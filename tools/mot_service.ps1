# mot_service.ps1 - watchdog: keep web_monitor.py running (auto restart)
param(
    [string]$Port = "COM15",
    [int]$Http = 8090,
    [string]$Out = "FPGA_104\out\live"
)
$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script = Join-Path $root "tools\web_monitor.py"
$logdir = Join-Path $root "out\live"
New-Item -ItemType Directory -Force -Path $logdir | Out-Null
$log = Join-Path $logdir "service.log"
$py = (Get-Command py -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = "python" }

while ($true) {
    $proc = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like "*web_monitor.py*" }
    if (-not $proc) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $log -Value "$ts starting web_monitor (port=$Port http=$Http)"
        Start-Process -FilePath $py -WindowStyle Hidden -ArgumentList @("-3", "-u", $script, "--port", $Port, "--http", "$Http", "--out", $Out) -RedirectStandardOutput (Join-Path $logdir "monitor_stdout.log") -RedirectStandardError (Join-Path $logdir "monitor_stderr.log")
    }
    Start-Sleep -Seconds 10
}