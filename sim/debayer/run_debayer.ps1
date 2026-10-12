# ==========================================================================
#  run_debayer.ps1 -- debayer colour-mapping / Bayer-phase test
# --------------------------------------------------------------------------
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File sim\debayer\run_debayer.ps1
#
#  Compiles the vendor debayer chain READ-ONLY from rtl\ plus the patched
#  copies under sim\debayer\patched\ and runs the synthetic-Bayer testbench
#  against each variant, then prints a side-by-side verdict table.
#
#  Variants
#    ORIGINAL : rtl\debayer\debayer_top_2to1.v + rtl\debayer\raw_to_rgb.v as-is
#    RB_SWAP  : debayer output byte order r<->b exchanged
#    ROWFLIP  : raw_to_rgb.v row-parity test  r_y_cnt[0]  ->  !r_y_cnt[0]
#    LEGACY0  : raw_to_rgb parameter LEGACY 1'b1 -> 1'b0
#
#  Build artefacts go to %TEMP%\debayer_sim.
#  ASCII-only messages (Windows PowerShell 5.1 mis-decodes BOM-less Chinese).
# ==========================================================================

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$sim  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $sim)
$R    = Join-Path $root 'rtl\debayer'
$P    = Join-Path $sim 'patched'
$out  = Join-Path $env:TEMP 'debayer_sim'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

$COMMON = @(
    (Join-Path $root 'rtl\true_dual_port_ram.v'),
    (Join-Path $R 'rgb_gain.v'),
    (Join-Path $R 'line_buffer.v')
)
$TB = Join-Path $sim 'tb_debayer.v'

# variant name -> @( raw_to_rgb, debayer_top )
$variants = [ordered]@{
    'ORIGINAL' = @( (Join-Path $R 'raw_to_rgb.v'),            (Join-Path $R 'debayer_top_2to1.v') )
    'RB_SWAP'  = @( (Join-Path $R 'raw_to_rgb.v'),            (Join-Path $P 'top_rbswap.v')       )
    'ROWFLIP'  = @( (Join-Path $P 'raw_to_rgb_rowflip.v'),    (Join-Path $R 'debayer_top_2to1.v') )
    'LEGACY0'  = @( (Join-Path $R 'raw_to_rgb.v'),            (Join-Path $P 'top_legacy0.v')      )
}

$results = @{}

foreach ($k in $variants.Keys) {
    $vvp = Join-Path $out ("v_" + $k + ".vvp")
    $log = Join-Path $out ("v_" + $k + ".log")
    Write-Output ''
    Write-Output ('=' * 72)
    Write-Output ("== variant " + $k)
    Write-Output ('=' * 72)

    $cc = @('-g2012', '-s', 'tb_debayer', '-o', $vvp) + $COMMON + $variants[$k] + @($TB)
    & "$ivBin\iverilog.exe" @cc 2>&1 | Select-String ': error' | Select-Object -First 5 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
        continue
    }
    $runlog = & "$ivBin\vvp.exe" $vvp 2>&1
    $runlog | Set-Content -Path $log -Encoding UTF8

    if ($k -eq 'ORIGINAL') {
        $runlog | ForEach-Object { $_ }
    } else {
        $runlog | Select-String -Pattern '\[SUMMARY\]|DONE' | ForEach-Object { $_.Line }
        Write-Output ("   (ran OK, log: " + $log + ")")
    }

    foreach ($line in $runlog) {
        if ($line -match 'PACK=(\d) phase=(\w+) field=(\w+).*=> (\S+)') {
            $results["$k|$($matches[2])|$($matches[3])"] = $matches[4]
        }
    }
}

# --------------------------------------------------------------------------
#  side-by-side verdict table
# --------------------------------------------------------------------------
Write-Output ''
Write-Output ('=' * 72)
Write-Output '== VERDICT TABLE  (PACK=1 : raw_datax4_i[15:8] = even column)'
Write-Output '==   cell = which output channel carries the driven colour'
Write-Output ('=' * 72)
Write-Output ("  {0,-6} {1,-6} {2,-6} {3,-6} {4,-6} {5,-6}" -f 'phase','field','ORIG','RB_SWP','ROWFLIP','LEG0')
$phases = @('RGGB','BGGR','GRBG','GBRG')
$fields = @('RED','GREEN','BLUE')
foreach ($ph in $phases) {
    foreach ($f in $fields) {
        Write-Output ("  {0,-6} {1,-6} {2,-6} {3,-6} {4,-6} {5,-6}" -f $ph, $f,
            $results["ORIGINAL|$ph|$f"], $results["RB_SWAP|$ph|$f"],
            $results["ROWFLIP|$ph|$f"],  $results["LEGACY0|$ph|$f"])
    }
}

# --------------------------------------------------------------------------
#  automated expectations
# --------------------------------------------------------------------------
$bad = 0
function Check($name, $cond) {
    if ($cond) { Write-Output ("[PASS] " + $name) }
    else       { Write-Output ("[FAIL] " + $name); $script:bad++ }
}

Write-Output ''
Write-Output '== expectations =='
Check 'E1 ORIGINAL is a correct RGGB debayer (RED->R GREEN->G BLUE->B)' `
      (($results['ORIGINAL|RGGB|RED']   -eq 'R') -and
       ($results['ORIGINAL|RGGB|GREEN'] -eq 'G') -and
       ($results['ORIGINAL|RGGB|BLUE']  -eq 'B'))
Check 'E2 ORIGINAL with a BGGR sensor => exact R/B swap (RED->B, GREEN->G, BLUE->R)' `
      (($results['ORIGINAL|BGGR|RED']   -eq 'B') -and
       ($results['ORIGINAL|BGGR|GREEN'] -eq 'G') -and
       ($results['ORIGINAL|BGGR|BLUE']  -eq 'R'))
Check 'E3 RB_SWAP fixes the BGGR (purple) case' `
      (($results['RB_SWAP|BGGR|RED']   -eq 'R') -and
       ($results['RB_SWAP|BGGR|GREEN'] -eq 'G') -and
       ($results['RB_SWAP|BGGR|BLUE']  -eq 'B'))
Check 'E4 RB_SWAP is an involution (it breaks the already-correct RGGB case)' `
      (($results['RB_SWAP|RGGB|RED'] -eq 'B') -and ($results['RB_SWAP|RGGB|BLUE'] -eq 'R'))
Check 'E5 ROWFLIP does NOT fix the purple case (only shifts the green lattice)' `
      (-not (($results['ROWFLIP|BGGR|RED'] -eq 'R') -and ($results['ROWFLIP|BGGR|BLUE'] -eq 'B')))
Check 'E6 LEGACY=0 has no effect on the colour mapping (identical to ORIGINAL)' `
      ((($phases | ForEach-Object { $ph = $_; $fields | ForEach-Object {
            $results["LEGACY0|$ph|$_"] -eq $results["ORIGINAL|$ph|$_"] } }) -notcontains $false))

Write-Output ''
Write-Output ('=' * 72)
if ($bad -eq 0) { Write-Output '=== DEBAYER ANALYSIS: ALL EXPECTATIONS MET ===' }
else            { Write-Output ("=== DEBAYER ANALYSIS: " + $bad + " EXPECTATION(S) NOT MET ===") }

# --------------------------------------------------------------------------
#  display-path check: does mmt_osd_overlay pass R/G/B through honestly?
#  ($readmemh("font8x16.hex") needs the project root as cwd)
# --------------------------------------------------------------------------
Write-Output ''
Write-Output ('=' * 72)
Write-Output '== mmt_osd_overlay pass-through / R-B wiring test'
Write-Output ('=' * 72)

$osdVvp = Join-Path $out 'osd.vvp'
$cc2 = @('-g2012', '-s', 'tb_osd_passthrough', '-o', $osdVvp,
         (Join-Path $root 'rtl\mmt\osd\mmt_osd_overlay.v'),
         (Join-Path $sim 'tb_osd_passthrough.v'))
& "$ivBin\iverilog.exe" @cc2 2>&1 | Select-String ': error' | Select-Object -First 5 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
    $bad++
} else {
    Push-Location $root
    $osdlog = & "$ivBin\vvp.exe" $osdVvp 2>&1
    $osdrc  = $LASTEXITCODE
    Pop-Location
    $osdlog | Set-Content -Path (Join-Path $out 'osd.log') -Encoding UTF8
    $osdlog | ForEach-Object { $_ }
    if ($osdrc -ne 0) { $bad++ }
}

Write-Output ''
Write-Output ('=' * 72)
if ($bad -eq 0) { Write-Output '=== OVERALL: DEBAYER + DISPLAY PATH AS EXPECTED ===' }
else            { Write-Output ("=== OVERALL: " + $bad + " PROBLEM(S) ===") }
exit $bad
