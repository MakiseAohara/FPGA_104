# ==========================================================================
#  disasm_demo.ps1 -- quick RISC-V word scanner for the Efinity demo firmware
# --------------------------------------------------------------------------
#  The SoC RAM init files (*.v_toplevel_system_ramA_logic_ram_symbolN.bin)
#  are plain ASCII: one line per byte, 8 characters of '0'/'1'.
#  Word at RAM word index i = {symbol3[i], symbol2[i], symbol1[i], symbol0[i]}
#  (little endian), and the RAM lives at 0xF9000000 (8 KB).
#
#  This script reassembles the words and reports, for a chosen LUI base,
#  which loads/stores touch it -- that is how the demo's real peripheral
#  addresses and register offsets were recovered.
#
#  Usage:
#    powershell -File disasm_demo.ps1 -IpDir <sapphire_soc dir> -Base 0xF8010000
#
#  NOTE: keep everything in [int64]. Casting a value with bit31 set to
#  [uint32] in PowerShell throws, and the intermediate -bor result is Int32.
# ==========================================================================
param(
    [string]$IpDir = 'D:\FPGA\mmt\ip\sapphire_soc',
    [string]$Base  = '0xF8010000',
    [int]$Window   = 48
)

$ErrorActionPreference = 'Continue'

function Get-Word64([string[]]$l0, [string[]]$l1, [string[]]$l2, [string[]]$l3, [int]$i) {
    $b0 = [Convert]::ToInt32($l0[$i], 2)
    $b1 = [Convert]::ToInt32($l1[$i], 2)
    $b2 = [Convert]::ToInt32($l2[$i], 2)
    $b3 = [Convert]::ToInt32($l3[$i], 2)
    return [int64]$b0 + [int64]$b1 * 256 + [int64]$b2 * 65536 + [int64]$b3 * 16777216
}

function Sx([int64]$v, [int]$bits) {
    $m = [int64]1 -shl ($bits - 1)
    if ($v -band $m) { return $v - ([int64]1 -shl $bits) } else { return $v }
}

$l0 = [System.IO.File]::ReadAllLines((Join-Path $IpDir 'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol0.bin'))
$l1 = [System.IO.File]::ReadAllLines((Join-Path $IpDir 'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol1.bin'))
$l2 = [System.IO.File]::ReadAllLines((Join-Path $IpDir 'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol2.bin'))
$l3 = [System.IO.File]::ReadAllLines((Join-Path $IpDir 'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol3.bin'))
$N  = $l0.Count

$words = New-Object 'int64[]' $N
for ($i = 0; $i -lt $N; $i++) { $words[$i] = Get-Word64 $l0 $l1 $l2 $l3 $i }

# how much of the 8 KB actually carries code/data
$last = -1
for ($i = $N - 1; $i -ge 0; $i--) { if ($words[$i] -ne 0) { $last = $i; break } }
Write-Output ("RAM words present = {0} of {1};  highest non-zero word = {2} -> at least {3} bytes used" -f `
    $N, $N, $last, (($last + 1) * 4))

$target = [int64][uint32]([Convert]::ToUInt32($Base, 16))
Write-Output ("Looking for LUI {0:X8} ..." -f $target)

for ($i = 0; $i -lt $N; $i++) {
    $x = $words[$i]
    if (($x -band 0x7F) -ne 0x37) { continue }
    if (($x -band 0xFFFFF000) -ne $target) { continue }

    $reg = [int](($x -shr 7) -band 0x1F)
    Write-Output ("  LUI {0:X8} -> x{1}   @ word {2} (VA 0x{3:X8})" -f $target, $reg, $i, (0xF9000000 + $i * 4))

    $stop = [Math]::Min($i + $Window, $N)
    for ($j = $i + 1; $j -lt $stop; $j++) {
        $y  = $words[$j]
        $op = $y -band 0x7F
        $f3 = ($y -shr 12) -band 7
        $r1 = ($y -shr 15) -band 0x1F
        $rd = ($y -shr 7)  -band 0x1F
        $simm = Sx (((($y -shr 25) -band 0x7F) -shl 5) -bor (($y -shr 7) -band 0x1F)) 12
        $iimm = Sx (($y -shr 20) -band 0xFFF) 12
        if (($op -eq 0x23 -or $op -eq 0x03) -and $r1 -eq $reg) {
            $kind = if ($op -eq 0x23) { 'STORE' } else { 'LOAD ' }
            $sz   = @('byte', 'half', 'word', '?')[ $f3 -band 3 ]
            if ($f3 -eq 7) { $sz = 'byteu' }
            Write-Output ("     +{0,3}: {1} {2,-5} off=0x{3:X}   @0x{4:X8}" -f ($j - $i), $kind, $sz, $simm, (0xF9000000 + $j * 4))
        }
        if ($op -eq 0x13 -and $rd -eq $reg -and $r1 -eq $reg -and $f3 -le 1) {
            Write-Output ("     +{0,3}: ADDI  x{1} += {2} (0x{3:X})" -f ($j - $i), $reg, $iimm, $iimm)
        }
    }
}
