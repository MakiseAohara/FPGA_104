# ==========================================================================
#  make_shim_src.ps1 -- build the iverilog-compatible copy of the vendor
#                      frame_buffer sources under %TEMP%\frame_wr_sim\src
# --------------------------------------------------------------------------
#  rtl\ is NEVER modified.  Three minimal, documented, semantics-preserving
#  edits are applied to the copy:
#
#   1) ddr_wr_buffer.v  {(ddr_awlen+1) ,...}  ->  (ddr_awlen+9'd1)
#   2) ddr_rd_buffer.v  {(ddr_arlen+1) ,...}  ->  (ddr_arlen+9'd1)
#      iverilog rejects an unsized literal inside a concatenation
#      ("indefinite width"); -g2005 / -g2009 / -g2012 all reject it.
#      Value identical for every awlen/arlen <= 255.
#
#   3) DC_FIFO.v GrayDecode: `always @ (GrayIn)` has an INCOMPLETE sensitivity
#      list, so iverilog never evaluates the block when GrayIn does not toggle
#      and leaves HexOut = X.  That makes WrDNum/RdDNum X, and
#      `wr_req = (wr_fifo_rdusedw > ddr_awlen)` X (false) -> the write FSM
#      never issues AW at all.  Synthesis ignores the sensitivity list and
#      infers pure combinational logic, so the identical function is written
#      as a continuous assignment -- i.e. this makes the model match hardware.
#
#  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File make_shim_src.ps1
# ==========================================================================

$ErrorActionPreference = 'Continue'

$simRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $simRoot)
$RTLD    = Join-Path $root 'rtl\frame_buffer'
$out     = Join-Path $env:TEMP 'frame_wr_sim'
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
