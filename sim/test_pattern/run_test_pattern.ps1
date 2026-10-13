# ==========================================================================
#  run_test_pattern.ps1 -- M0: 测试图案 → checker0 → 写 DDR → 读 DDR
# --------------------------------------------------------------------------
#  用法:
#    powershell -NoProfile -ExecutionPolicy Bypass -File sim\test_pattern\run_test_pattern.ps1
#
#  做三件事:
#    1. 生成 shim 过的厂商 frame_buffer 源码副本到 %TEMP%\test_pattern_sim\src
#       （rtl\ 只读；3 处 shim 的说明见 make_shim_src.ps1）
#    2. 编译 rtl\mmt\mmt_test_pattern.v + tb_test_pattern.v + 副本
#    3. 跑仿真，打印 T1~T5 全部断言与原始输出；退出码非 0 表示有 FAIL
#
#  产物:
#    %TEMP%\test_pattern_sim\tp.vvp           编译产物
#    sim\test_pattern\_logs\tp_run.log        完整原始输出（留档）
# ==========================================================================

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$sim  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $sim)
$out  = Join-Path $env:TEMP 'test_pattern_sim'
$log  = Join-Path $sim '_logs'
if (-not (Test-Path $log)) { New-Item -ItemType Directory -Path $log -Force | Out-Null }

# ---- 1. shim 源码副本 ----
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sim 'make_shim_src.ps1')

$src = Get-ChildItem (Join-Path $out 'src') -Filter '*.v' | ForEach-Object { $_.FullName }
$TP  = Join-Path $root 'rtl\mmt\mmt_test_pattern.v'
$TB  = Join-Path $sim 'tb_test_pattern.v'
$vvp = Join-Path $out 'tp.vvp'

# ---- 2. 编译 ----
Write-Output ''
Write-Output '=== compile ==='
$cc = @('-g2012', '-s', 'tb_test_pattern', '-o', $vvp) + $src + @($TP, $TB)
& "$ivBin\iverilog.exe" @cc 2>&1 | Select-String ': error' | Select-Object -First 10 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
    exit 1
}
Write-Output 'compile OK'

# ---- 3. 跑 ----
Write-Output ''
Write-Output '=== run ==='
$runlog = & "$ivBin\vvp.exe" $vvp 2>&1
$rc = $LASTEXITCODE
$runlog | Set-Content -Path (Join-Path $log 'tp_run.log') -Encoding UTF8
$runlog | ForEach-Object { $_ }

Write-Output ''
Write-Output ("完整原始输出留档: " + (Join-Path $log 'tp_run.log'))
exit $rc
