# ============================================================
#  serial_daemon.ps1 —— 串口守护（独占 COM19，写日志文件，供多人同时查看）
#
#  为什么要它：串口是独占资源，谁打开谁占用。这个脚本**只开一次**、
#  一直把收到的数据追加到日志文件；其他人（你和 Lead）都用
#  "看文件"的方式读，互不打扰。
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\serial_daemon.ps1
#     （后台跑，Ctrl+C 停止）
#
#  看输出（另开一个窗口，不占串口）：
#     Get-Content D:\FPGA\mmt\out\serial.log -Wait -Tail 30
#  或直接用记事本打开 D:\FPGA\mmt\out\serial.log
# ============================================================
param(
    [string]$Port = 'COM19',
    [int]   $Baud = 115200,
    [string]$Log  = 'D:\FPGA\mmt\out\serial.log',
    [int]   $MaxMB = 5            # 日志超过这个大小就轮转一份 .1
)

$ErrorActionPreference = 'Continue'
$dir = Split-Path $Log -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

function Log-Write([string]$text) {
    # 轮转
    if ((Test-Path $Log) -and ((Get-Item $Log).Length -gt ($MaxMB * 1MB))) {
        Move-Item $Log "$Log.1" -Force
    }
    Add-Content -Path $Log -Value $text -Encoding UTF8
    Write-Host $text -NoNewline
}

while ($true) {
    try {
        $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
        $sp.ReadTimeout = 500
        $sp.Open()
        Log-Write "[$(Get-Date -Format 'HH:mm:ss')] === 串口 $Port @$Baud 已打开 ===`n"
        while ($sp.IsOpen) {
            try {
                $chunk = $sp.ReadExisting()
                if ($chunk -and $chunk.Length -gt 0) { Log-Write $chunk }
            } catch { }
            Start-Sleep -Milliseconds 50
        }
    } catch {
        Log-Write "[$(Get-Date -Format 'HH:mm:ss')] !! 打不开 $Port : $($_.Exception.Message) （5 秒后重试）`n"
        Start-Sleep -Seconds 5
    } finally {
        if ($sp) { try { $sp.Close(); $sp.Dispose() } catch { } }
    }
}
