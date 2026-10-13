# ==========================================================================
#  run_frame_wr.ps1 -- frame_buffer write-path functional simulation
# --------------------------------------------------------------------------
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File sim\frame_wr\run_frame_wr.ps1
#
#  Compiles the VENDOR frame_buffer chain (rtl\frame_buffer\*.v) together with
#  tb_frame_wr.v and runs three scenarios:
#     VS1-EQ      VS_MODE=1 UNEQUAL=0   i_vs spans the active frame, equal frames
#     VS1-UNEQUAL VS_MODE=1 UNEQUAL=1   alternating frame length  (Q4 control)
#     VS0-EQ      VS_MODE=0 UNEQUAL=0   i_vs is a pulse in the vertical blanking
#
#  ---------------------------------------------------------------------------
#  WHY A SHIMMED SOURCE COPY
#  -------------------------
#  rtl\ is NEVER modified.  A copy of rtl\frame_buffer\*.v is made under
#  %TEMP%\frame_wr_sim\src\ and three minimal, documented edits are applied
#  there.  All three are needed only because iverilog is stricter than the
#  vendor tools / exposes a vendor simulation-only defect:
#
#   1+2) "Concatenation operand has indefinite width"
#        ddr_wr_buffer.v:262   {(ddr_awlen+1) ,...}   -> (ddr_awlen+9'd1)
#        ddr_rd_buffer.v:194   {(ddr_arlen+1) ,...}   -> (ddr_arlen+9'd1)
#        Pure Verilog-2001 syntax accommodation: an unsized literal is illegal
#        in a concatenation for iverilog (-g2005/-g2009/-g2012 all reject it).
#        Value is unchanged for every awlen/arlen <= 255.
#
#   3)  DC_FIFO.v:787 GrayDecode uses `always @ (GrayIn)` -- an INCOMPLETE
#       sensitivity list.  When GrayIn never toggles (exactly what happens for
#       the read-address synchroniser) iverilog never evaluates the block, so
#       HexOut stays X forever, WrDNum/RdDNum become X, and
#       `wr_req = (wr_fifo_rdusedw > ddr_awlen)` becomes X (treated as false)
#       so the write FSM never issues AW.  Synthesis ignores the sensitivity
#       list and infers pure combinational logic, so the shim rewrites the
#       block as the identical continuous assignment -- i.e. it makes the
#       model match what the hardware actually does.  See docs\帧缓冲写通路RTL仿真.md.
#
#  A copy of the shimmed sources and a summary of what changed is left in
#  %TEMP%\frame_wr_sim\ for audit.
# ==========================================================================

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$sim  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $sim)
$RTLD = Join-Path $root 'rtl\frame_buffer'
$out  = Join-Path $env:TEMP 'frame_wr_sim'
$src  = Join-Path $out 'src'

# --------------------------------------------------------------------------
#  build the shimmed source copy
# --------------------------------------------------------------------------
Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $src | Out-Null
Copy-Item (Join-Path $RTLD '*.v') $src -Force

$shimLog = @()
foreach ($f in Get-ChildItem $src -Filter '*.v') {
    $t = [System.IO.File]::ReadAllText($f.FullName)
    $o = $t
    $t = $t -replace '\(ddr_awlen\+1\)', "(ddr_awlen+9'd1)"
    $t = $t -replace '\(ddr_arlen\+1\)', "(ddr_arlen+9'd1)"
    $grayNew = @"
  // [SIM SHIM] original was `always @ (GrayIn)` with an incomplete sensitivity
  // list; iverilog then never evaluates it when GrayIn does not toggle and
  // leaves HexOut = X.  Synthesis infers pure combinational logic, so the same
  // function is expressed directly here.
  wire [DW_C-1:0] sh1 = GrayIn ^ (GrayIn >> 1);
  wire [DW_C-1:0] sh2 = sh1 ^ (sh1 >> 2);
  wire [DW_C-1:0] sh4 = sh2 ^ (sh2 >> 4);
  wire [DW_C-1:0] sh8 = sh4 ^ (sh4 >> 8);
  assign HexOut = sh8;
"@
    $t = [regex]::Replace($t, '(?s)\s*reg \[DW_C-1:0\] Hex;.*?assign HexOut = Hex;', $grayNew)
    if ($t -ne $o) {
        [System.IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
        $shimLog += ("shimmed: " + $f.Name)
    }
}
$shimLog | ForEach-Object { Write-Output $_ }
$shimLog | Set-Content -Path (Join-Path $out 'shims_applied.txt') -Encoding UTF8

$SRC = Get-ChildItem $src -Filter '*.v' | ForEach-Object { $_.FullName }
$TB  = Join-Path $sim 'tb_frame_wr.v'

$scenarios = @(
    @{ Name='VS1-EQ';      Vs=1; Uneq=0; Desc='vs spans active frame, equal frames'      },
    @{ Name='VS1-UNEQUAL'; Vs=1; Uneq=1; Desc='vs spans active frame, UNEQUAL frames (Q4)' },
    @{ Name='VS0-EQ';      Vs=0; Uneq=0; Desc='vs pulse in blanking, equal frames'        }
)

$bad = 0
foreach ($s in $scenarios) {
    $vvp = Join-Path $out ("fw_" + $s.Name + ".vvp")
    $log = Join-Path $out ("res_" + $s.Name + ".log")

    Write-Output ''
    Write-Output ('=' * 74)
    Write-Output ("== " + $s.Name + "  (VS_MODE=" + $s.Vs + " UNEQUAL=" + $s.Uneq + ")  -- " + $s.Desc)
    Write-Output ('=' * 74)

    $cc = @('-g2012', '-s', 'tb_frame_wr', '-o', $vvp,
            ("-DVS_MODE=" + $s.Vs), ("-DUNEQUAL=" + $s.Uneq)) + $SRC + @($TB)
    & "$ivBin\iverilog.exe" @cc 2>&1 | Select-String ': error' | Select-Object -First 5 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]")
        $bad++
        continue
    }

    $runlog = & "$ivBin\vvp.exe" $vvp 2>&1
    $rc = $LASTEXITCODE
    $runlog | Set-Content -Path $log -Encoding UTF8
    $runlog | ForEach-Object { $_ }

    # report the AW address list compactly
    $aws = $runlog | Select-String -Pattern '^\[AW\]'
    Write-Output ("  AW bursts observed: " + $aws.Count)
    if ($aws.Count -gt 0) {
        $aws | Select-Object -First 6 | ForEach-Object { "    " + $_.Line }
    }
    if ($rc -ne 0) { $bad++ }
}

Write-Output ''
Write-Output ('=' * 74)
if ($bad -eq 0) { Write-Output '=== FRAME_WR: ALL SCENARIOS RAN (see per-scenario PASS/FAIL above) ===' }
else            { Write-Output ("=== FRAME_WR: " + $bad + " SCENARIO(S) PROBLEM ===") }
Write-Output 'NOTE: vendor RTL was compiled from a shimmed copy -- see header + docs.'
exit $bad
