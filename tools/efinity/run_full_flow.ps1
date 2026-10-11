# ==========================================================================
#  run_full_flow.ps1 -- map -> Interface Designer -> filter -> PnR(with pins)
# --------------------------------------------------------------------------
#  Why the pin constraints need their own pipeline
#  ----------------------------------------------
#  efx_map / efx_pnr do NOT read <project>.peri.xml.  The chain is:
#
#     <project>.peri.xml                       (Interface Designer's state)
#          |  named by <efx:interface_info><efx:peri_file name="..."/>
#          |  in the project XML  (efx_run.py:976-983)
#          v
#     efx_run -f interface   ->  outflow\<design>.interface.csv
#          |  pruned by filter_interface.ps1 (see that script's header for why)
#          v
#     efx_pnr --sync_file <output_dir>\<design>.interface.csv
#
#  mmt.xml was originally missing the whole <efx:interface_info> block, so the
#  peri file sat unused and EVERY I/O came out as "Unassigned Core Pins" in
#  mmt.place.rpt.  That is fixed; this script keeps the whole chain runnable.
#
#  Usage:  powershell -File run_full_flow.ps1
# ==========================================================================
$ErrorActionPreference = 'Continue'

$efi = 'D:/Efinity/2026.1'
$env:EFINITY_HOME         = $efi
$env:EFINITY_USER_DIR_INI = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFINITY_USER_DIR     = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity'
$env:EFXPT_HOME           = "$efi/pt"
$env:EFXPGM_HOME          = "$efi/pgm"
$env:EFXDBG_HOME          = "$efi/debugger"
$env:EFXIPM_HOME          = "$efi/ipm"
$env:PYTHONHOME           = "$efi/python311"
$env:PATH                 = "$efi/python311/bin;$efi/bin;$efi/scripts;" + $env:PATH

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$prj   = 'D:\FPGA\mmt'
$xml   = Join-Path $prj 'mmt.xml'
$out   = Join-Path $prj 'out'
$flow  = Join-Path $prj 'outflow'
$build = Join-Path $here 'build.ps1'
$filt  = Join-Path $here 'filter_interface.ps1'
$topv  = Join-Path $prj 'rtl\mmt\mmt_top.v'

Write-Output '########## [1/4] map + unconstrained PnR (produces out\mmt.vdb) ##########'
& powershell -NoProfile -ExecutionPolicy Bypass -File $build -Xml $xml -Top mmt_top -Name mmt 2>&1 |
    Select-String -Pattern '退出码|XLR count|ERROR' | Select-Object -First 12
if (-not (Test-Path (Join-Path $out 'mmt.vdb'))) {
    Write-Output '!! no out\mmt.vdb -- aborting'; exit 1
}

Write-Output ''
Write-Output '########## [2/4] Interface Designer ##########'
Remove-Item $flow -Recurse -Force -ErrorAction SilentlyContinue
Push-Location $prj
& "$efi/bin/efx_run.bat" mmt --prj -f interface 2>&1 | Select-Object -Last 6
Pop-Location
$rawCsv = Join-Path $flow 'mmt.interface.csv'
if (-not (Test-Path $rawCsv)) { Write-Output '!! Interface Designer produced no csv -- aborting'; exit 2 }

Write-Output ''
Write-Output '########## [3/4] prune stale pins from the constraint file ##########'
& powershell -NoProfile -ExecutionPolicy Bypass -File $filt -Top $topv -In $rawCsv `
    -Out (Join-Path $out 'mmt.interface.csv') 2>&1

Write-Output ''
Write-Output '########## [4/4] PnR with pin constraints ##########'
& powershell -NoProfile -ExecutionPolicy Bypass -File $build -Xml $xml -Top mmt_top -Name mmt -SkipSyn `
    -SyncFile (Join-Path $out 'mmt.interface.csv') 2>&1 |
    Select-String -Pattern '退出码|XLRs:|Memory Blocks|DSP Blocks|Inputs:|Outputs:|ERROR|Required pin' |
    Select-Object -First 20

Write-Output ''
Write-Output '########## unassigned pins (should be only the new ones awaiting the board) ##########'
$rpt = Join-Path $out 'mmt.place.rpt'
$lines = Get-Content $rpt
$idx = ($lines | Select-String -Pattern 'Unassigned Core Pins' | Select-Object -First 1).LineNumber
if ($idx) {
    $list = @()
    for ($i = $idx + 2; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '\|\s*(\S+)\s*\|\s*(Input|Output)\s*\|') { $list += $Matches[1] }
        elseif ($lines[$i] -match '^\s*\+-{10,}\+') { break }
    }
    Write-Output ("{0} unassigned:" -f $list.Count)
    $list | ForEach-Object { Write-Output ('   ' + $_) }
} else {
    Write-Output 'none -- every pin is constrained'
}
exit 0
