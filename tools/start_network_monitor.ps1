$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$portReady = (& py -3 -c "import socket;s=socket.socket();s.settimeout(1);print(int(s.connect_ex(('127.0.0.1',8090))==0));s.close()").Trim()
if ($portReady -eq '1') {
    Write-Host 'Monitor port is already in use. Open http://169.254.47.62:8090/'
    exit 0
}
$python = (& py -3 -c 'import sys;print(sys.executable)').Trim()
$out = Join-Path $root 'out\network_monitor'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$monitorArgs = @('-X','utf8','-u',('"'+(Join-Path $root 'tools\web_monitor.py')+'"'),
    '--port','COM15','--udp','8080','--http','8090','--public-host','169.254.47.62',
    '--board-url','http://169.254.47.63','--udp-pixel-encoding','uint8','--preview-aspect','16:9',
    '--out',('"'+$out+'"'))
$process = Start-Process -FilePath $python -ArgumentList $monitorArgs -WorkingDirectory $root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $out 'stdout.log') -RedirectStandardError (Join-Path $out 'stderr.log')
$process.Id | Set-Content (Join-Path $out 'monitor.pid')
Write-Host 'http://169.254.47.62:8090/'
