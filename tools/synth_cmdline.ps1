# ============================================================================
#  synth_cmdline.ps1 —— 纯命令行 efx_map 综合（不依赖 mmt.xml 的 synthesis 段/peri）
#  指挥官 #16 第四条：2025.2 一到位，只改 -EfxMap 路径就能一键跑 E3。
#
#  用法：
#    powershell -File tools\synth_cmdline.ps1 -Project mmt
#    powershell -File tools\synth_cmdline.ps1 -Project vendor
#    powershell -File tools\synth_cmdline.ps1 -Project mmt -EfxMap 'D:\Efinity\2025.2\bin\efx_map.exe'
#    powershell -File tools\synth_cmdline.ps1 -Project mmt -Ice 0
#
#  输出：out\synth_cmdline\<Project>.postslyn.v  + out\synth_cmdline\<Project>.log
#
#  ⚠️ 本脚本【只做综合】，不跑 efx_pnr / efx_pgm。
#     选项值取自 map.rpt 头（2026.1 实测生效值），显式传入，避免"命令行与工程流程有差异"。
# ============================================================================
param(
    [Parameter(Mandatory=$true)][ValidateSet('mmt','vendor')][string]$Project,
    [string]$EfxMap = 'D:\Efinity\2026.1\bin\efx_map.exe',
    [int]$Ice = 3,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
$P = 'D:\FPGA\mmt'
if (-not $OutDir) { $OutDir = Join-Path $P 'out\synth_cmdline' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------- 按项目决定：xml / 顶层 / 工作目录 / include ----------
if ($Project -eq 'mmt') {
    $Xml  = Join-Path $P 'mmt.xml'
    $Root = $P
    $Top  = 'mmt_top'
    $Name = 'mmt'
    $Inc  = @((Join-Path $P 'ip\csi_rx_controller'), (Join-Path $P 'ip\tinyml'), (Join-Path $P 'ip\axi_interconnect'))
} else {
    $V    = 'D:\FPGA\mmt\_synth_loop\v_vendor'
    $Xml  = Join-Path $V 'ti60f225_oob.xml'
    $Root = $V
    $Top  = 'ti60f225_oob_top'
    $Name = 'ti60f225_oob'
    $Inc  = @((Join-Path $V 'ip\csi_rx_controller'), (Join-Path $V 'ip\dsi_tx'), (Join-Path $V 'rtl'))
}

# ---------- 文件列表：从 xml 的 <efx:design_file> 显式取出，逐个 --v ----------
[xml]$doc = Get-Content $Xml
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('efx', 'http://www.efinixinc.com/enf_proj')
$files = @()
foreach ($n in $doc.SelectNodes('//efx:design_file', $ns)) {
    $rel = $n.name -replace '/','\'
    $abs = Join-Path $Root $rel
    if (Test-Path $abs) { $files += $abs } else { Write-Host "  !! 缺文件: $abs" }
}
# IP 源文件：<efx:ip instance_name=... path="ip/xxx/settings.json"><efx:ip_src_file name="xxx.v"/>
$ipCount = 0
foreach ($ipn in $doc.SelectNodes('//efx:ip', $ns)) {
    $ipDir = Join-Path $Root ((Split-Path $ipn.path -Parent) -replace '/','\')
    foreach ($sf in $ipn.SelectNodes('efx:ip_src_file', $ns)) {
        $abs = Join-Path $ipDir $sf.name
        if (-not (Test-Path $abs)) {
            # 兼容：在 ip 目录下递归找同名文件
            $cand = Get-ChildItem $ipDir -Recurse -File -Filter $sf.name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $abs = $cand.FullName }
        }
        if (Test-Path $abs) { $files += $abs; $ipCount++ } else { Write-Host "  !! 缺 IP 文件: $($sf.name) (ip=$($ipn.instance_name))" }
    }
}
Write-Host "  IP 源文件: $ipCount 个"
Write-Host "=== 项目: $Project   顶层: $Top ==="
Write-Host "  efx_map: $EfxMap"
Write-Host "  源文件 : $($files.Count) 个（从 xml 的 design_file 取出）"

# ---------- 环境（Efinity 各版本通用；按 efx_map 所在版本目录推导）----------
$verDir = Split-Path (Split-Path $EfxMap -Parent) -Parent     # ...\2026.1
$env:EFINITY_HOME                = $verDir -replace '\\','/'
$env:EFINITY_USER_DIR_INI        = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFINITY_USER_DIR            = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity'
$env:EFXPT_HOME  = "$verDir/pt";  $env:EFXPGM_HOME = "$verDir/pgm"
$env:EFXDBG_HOME = "$verDir/debugger"; $env:EFXIPM_HOME = "$verDir/ipm"
$pyBin = Join-Path $verDir 'python311\bin'
if (Test-Path $pyBin) { $env:PYTHONHOME = (Join-Path $verDir 'python311') -replace '\\','/' }
$env:QT_PLUGIN_PATH = Join-Path $verDir 'bin'
$env:QT_QPA_PLATFORM_PLUGIN_PATH = Join-Path $verDir 'python311\platforms'
$env:PATH = "$pyBin;$verDir\bin;$env:PATH"

# ---------- 显式选项（取自 map.rpt 头，2026.1 实测生效值）----------
$opts = @(
  '--root', $Top,
  '--device','Ti60F225','--family','Titanium',
  '--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008',
  '--mode','speed',
  '--infer-clk-enable', "$Ice",
  '--infer-sync-set-reset','1',
  '--fanout-limit','0',
  '--seq_opt','0',
  '--retiming','0',
  '--dsp-mac-packing','1','--dsp-input-regs-packing','1','--dsp-output-regs-packing','1',
  '--bram_output_regs_packing','1',
  '--blast_const_operand_adders','1',
  '--operator-sharing','0',
  '--optimize-adder-tree','0',
  '--pack-luts-to-comb4','0',
  '--min-sr-fanout','0','--min-ce-fanout','0',
  '--seq-opt-sync-only','0',
  '--blackbox-error','1',
  '--allow-const-ram-index','0',
  '--hdl-compile-unit','1',
  '--create-onehot-fsms','0',
  '--mult-decomp-retime','0',
  '--optimize-zero-init-rom','1',
  '--insert-carry-skip','0',
  '--mult-auto-pipeline','0',
  '--use-logic-for-small-mem','64',
  '--use-logic-for-small-rom','64',
  '--bram-push-tco-outreg','0',
  '--hdl-loop-limit','20000',
  '--enable-mark-debug','1',
  '--max-bit-blast-mem-size','10240',
  '--peri-syn-instantiation','0',
  '--peri-syn-inference','0'
)

$args = @()
foreach ($f in $files) { $args += @('--v', $f) }
$args += $opts
$args += @('--work-dir', (Join-Path $OutDir "work_$($Project)"), '--output-dir', $OutDir, '--I', $Root)
foreach ($d in $Inc) { if (Test-Path $d) { $args += @('--I', $d) } }
$outNet = Join-Path $OutDir "$Project.postsyn.v"
Remove-Item $outNet -Force -ErrorAction SilentlyContinue
$args += @('--write-efx-verilog', $outNet)

Write-Host "`n=== 综合中（只 efx_map，不 PnR）==="
$t0 = Get-Date
$proc = Start-Process -FilePath $EfxMap -ArgumentList $args -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $Root `
        -RedirectStandardOutput (Join-Path $OutDir "$Project.log") `
        -RedirectStandardError  (Join-Path $OutDir "$Project.err.log")
Write-Host ("  efx_map 退出码 = {0}   耗时 {1:N0}s" -f $proc.ExitCode, ((Get-Date)-$t0).TotalSeconds)
Get-Content (Join-Path $OutDir "$Project.err.log") -ErrorAction SilentlyContinue | Select-Object -Last 6

if (-not (Test-Path $outNet)) { Write-Host "!! 网表未生成"; exit 1 }
Write-Host ("  网表: {0}  {1:N2} MB" -f $outNet, ((Get-Item $outNet).Length/1MB))
Write-Host "`n=== 资源（从 efx_map 日志）==="
Select-String -Path (Join-Path $OutDir "$Project.log") -Pattern 'EFX_FF|EFX_LUT4|EFX_SRL8|EFX_ADD|EFX_RAM10' -ErrorAction SilentlyContinue |
    Select-Object -Last 8 | ForEach-Object { "  " + $_.Line.Trim() }
Write-Host "`n=== 应有清单门禁 ==="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $P 'tools\check_expected.ps1') -Netlist $outNet
Write-Host ("  门禁退出码 = {0}" -f $LASTEXITCODE)
exit $LASTEXITCODE

