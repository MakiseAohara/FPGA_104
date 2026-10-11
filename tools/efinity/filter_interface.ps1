# ==========================================================================
#  filter_interface.ps1 -- drop stale pins from an Efinity interface.csv
# --------------------------------------------------------------------------
#  WHY THIS EXISTS
#  ---------------
#  The Interface Designer builds <design>.interface.csv from <project>.peri.xml.
#  Our peri file is the vendor's, and it still declares the MIPI **DSI TX**
#  (dphy) block -- but we deleted dsi_tx from the RTL (it saved 5,093 XLR / 76
#  BRAM, see README).  The Designer therefore emits lines like
#
#      required output, 172, 323, 0, __bypass__, mipi_dp_clk_RST
#
#  and efx_pnr then hard-fails with
#
#      ERROR : Required pin mipi_dp_clk_RST is not found
#
#  The obvious fix -- delete the <efxpt:mipi_dphy_info> block from the peri
#  file -- makes the Designer itself crash:
#
#      File ".../pt/bin/design/service.py", line 2537, in _build_common_mipi_dphy
#          self.design.mipi_dphy_reg.apply_device_db(self.design.device_db)
#      AttributeError: 'NoneType' object has no attribute 'apply_device_db'
#
#  i.e. when the block is absent _build_block_reg() returns None and the MIPI
#  path has no None guard (its sibling _build_spi_flash_reg at service.py:2568
#  *does* have one).  That is a vendor bug, so patching the installed tool is
#  not attractive.
#
#  Instead: keep the peri file exactly as the vendor shipped it, let the
#  Designer run, and prune from the CSV any pin that the design does not
#  actually have.  This script does that, using the real port list parsed out
#  of the top-level HDL, and REPORTS every line it drops so the result is
#  auditable rather than magic.
#
#  Usage:
#    powershell -File filter_interface.ps1 -Top <top.v> -In <in.csv> -Out <out.csv>
# ==========================================================================
param(
    [Parameter(Mandatory=$true)][string]$Top,
    [Parameter(Mandatory=$true)][string]$In,
    [Parameter(Mandatory=$true)][string]$Out
)
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- parse ports
# Handles both "output [3:0] led" and parameterised widths such as
# "output [ROW_WIDTH-1:0] ddr_addr" (for those we accept any index).
$txt = [System.IO.File]::ReadAllText($Top)
$i = $txt.IndexOf('module ')
if ($i -lt 0) { Write-Output "!! no module declaration in $Top"; exit 1 }
# the header ends at the first line that is just ");"
$m = [regex]::Match($txt.Substring($i), '(?s)^.*?\n\s*\);')
if (-not $m.Success) { Write-Output '!! cannot find end of port list'; exit 1 }
$hdr = $m.Value

$exactAny = @{}      # names where any index is legal (bus / parameterised)
$exact    = @{}      # plain names
$ms = [regex]::Matches($hdr, '(?m)^\s*(?:input|output|inout)\s+(?:wire\s+|reg\s+)?(\[[^\]]+\])?\s*(\w+)\s*[,\)]')
foreach ($p in $ms) {
    $rng  = $p.Groups[1].Value
    $name = $p.Groups[2].Value
    if ([string]::IsNullOrEmpty($rng)) {
        $exact[$name] = $true
    } elseif ($rng -match '^\[(\d+):(\d+)\]$') {
        $hi = [int]$Matches[1]; $lo = [int]$Matches[2]
        for ($k = $lo; $k -le $hi; $k++) { $exact["$name[$k]"] = $true }
        $exact[$name] = $true          # bare name also acceptable
    } else {
        $exactAny[$name] = $true       # e.g. [ROW_WIDTH-1:0] -> any index ok
    }
}
Write-Output ("port list: {0} exact names, {1} any-index buses" -f $exact.Count, $exactAny.Count)

function Test-Port([string]$sig) {
    if ($exact.ContainsKey($sig)) { return $true }
    if ($sig -match '^(\w+)\[\d+\]$' -and $exactAny.ContainsKey($Matches[1])) { return $true }
    return $false
}

# ---------------------------------------------------------------- filter
$inLines = [System.IO.File]::ReadAllLines($In)
$kept = New-Object System.Collections.Generic.List[string]
$dropped = New-Object System.Collections.Generic.List[string]

foreach ($line in $inLines) {
    $t = $line.Trim()
    # comments / blanks / clkout rows (they name clocks, not pins) pass through
    if ($t -eq '' -or $t.StartsWith('#')) { $kept.Add($line); continue }
    if ($t -notmatch '^(required|optional)\b') { $kept.Add($line); continue }

    $parts = $t -split ','
    $sig = $parts[-1].Trim()
    if ($sig -eq '__vcc__' -or $sig -eq '__gnd__') { $kept.Add($line); continue }
    if (Test-Port $sig) { $kept.Add($line); continue }

    $dropped.Add($line)
}

Write-Output ''
if ($dropped.Count -eq 0) {
    Write-Output 'filter: nothing dropped (constraint file already matches the design)'
} else {
    Write-Output ("filter: dropped {0} stale pin line(s):" -f $dropped.Count)
    foreach ($d in $dropped) { Write-Output ('   - ' + $d.Trim()) }
}
[System.IO.File]::WriteAllLines($Out, $kept, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote {0} lines -> {1}" -f $kept.Count, $Out)
exit 0
