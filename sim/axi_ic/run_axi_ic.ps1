# ==========================================================================
#  run_axi_ic.ps1 -- build and run the AXI interconnect testbench
# --------------------------------------------------------------------------
#  Usage:  pwsh -File sim\axi_ic\run_axi_ic.ps1
#
#  ASCII-only comments/messages on purpose: a .ps1 with Chinese comments but
#  no BOM is mis-decoded by Windows PowerShell 5.1 (same rule as run_all.ps1).
#
#  iverilog needs BOTH of these on PATH (see sim\run_all.ps1):
#    D:\iverilog\Library\bin
#    D:\iverilog\Library\mingw-w64\bin
#
#  Three configurations are built and run:
#    1. baseline model    ARB_ORDER=0 ROUTE_POLICY=0 (BY_PORT) -> must PASS
#    2. negative control  ARB_ORDER=0 ROUTE_POLICY=1 (BY_ID)   -> must FAIL,
#                         which proves the ID-collision check is sensitive
#    3. reverse priority  ARB_ORDER=1 ROUTE_POLICY=0           -> must PASS
#
#  Exit code 0 only when every configuration behaved as expected.
# ==========================================================================

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '_run'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

$SRC = @(
    (Join-Path $here 'axi_master_bfm.v'),
    (Join-Path $here 'axi4_slave_model.v'),
    (Join-Path $here 'axi_ic_semantic_model.v'),
    (Join-Path $here 'dut_axi_ic.v'),
    (Join-Path $here 'tb_axi_ic.v')
)

$configs = @(
    @{ Name = 'axi_ic_baseline';    Arb = 0; Route = 0; Expect = 'PASS';
       Desc = 'model, s0 first priority, response routed BY_PORT' },
    @{ Name = 'axi_ic_idhazard';    Arb = 0; Route = 1; Expect = 'FAIL';
       Desc = 'model, response routed BY_ID (negative control)' },
    @{ Name = 'axi_ic_revprio';     Arb = 1; Route = 0; Expect = 'PASS';
       Desc = 'model, s2 first priority, response routed BY_PORT' }
)

$bad = 0
foreach ($c in $configs) {
    $vvp = Join-Path $out ($c.Name + '.vvp')
    $log = Join-Path $out ($c.Name + '.log')

    Write-Output ''
    Write-Output ('=' * 72)
    Write-Output ("== " + $c.Name + "  (" + $c.Desc + ")")
    Write-Output ("==   -DARB_ORDER_VAL=" + $c.Arb + " -DROUTE_POLICY_VAL=" + $c.Route)
    Write-Output ('=' * 72)

    $cc = @('-g2012', '-s', 'tb_axi_ic', '-o', $vvp,
            ("-DARB_ORDER_VAL=" + $c.Arb),
            ("-DROUTE_POLICY_VAL=" + $c.Route)) + $SRC
    & "$ivBin\iverilog.exe" @cc 2>&1 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
        $bad++
        continue
    }

    $runlog = & "$ivBin\vvp.exe" $vvp 2>&1
    $rc = $LASTEXITCODE
    $runlog | Set-Content -Path $log -Encoding UTF8
    $runlog | Select-Object -Last 60 | ForEach-Object { $_ }

    $summary = ($runlog | Select-String -Pattern '\[SUMMARY\]').Line
    $arb     = ($runlog | Select-String -Pattern '^\[ARB\] TC2-read').Line
    if ($arb) { Write-Output ("  " + $arb.Trim()) }

    $verdict = if ($rc -ne 0) { 'FAIL' } else { 'PASS' }
    Write-Output ("[CONFIG RESULT: " + $verdict + "]  (vvp exit=" + $rc + ")  expected=" + $c.Expect + "  log=" + $log)
    if ($verdict -ne $c.Expect) {
        Write-Output ("[UNEXPECTED] " + $c.Name + " produced " + $verdict + " but " + $c.Expect + " was expected")
        $bad++
    }
}

Write-Output ''
Write-Output ('=' * 72)
if ($bad -eq 0) {
    Write-Output '=== AXI_IC REGRESSION: ALL CONFIGURATIONS AS EXPECTED ==='
} else {
    Write-Output ("=== AXI_IC REGRESSION: " + $bad + " CONFIGURATION(S) UNEXPECTED ===")
}
Write-Output 'NOTE: results marked PASS come from a BEHAVIOURAL MODEL, not from the'
Write-Output '      encrypted vendor IP -- see docs\AXI互联仿真结论.md'
exit $bad
