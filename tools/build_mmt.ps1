# ============================================================================
#  build_mmt.ps1 —— 规范构建包装（指挥官指令 #10 之 1b）
#
#  为什么需要它：
#    2026-10-16 出过一次"PnR 失败却打出陈旧位流"的事故 ——
#    run_full_flow.ps1 内部的 build.ps1 在 PnR 失败时确实会 exit 1，
#    但外层命令里额外接了一段无条件的 efx_pgm，用陈旧的 work_pnr\mmt.lbf
#    打出了旧位流（out\mmt.bit 时间戳是新的，内容却是旧的）。
#
#  本脚本固化三重防线：
#    ① 构建前清掉 work_pnr\*.lbf 与 out\mmt.bit / mmt.hex（杜绝陈旧产物被复用）
#    ② PnR 失败立即 abort，绝不调 efx_pgm
#    ③ 构建后校验 bit 的修改时间晚于 PnR 结束时间，并写 sha256
#
#  用法：
#    powershell -File tools\build_mmt.ps1
#    powershell -File tools\build_mmt.ps1 -SkipBitstream   # 只到 PnR
# ============================================================================
param([switch]$SkipBitstream)
$ErrorActionPreference = 'Continue'

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # D:\FPGA\mmt
if (-not (Test-Path (Join-Path $root 'mmt.xml'))) { $root = 'D:\FPGA\mmt' }
$out  = Join-Path $root 'out'
$wpnr = Join-Path $root 'work_pnr'
$bit  = Join-Path $out  'mmt.bit'
$hex  = Join-Path $out  'mmt.hex'

Write-Host "==================== build_mmt ===================="
Write-Host "工程 : $root"
Write-Host "开始 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ---------- ① 构建前清理（杜绝陈旧产物）----------
Write-Host "`n--- ① 清理陈旧产物 ---"
Get-ChildItem $wpnr -Filter *.lbf -File -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host ("  删除 {0}  ({1})" -f $_.Name, $_.LastWriteTime); Remove-Item $_.FullName -Force }
foreach ($f in @($bit, $hex)) {
    if (Test-Path $f) { Write-Host ("  删除 {0}  ({1})" -f (Split-Path $f -Leaf), (Get-Item $f).LastWriteTime); Remove-Item $f -Force } }

$tStart = Get-Date

# ---------- ②a 只综合（efx_map），产出网表供门禁检查 ----------
#  指挥官 #15 第一条：必须"efx_map → 门禁 → efx_pnr → bitgen"。
#  因此这里先单独跑一次综合（约 2.5 分钟），门禁过了才进 PnR。
Write-Host "`n--- ②a 只综合 efx_map（供门禁检查，尚未 PnR）---"
$efi = 'D:/Efinity/2026.1'
$env:EFINITY_HOME=$efi
$env:EFINITY_USER_DIR_INI=($env:LOCALAPPDATA -replace '\\','/')+'/efinity/user_dir.ini'
$env:EFINITY_USER_DIR=($env:LOCALAPPDATA -replace '\\','/')+'/efinity'
$env:EFXPT_HOME="$efi/pt"; $env:EFXPGM_HOME="$efi/pgm"; $env:EFXDBG_HOME="$efi/debugger"; $env:EFXIPM_HOME="$efi/ipm"
$env:PYTHONHOME="$efi/python311"
$env:QT_PLUGIN_PATH="$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH="$efi/python311/platforms"
$env:PATH="$efi/python311/bin;$efi/bin;$efi/scripts;"+$env:PATH
$wsyn = Join-Path $root 'work_syn'
$gateNetlist = Join-Path $out 'mmt.gate.postsyn.v'
Remove-Item $gateNetlist -Force -ErrorAction SilentlyContinue
$aMap = @('--prj', (Join-Path $root 'mmt.xml'), '--project','mmt','--root','mmt_top',
          '--device','Ti60F225','--family','Titanium',
          '--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008',
          '--work-dir',$wsyn,'--output-dir',$out,'--I',$root)
foreach ($mm in [regex]::Matches([System.IO.File]::ReadAllText((Join-Path $root 'mmt.xml')), '<efx:param\s+name="include"\s+value="([^"]+)"')) {
    $d = Join-Path $root ($mm.Groups[1].Value -replace '/','\'); if (Test-Path $d) { $aMap += @('--I',$d) } }
$aMap += @('--write-efx-verilog',$gateNetlist)
$pMap = Start-Process -FilePath "$efi/bin/efx_map.exe" -ArgumentList $aMap -NoNewWindow -Wait -PassThru `
        -WorkingDirectory $root -RedirectStandardOutput (Join-Path $out 'efx_map.gate.log') `
        -RedirectStandardError (Join-Path $out 'efx_map.gate.err.log')
Write-Host "efx_map 退出码 = $($pMap.ExitCode)"
if ($pMap.ExitCode -ne 0 -or -not (Test-Path $gateNetlist)) {
    Write-Host "!! 只综合失败，abort（不进 PnR）"; exit 1 }

# ---------- ②b 门禁（efx_pnr 之前，必须过）----------
Write-Host "`n--- ②b 应有清单门禁（efx_pnr 之前）---"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'check_expected.ps1') -Netlist $gateNetlist
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n########## 门禁未过 —— abort，不进入 efx_pnr ##########" -ForegroundColor Red
    Write-Host "  （本脚本不提供跳过开关；要放行须指挥官批示后修改 expected_ffs.txt / victim_whitelist.txt）"
    exit 1
}
Write-Host "  门禁通过 ⇒ 进入 PnR"

# ---------- ②c 完整流程（综合 + Interface + PnR with pins）----------
Write-Host "`n--- ②c run_full_flow.ps1（Interface + PnR）---"
$flow = Join-Path $root 'tools\efinity\run_full_flow.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $flow 2>&1 | Select-Object -Last 25
$flowExit = $LASTEXITCODE
Write-Host "run_full_flow.ps1 退出码 = $flowExit"
$tPnrEnd = Get-Date

# PnR 判据：日志里出现 ERROR 或退出码非 0，立即 abort
$pnrLog = Join-Path $out 'efx_pnr.log'
$pnrBad = $false
if (Test-Path $pnrLog) {
    $errs = Select-String -Path $pnrLog -Pattern 'Block capacity checks have failed|Not enough physical locations|^ERROR' -ErrorAction SilentlyContinue
    if ($errs) { $pnrBad = $true; Write-Host "`n!! PnR 日志里发现错误："; $errs | Select-Object -First 8 | ForEach-Object { "   " + $_.Line.Trim() } }
}
$lbf = Get-ChildItem $wpnr -Filter *.lbf -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $lbf)       { Write-Host "`n!! work_pnr 下没有 .lbf ⇒ PnR 未产出"; $pnrBad = $true }
elseif ($lbf.LastWriteTime -lt $tStart) { Write-Host ("`n!! .lbf 早于本次构建开始（{0} < {1}）⇒ 是陈旧产物" -f $lbf.LastWriteTime,$tStart); $pnrBad = $true }

if ($pnrBad -or $flowExit -ne 0) {
    Write-Host "`n########## PnR 失败 —— 立即 abort，不调用 efx_pgm ##########"
    if (Test-Path $bit) { Remove-Item $bit -Force; Write-Host "  已删除可能存在的 out\mmt.bit" }
    exit 1
}
Write-Host ("`nPnR OK：{0}  {1}" -f $lbf.Name, $lbf.LastWriteTime)


if ($SkipBitstream) { Write-Host "`n-SkipBitstream：到此为止"; exit 0 }

# ---------- ③ 位流 ----------
Write-Host "`n--- ③ efx_pgm 位流 ---"
$efi = 'D:/Efinity/2026.1'
$env:EFINITY_HOME=$efi
$env:EFINITY_USER_DIR_INI=($env:LOCALAPPDATA -replace '\\','/')+'/efinity/user_dir.ini'
$env:EFINITY_USER_DIR=($env:LOCALAPPDATA -replace '\\','/')+'/efinity'
$env:EFXPT_HOME="$efi/pt"; $env:EFXPGM_HOME="$efi/pgm"; $env:EFXDBG_HOME="$efi/debugger"; $env:EFXIPM_HOME="$efi/ipm"
$env:PYTHONHOME="$efi/python311"
$env:QT_PLUGIN_PATH="$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH="$efi/python311/platforms"
$env:PATH="$efi/python311/bin;$efi/bin;$efi/scripts;"+$env:PATH
$p = Start-Process -FilePath "$efi/bin/efx_pgm.exe" -ArgumentList @(
      '--project-xml', (Join-Path $root 'mmt.xml'), '--source', $lbf.FullName,
      '--dest', $hex, '--family','Titanium','--device','Ti60F225','--mode','active','--width','1') `
     -NoNewWindow -Wait -PassThru -WorkingDirectory $root `
     -RedirectStandardOutput (Join-Path $out 'efx_pgm.log') -RedirectStandardError (Join-Path $out 'efx_pgm.err.log')
Write-Host "efx_pgm 退出码 = $($p.ExitCode)"
if ($p.ExitCode -ne 0) { Write-Host "!! 位流生成失败，abort"; exit 1 }

# ---------- ④ 产物校验 + sha256 ----------
Write-Host "`n--- ④ 产物校验 ---"
if (-not (Test-Path $bit)) { Write-Host "!! out\mmt.bit 不存在"; exit 1 }
$b = Get-Item $bit
if ($b.LastWriteTime -lt $tPnrEnd) {
    Write-Host ("!! 位流时间戳 {0} 早于 PnR 结束 {1} ⇒ 拒绝" -f $b.LastWriteTime, $tPnrEnd); exit 1 }
$sha = (Get-FileHash $bit -Algorithm SHA256).Hash
Write-Host ("  位流 : {0}" -f $bit)
Write-Host ("  大小 : {0} B" -f $b.Length)
Write-Host ("  时间 : {0}   (PnR 结束 {1})  ✔ 晚于 PnR" -f $b.LastWriteTime, $tPnrEnd)
Write-Host ("  SHA256: {0}" -f $sha)
$shaFile = Join-Path $out ("bitstream_{0}.sha256" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Set-Content -Path $shaFile -Value "$sha  $bit" -Encoding UTF8
Write-Host ("  已写 : {0}" -f $shaFile)
Write-Host "`n==================== DONE ===================="
exit 0
