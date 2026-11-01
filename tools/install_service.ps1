# install_service.ps1 - register ONLOGON scheduled task (current user, no admin)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$svc = Join-Path $root "tools\mot_service.ps1"
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$svc"""
schtasks /Create /TN "MMT_WebMonitor" /TR $cmd /SC ONLOGON /RL LIMITED /F
schtasks /Run /TN "MMT_WebMonitor"
Write-Host "registered + started: MMT_WebMonitor"
Write-Host "query:  schtasks /Query /TN MMT_WebMonitor"
Write-Host "stop:   schtasks /End /TN MMT_WebMonitor ; schtasks /Delete /TN MMT_WebMonitor /F"