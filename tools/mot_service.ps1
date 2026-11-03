# mot_service.ps1 - watchdog (HTTP health check)
$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script = Join-Path $root "tools\web_monitor.py"
$outdir = Join-Path $root "out\live"
New-Item -ItemType Directory -Force -Path $outdir | Out-Null
$svclog = Join-Path $outdir "service.log"
while ($true) {
    $ok = $false
    try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:8090/api/status" -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { $ok = $true } } catch { $ok = $false }
    if (-not $ok) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $svclog -Value "$ts restart web_monitor"
        $arg = '-3 -u "' + $script + '" --port COM15 --http 8090 --out "' + $outdir + '"'
        Start-Process -FilePath "py" -ArgumentList $arg -WindowStyle Hidden -RedirectStandardOutput (Join-Path $outdir "monitor_stdout.log") -RedirectStandardError (Join-Path $outdir "monitor_stderr.log")
        Start-Sleep -Seconds 8
    }
    Start-Sleep -Seconds 10
}