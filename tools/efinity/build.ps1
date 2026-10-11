# ============================================================
#  Efinity 通用构建脚本（综合 + 布局布线 + 资源报告）
#  用法:
#    .\build.ps1 -Xml "D:\...\mmt.xml" -Top "ti60f225_oob_top" -Name "mmt" [-SkipSyn] [-OnlyXlr]
#  说明:
#    - 非破坏性：输出写到 <Xml所在目录>\out 与 work_syn / work_pnr
#    - 自动设置 Efinity 环境（等价于官方 bin\setup.bat）
#    - 结束后打印 XLR / BRAM / DSP / 时钟 占用
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Xml,
    [Parameter(Mandatory=$true)][string]$Top,
    [string]$Name,
    [string]$Sdc,
    [string]$SyncFile,
    [string]$IncDir,
    [switch]$SkipSyn,
    [switch]$Bitstream
)
$ErrorActionPreference = 'Continue'

# ---------- Efinity 环境 ----------
$efi = "D:/Efinity/2026.1"
$env:EFINITY_HOME                = $efi
$env:EFINITY_USER_DIR_INI        = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFXPT_HOME                  = "$efi/pt"
$env:EFXPGM_HOME                 = "$efi/pgm"
$env:EFXDBG_HOME                 = "$efi/debugger"
$env:EFXIPM_HOME                 = "$efi/ipm"
$env:PYTHONHOME                  = "$efi/python311"
$env:QT_PLUGIN_PATH              = "$efi/bin"
$env:QT_QPA_PLATFORM_PLUGIN_PATH = "$efi/python311/platforms"
$env:PATH                        = "$efi/python311/bin;$efi/bin;$efi/scripts;" + $env:PATH
$efx_map = "$efi/bin/efx_map.exe"
$efx_pnr = "$efi/bin/efx_pnr.exe"
$efx_pgm = "$efi/bin/efx_pgm.exe"

$Xml = (Resolve-Path $Xml).Path
$root = Split-Path $Xml -Parent
if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Xml) }
if (-not $Sdc) {
    # 从 XML 里读 sdc 路径
    $m = Select-String -Path $Xml -Pattern '<efx:sdc_file name="([^"]+)"' | Select-Object -First 1
    if ($m -and $m.Matches[0].Groups[1].Value) { $Sdc = Join-Path $root ($m.Matches[0].Groups[1].Value -replace '/','\') }
}
$out  = Join-Path $root 'out'
$wsyn = Join-Path $root 'work_syn'
$wpnr = Join-Path $root 'work_pnr'
foreach ($d in @($out,$wsyn,$wpnr)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

Write-Output "=============================="
Write-Output "工程 : $Xml"
Write-Output "顶层 : $Top"
Write-Output "约束 : $Sdc"
Write-Output "输出 : $out"
Write-Output "=============================="

# ---------- 综合 ----------
if (-not $SkipSyn) {
    Write-Output "`n########## [1/3] efx_map 综合 ##########"
    $args1 = @('--prj', $Xml, '--project', $Name, '--root', $Top,
               '--device', 'Ti60F225', '--family', 'Titanium',
               '--veri_option', 'verilog_mode=sv_09,vhdl_mode=vhdl_2008',
               '--work-dir', $wsyn, '--output-dir', $out,
               '--I', $root)
    # include 搜索路径。★ 一律从工程 XML 读 <efx:param name="include" .../>，
    #   不在这里硬编码 —— 之前硬编码了一份（还多带了个 'rtl'），而 XML 里只有
    #   两个 ip 目录，于是出现"命令行脚本能综合、Efinity GUI 里点综合就报
    #   cannot open include file 'ddr3_controller/ddr3_parameter.vh'"这种两边
    #   行为不一致的问题。GUI 正是读 XML 里这些条目生成 -I 的，现在脚本读同一份，
    #   两边不可能再漂移。
    $xmlIncludes = @()
    foreach ($mm in [regex]::Matches([System.IO.File]::ReadAllText($Xml),
                                     '<efx:param\s+name="include"\s+value="([^"]+)"')) {
        $xmlIncludes += $mm.Groups[1].Value
    }
    if ($xmlIncludes.Count -eq 0) { Write-Output '!! 工程 XML 里没有 include 条目' }
    foreach ($d in $xmlIncludes) {
        $p = Join-Path $root ($d -replace '/','\')
        if (Test-Path $p) { $args1 += @('--I', $p) }
        else { Write-Output ("!! include 目录不存在: " + $p) }
    }
    if ($IncDir) { $args1 += @('--I', $IncDir) }
    $t0 = Get-Date
    $log = Join-Path $out 'efx_map.log'
    $p1 = Start-Process -FilePath $efx_map -ArgumentList $args1 -NoNewWindow -Wait -PassThru `
            -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError (Join-Path $out 'efx_map.err.log')
    Write-Output ("efx_map 退出码 = {0}  耗时 {1:N0} 秒" -f $p1.ExitCode, ((Get-Date) - $t0).TotalSeconds)
    if ($p1.ExitCode -ne 0) {
        Write-Output "--- 错误摘要 ---"
        Get-Content (Join-Path $out 'efx_map.err.log') -ErrorAction SilentlyContinue | Select-Object -First 25
        Get-Content $log -ErrorAction SilentlyContinue | Select-String -Pattern 'ERROR' | Select-Object -First 25 | ForEach-Object { $_.Line }
        Write-Output "综合失败，终止。完整日志: $log"
        exit 1
    }
    Get-Content $log -ErrorAction SilentlyContinue | Select-String -Pattern 'EFX_ADD|EFX_LUT4|EFX_FF|EFX_SRL8|EFX_RAM|EFX_DPRAM' | ForEach-Object { '   ' + $_.Line }
}

# ---------- 布局布线 ----------
Write-Output "`n########## [2/3] efx_pnr 布局布线 ##########"
$args2 = @('--prj', $Xml, '--circuit', $Name, '--family', 'Titanium', '--device', 'Ti60F225',
           '--operating_conditions', 'I3', '--pack', '--place', '--route',
           '--vdb_file', (Join-Path $out "$Name.vdb"), '--use_vdb_file', 'on',
           '--place_file', (Join-Path $out "$Name.place"),
           '--route_file', (Join-Path $out "$Name.troutingtraces"),
           '--optimization_level', 'TIMING_3', '--seed', '0', '--placer_effort_level', '2',
           '--max_threads', '-1', '--beneficial_skew', 'on', '--print_critical_path', '10',
           '--work_dir', $wpnr, '--output_dir', $out, '--timing_analysis', 'on')
if ($Sdc -and (Test-Path $Sdc)) { $args2 += @('--sdc_file', $Sdc) }
if ($SyncFile -and (Test-Path $SyncFile)) { $args2 += @('--sync_file', $SyncFile) }
$t0 = Get-Date
$log2 = Join-Path $out 'efx_pnr.log'
$p2 = Start-Process -FilePath $efx_pnr -ArgumentList $args2 -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $root -RedirectStandardOutput $log2 -RedirectStandardError (Join-Path $out 'efx_pnr.err.log')
Write-Output ("efx_pnr 退出码 = {0}  耗时 {1:N0} 秒" -f $p2.ExitCode, ((Get-Date) - $t0).TotalSeconds)
Get-Content $log2 -ErrorAction SilentlyContinue | Select-String -Pattern 'XLR count|ERROR' | Select-Object -First 12 | ForEach-Object { '   ' + $_.Line }
if ($p2.ExitCode -ne 0) {
    Get-Content (Join-Path $out 'efx_pnr.err.log') -ErrorAction SilentlyContinue | Select-Object -First 20
    Write-Output "布局布线失败。完整日志: $log2"
    exit 1
}

# ---------- 位流（可选） ----------
if ($Bitstream) {
    Write-Output "`n########## [3/3] efx_pgm 位流 ##########"
    $t0 = Get-Date
    $p3 = Start-Process -FilePath $efx_pgm -ArgumentList @('--prj', $Xml, '--family', 'Titanium',
            '--device', 'Ti60F225', '--mode', 'active', '--width', '1',
            '--work_dir', $wpnr, '--output_dir', $out, '--timing_analysis', 'on') `
            -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
            -RedirectStandardOutput (Join-Path $out 'efx_pgm.log') -RedirectStandardError (Join-Path $out 'efx_pgm.err.log')
    Write-Output ("efx_pgm 退出码 = {0}  耗时 {1:N0} 秒" -f $p3.ExitCode, ((Get-Date) - $t0).TotalSeconds)
}

# ---------- 资源报告 ----------
$placeRpt = Join-Path $out "$Name.place.rpt"
if (-not (Test-Path $placeRpt)) {
    $cand = Get-ChildItem $out -Filter "*.place.rpt" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { $placeRpt = $cand.FullName }
}
Write-Output "`n########## 资源占用 ##########"
if (Test-Path $placeRpt) {
    Write-Output "报告: $placeRpt"
    Get-Content $placeRpt | Select-String -Pattern 'XLR|Memory Blocks|DSP Blocks|Global Clocks|Regional Clocks|Inputs:|Outputs:' | ForEach-Object { $_.Line }
} else { Write-Output "!! 没找到 place.rpt" }
