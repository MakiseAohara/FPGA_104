# ==========================================================================
#  run_frame_addr.ps1 -- frame_buffer write-address RANGE check (task-21)
# --------------------------------------------------------------------------
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File sim\frame_wr\run_frame_addr.ps1
#          powershell ... -File run_frame_addr.ps1 -Only REAL      # one scenario
#
#  Runs tb_frame_addr.v at three frame scales and reports whether the DDR write
#  address stays inside the documented video region [0x02000000, 0x02BDDE00):
#
#     SHORT : 128 x 16   =   2,048 de/frame  (reproduces task-20's 0x02fd2400)
#     MID   : 1920 x 34  =  65,280 de/frame  (~1 min, already shows the breach)
#     REAL  : 1920 x 270 = 518,400 de/frame  (= 1920x1080 / 4 pixels per clock)
#
#  Vendor RTL is compiled from a shimmed copy under %TEMP% (rtl\ is never
#  modified); see make_shim_src.ps1 for the three documented shims.
# ==========================================================================

param([string]$Only = '')

$ErrorActionPreference = 'Continue'

$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$sim = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $env:TEMP 'frame_wr_sim'
$log = Join-Path $sim '_logs'
if (-not (Test-Path $log)) { New-Item -ItemType Directory -Path $log -Force | Out-Null }

# ---- build the shimmed source copy ---------------------------------------
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sim 'make_shim_src.ps1')
$src = Get-ChildItem (Join-Path $out 'src') -Filter '*.v' | ForEach-Object { $_.FullName }
$TB  = Join-Path $sim 'tb_frame_addr.v'

$scen = [ordered]@{
    'SHORT' = @{ H = 128;  V = 16;  F = 8; Desc = '128x16    =   2,048 de/frame' }
    'MID'   = @{ H = 1920; V = 34;  F = 8; Desc = '1920x34   =  65,280 de/frame' }
    'REAL'  = @{ H = 1920; V = 270; F = 6; Desc = '1920x270  = 518,400 de/frame' }
}

$bad = 0
foreach ($k in $scen.Keys) {
    if ($Only -ne '' -and $Only -ne $k) { continue }
    $s = $scen[$k]
    $vvp = Join-Path $out ("addr_" + $k.ToLower() + ".vvp")

    Write-Output ''
    Write-Output ('=' * 74)
    Write-Output ("== " + $k + "  " + $s.Desc)
    Write-Output ('=' * 74)

    $cc = @('-g2012', '-s', 'tb_frame_addr', '-o', $vvp,
            ("-DH_ACTIVE_VAL=" + $s.H), ("-DV_ACTIVE_VAL=" + $s.V),
            ("-DN_FRAMES_VAL=" + $s.F)) + $src + @($TB)
    & "$ivBin\iverilog.exe" @cc 2>&1 | Select-String ': error' | Select-Object -First 5 | ForEach-Object { $_ }
    if ($LASTEXITCODE -ne 0) { Write-Output ("[COMPILE FAILED exit=" + $LASTEXITCODE + "]"); $bad++; continue }

    $runlog = & "$ivBin\vvp.exe" $vvp 2>&1
    $rc = $LASTEXITCODE
    $runlog | Set-Content -Path (Join-Path $log ("addr_" + $k.ToLower() + ".log")) -Encoding UTF8

    $runlog | Select-String -Pattern 'bank bases|documented region|actual 3-bank|^\[FRAME|^\[RELOAD|address range|bytes of the 3rd|AW beyond|first breach|ADDRESS RANGE' |
        ForEach-Object { $_.Line }
    if ($rc -ne 0) { $bad++ }
}

Write-Output ''
Write-Output ('=' * 74)
if ($bad -eq 0) { Write-Output '=== FRAME ADDR: all scenarios ran; logs in sim\frame_wr\_logs ===' }
else            { Write-Output ("=== FRAME ADDR: " + $bad + " scenario(s) failed to run ===") }
exit $bad
