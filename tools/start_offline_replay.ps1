$ErrorActionPreference = 'Stop'
$replayRoot = Split-Path -Parent $PSScriptRoot
$replayReady = (& py -3 -c "import socket;s=socket.socket();s.settimeout(1);print(int(s.connect_ex(('127.0.0.1',8092))==0));s.close()").Trim()
if ($replayReady -eq '1') {
    Write-Host 'http://127.0.0.1:8092/'
    exit 0
}
$replayPython = (& py -3 -c 'import sys;print(sys.executable)').Trim()
$replayLogs = Join-Path $replayRoot 'out\offline_replay'
New-Item -ItemType Directory -Force -Path $replayLogs | Out-Null
$replayArgs = @('-X','utf8','-u',('"'+(Join-Path $replayRoot 'tools\mot_replay_server.py')+'"'),'--http','8092')
$replayProcess = Start-Process -FilePath $replayPython -ArgumentList $replayArgs -WorkingDirectory $replayRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $replayLogs 'stdout.log') -RedirectStandardError (Join-Path $replayLogs 'stderr.log')
$replayProcess.Id | Set-Content (Join-Path $replayLogs 'replay.pid')
Write-Host 'http://127.0.0.1:8092/'
