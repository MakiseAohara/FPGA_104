# ==========================================================================
#  run_all.ps1 -- compile and run every RTL testbench of the MMT project
# --------------------------------------------------------------------------
#  Usage:  pwsh -File sim\run_all.ps1
#          powershell -ExecutionPolicy Bypass -File sim\run_all.ps1
#
#  Comments and messages are deliberately ASCII-only: a .ps1 with Chinese
#  comments but no BOM is mis-decoded by Windows PowerShell 5.1.
#
#  iverilog needs BOTH of these on PATH, otherwise it dies with a vague
#  "failed to open using dlopen() ... module not found" or exit 0xC0000135:
#    D:\iverilog\Library\bin
#    D:\iverilog\Library\mingw-w64\bin
#  (installed with micromamba from conda-forge, see sim.ps1 header)
# ==========================================================================

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

# repo root = parent of this script's directory
$sim = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $sim
$out  = Join-Path $sim '_run'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

$RTL = Join-Path $root 'rtl\mmt'
$S   = Join-Path $sim ''

$tests = @(
    @{ Name = 'tb_i2c_master';
       Tb   = "$S\tb_i2c_master.v";
       Src  = @("$RTL\sensors\mmt_i2c_master.v") },
    @{ Name = 'tb_i2c_hub';
       Tb   = "$S\tb_i2c_hub.v";
       Src  = @("$S\i2c_slave_model.v", "$RTL\sensors\mmt_i2c_hub.v", "$RTL\sensors\mmt_i2c_master.v") },
    @{ Name = 'tb_sht30_ctrl';
       Tb   = "$S\tb_sht30_ctrl.v";
       Src  = @("$S\i2c_slave_model.v", "$RTL\sensors\mmt_sht30_ctrl.v",
                "$RTL\sensors\mmt_i2c_master.v", "$RTL\sensors\mmt_i2c_hub.v") },
    @{ Name = 'tb_mlx90640_ctrl';
       Tb   = "$S\tb_mlx90640_ctrl.v";
       Src  = @("$S\mlx90640_model.v", "$RTL\sensors\mmt_mlx90640_ctrl.v",
                "$RTL\sensors\mmt_i2c_master.v", "$RTL\sensors\mmt_i2c_hub.v") }
)

$failed = 0
foreach ($t in $tests) {
    Write-Output ''
    Write-Output ('=' * 66)
    Write-Output ("== " + $t.Name)
    Write-Output ('=' * 66)

    $vvp = Join-Path $out ($t.Name + '.vvp')
    $cc  = @('-g2012', '-o', $vvp, '-I', $S) + $t.Src + @($t.Tb)
    & "$ivBin\iverilog.exe" @cc 2>&1 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
        $failed++
        continue
    }

    $log = & "$ivBin\vvp.exe" $vvp 2>&1
    $log | ForEach-Object { $_ }
    $rc = $LASTEXITCODE

    $bad = ($log | Select-String -Pattern 'FAILURES|FAIL\]|TIMEOUT').Count
    if ($rc -ne 0 -or $bad -gt 0) {
        Write-Output ("[RESULT: FAIL]  (vvp exit=" + $rc + ")")
        $failed++
    } else {
        Write-Output '[RESULT: PASS]'
    }
}

Write-Output ''
Write-Output ('=' * 66)
if ($failed -eq 0) { Write-Output '=== REGRESSION: ALL TESTBENCHES PASSED ===' }
else               { Write-Output ("=== REGRESSION: " + $failed + " TESTBENCH(ES) FAILED ===") }
exit $failed
