# ==========================================================================
#  build_rv32_test.ps1 -- build a bare-metal RV32 test program for rv32sim
# --------------------------------------------------------------------------
#  Produces  build\<name>.elf / .bin / .map  next to the source, plus a
#  <name>.sym file (symbol name -> address) so the emulator can find entry
#  points without parsing ELF.
#
#  NOTE ON POWERSHELL QUOTING
#  --------------------------
#  Bare "-Wl,-Ttext=0" is parsed by PowerShell as a *list* (the comma is an
#  array separator), which fails with "Missing argument in parameter list".
#  Every toolchain flag must therefore be a properly quoted array element.
#
#  Usage:  powershell -File build_rv32_test.ps1 -Src test\t_smoke.c
# ==========================================================================
param(
    [Parameter(Mandatory=$true)][string]$Src,
    [string]$Name    = '',
    [string]$Base    = '0x00000000',
    [string]$Entry   = '_start',
    [string[]]$Inc   = @(),
    [string[]]$SrcMore = @(),
    [switch]$UseLibm,
    [switch]$UseNosys,
    [string[]]$Extra = @()
)
$ErrorActionPreference = 'Continue'

$sw    = $PSScriptRoot                          # ...\mmt\sw (this script lives there)
$tc    = 'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
$gcc   = Join-Path $tc 'riscv-none-elf-gcc.exe'
$objc  = Join-Path $tc 'riscv-none-elf-objcopy.exe'
$nm    = Join-Path $tc 'riscv-none-elf-nm.exe'
$size  = Join-Path $tc 'riscv-none-elf-size.exe'

if (-not (Test-Path $gcc)) { Write-Output "!! toolchain not found: $gcc"; exit 1 }
if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Src) }

$srcAbs = if ([IO.Path]::IsPathRooted($Src)) { $Src } else { Join-Path $sw $Src }
if (-not (Test-Path $srcAbs)) { Write-Output "!! source not found: $srcAbs"; exit 1 }

$out = Join-Path $sw ('test\build')
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
$elf = Join-Path $out "$Name.elf"
$bin = Join-Path $out "$Name.bin"
$sym = Join-Path $out "$Name.sym"

# rv32im (NO compressed) so rv32sim's decoder matches.
# NOTE: do NOT build an array element by concatenation inline --
#       @( ..., '-Wl,-Map=' + $p ) is parsed as TWO elements and gcc then
#       complains "no file/directory name provided for map output".
$mapArg = '-Wl,-Map=' + (Join-Path $out "$Name.map")
$cflags = @(
    '-march=rv32im', '-mabi=ilp32',
    '-Os', '-ffreestanding', '-fno-builtin', '-fno-stack-protector',
    "-Wl,-Ttext=$Base", "-Wl,--entry=$Entry",
    $mapArg
)
if ($UseNosys) { $cflags += '--specs=nosys.specs' } else { $cflags += '-nostdlib' }
# ★ -nostartfiles is needed in BOTH cases: with --specs=nosys.specs the linker
#   otherwise pulls in crt0.o, which defines its own _start and demands a
#   `main` symbol -- conflicting with the test's own _start entry point.
$cflags += '-nostartfiles'
foreach ($d in $Inc) { $cflags += @('-I', $d) }
$cflags += $Extra

$srcs = @($srcAbs)
foreach ($s in $SrcMore) {
    $a = if ([IO.Path]::IsPathRooted($s)) { $s } else { Join-Path $sw $s }
    if (-not (Test-Path $a)) { Write-Output "!! extra source not found: $a"; exit 1 }
    $srcs += $a
}

# ★ Libraries must come AFTER the objects that reference them (GNU ld is a
#   single-pass linker). Putting -lm in $cflags before $srcs gives
#   "undefined reference to `sqrt'" even though libm is installed.
$libs = @()
if ($UseLibm) { $libs += '-lm' }

$args1 = $cflags + @('-o', $elf) + $srcs + $libs
Write-Output ('gcc ' + ($args1 -join ' '))
& $gcc @args1 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { Write-Output "!! compile failed ($LASTEXITCODE)"; exit 1 }

& $objc -O binary $elf $bin
if ($LASTEXITCODE -ne 0) { Write-Output '!! objcopy failed'; exit 1 }

# symbol dump: "addr type name"  ->  "name addr"
$lines = & $nm $elf
$lines | Where-Object { $_ -match '^[0-9a-fA-F]{8}' } | ForEach-Object {
    $p = $_ -split '\s+'
    if ($p.Count -ge 3) { '{0} {1}' -f $p[2], $p[0] }
} | Set-Content -Encoding ascii $sym

Write-Output ''
Write-Output ('elf : {0}' -f $elf)
Write-Output ('bin : {0}  ({1} bytes)' -f $bin, (Get-Item $bin).Length)
Write-Output ('sym : {0}' -f $sym)
& $size $elf
exit 0
