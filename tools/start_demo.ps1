# start_demo.ps1 - 一条命令起监控（PC 端）
#   .\tools\start_demo.ps1            # 只开 UDP（网口模式）
#   .\tools\start_demo.ps1 -Port COM15  # 同时读串口
param(
  [string]$Port = "",
  [int]$Udp = 8080,
  [int]$Http = 8081,
  [string]$Out = "out/live"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
$args = @("-3", "tools/web_monitor.py", "--udp", "$Udp", "--http", "$Http", "--out", $Out)
if ($Port -ne "") { $args += @("--port", $Port) }
Write-Host "监控页面: http://127.0.0.1:$Http/" -ForegroundColor Cyan
Write-Host "事件日志: $Out/events.jsonl    缩略图: $Out/thumbs/" -ForegroundColor DarkGray
Start-Process "http://127.0.0.1:$Http/"
py @args
