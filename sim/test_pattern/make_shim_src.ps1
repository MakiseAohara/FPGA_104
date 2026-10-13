# ==========================================================================
#  make_shim_src.ps1 -- iverilog-compatible copy of the vendor frame_buffer
#                       sources, for the M0 test-pattern simulation
# --------------------------------------------------------------------------
#  rtl\ is NEVER modified.  A copy of rtl\frame_buffer\*.v is written to
#  %TEMP%\test_pattern_sim\src\ with three minimal, documented,
#  semantics-preserving edits (identical to the ones justified in
#  docs\帧缓冲写通路RTL仿真.md §2):
#
#   1) ddr_wr_buffer.v  {(ddr_awlen+1) ,...}  ->  (ddr_awlen+9'd1)
#   2) ddr_rd_buffer.v  {(ddr_arlen+1) ,...}  ->  (ddr_arlen+9'd1)
#      iverilog rejects an unsized literal inside a concatenation
#      ("indefinite width"); value unchanged for every awlen/arlen <= 255.
#
#   3) DC_FIFO.v GrayDecode: `always @ (GrayIn)` has an INCOMPLETE sensitivity
#      list -> iverilog never evaluates it when GrayIn does not toggle, so
#      HexOut stays X, WrDNum/RdDNum become X and the write FSM never issues
#      AW.  Synthesis infers pure combinational logic, so the identical
#      function is written as a continuous assignment.
# ==========================================================================

$ErrorActionPreference = 'Continue'

$simRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $simRoot)
$RTLD    = Join-Path $root 'rtl\frame_buffer'
$out     = Join-Path $env:TEMP 'test_pattern_sim'
$src     = Join-Path $out 'src'

Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $src | Out-Null
Copy-Item (Join-Path $RTLD '*.v') $src -Force

$grayBody = @(
    '  // [SIM SHIM] original is `always @ (GrayIn)` with an incomplete',
    '  // sensitivity list: iverilog never evaluates it when GrayIn does not',
    '  // toggle, leaving HexOut = X.  Synthesis infers pure combinational',
    '  // logic, so the identical function is expressed directly here.',
    '  wire [DW_C-1:0] gs1 = GrayIn ^ (GrayIn >> 1);',
    '  wire [DW_C-1:0] gs2 = gs1 ^ (gs1 >> 2);',
    '  wire [DW_C-1:0] gs4 = gs2 ^ (gs2 >> 4);',
    '  wire [DW_C-1:0] gs8 = gs4 ^ (gs4 >> 8);',
    '  assign HexOut = gs8;'
) -join "`r`n"

$log = @()
foreach ($f in Get-ChildItem $src -Filter '*.v') {
    $t = [System.IO.File]::ReadAllText($f.FullName)
    $o = $t
    $t = $t -replace '\(ddr_awlen\+1\)', "(ddr_awlen+9'd1)"
    $t = $t -replace '\(ddr_arlen\+1\)', "(ddr_arlen+9'd1)"
    $t = [regex]::Replace($t,
        '(?s)[ \t]*reg \[DW_C-1:0\] Hex;[ \t]*\r?\n.*?assign HexOut = Hex;',
        "`r`n" + $grayBody + "`r`n")
    if ($t -ne $o) {
        [System.IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
        $log += ("shimmed: " + $f.Name)
    }
}
$log | ForEach-Object { Write-Output $_ }
$log | Set-Content -Path (Join-Path $out 'shims_applied.txt') -Encoding UTF8
Write-Output ("shimmed source dir: " + $src)
