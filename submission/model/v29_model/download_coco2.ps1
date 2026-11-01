# 可靠下载 COCO parquet：先探测是否被 HF 限流（限流响应不是 PAR1），再 Range 续传
$ErrorActionPreference = 'Continue'
$dl = 'D:\FPGA\mmt\work_v29\data\coco'
New-Item -ItemType Directory -Force -Path $dl | Out-Null
$tree = Get-Content 'D:\FPGA\mmt\work_v29\dl\coco_tree.json' -Raw | ConvertFrom-Json
$base = 'https://hf-mirror.com/datasets/detection-datasets/coco/resolve/main/'

function Test-Parquet($path) {
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item $path).Length
    if ($len -lt 1MB) { return $false }
    $fs = [IO.File]::OpenRead($path)
    try {
        $h = New-Object byte[] 4; $fs.Read($h,0,4) | Out-Null
        $fs.Seek(-4,'End') | Out-Null
        $t = New-Object byte[] 4; $fs.Read($t,0,4) | Out-Null
        return ([Text.Encoding]::ASCII.GetString($h) -eq 'PAR1' -and [Text.Encoding]::ASCII.GetString($t) -eq 'PAR1')
    } finally { $fs.Close() }
}

$want = @()
$want += ($tree | Where-Object path -match 'val-')
$want += ($tree | Where-Object path -match 'train-' | Select-Object -First 16)

foreach ($item in $want) {
    $name = Split-Path $item.path -Leaf
    $out = Join-Path $dl $name
    if (Test-Parquet $out) { Write-Host "SKIP(ok) $name"; continue }
    if (Test-Path $out) { Remove-Item $out -Force }
    $url = $base + $item.path + '?download=true'
    $ok = $false
    for ($try = 1; $try -le 30; $try++) {
        # 探测前 4 字节
        $probe = & curl.exe -4 -sL --max-time 60 -r 0-3 $url
        if ($probe -ne 'PAR1') {
            Write-Host "throttled $name try=$try probe='$probe'"; Start-Sleep -Seconds (10 + 3*$try); continue
        }
        & curl.exe -4 -sL -C - --max-time 1200 -o $out $url
        if (Test-Parquet $out) { Write-Host "OK $name $([math]::Round((Get-Item $out).Length/1MB,1)) MB (try $try)"; $ok = $true; break }
        $sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        Write-Host "incomplete $name try=$try size=$([math]::Round($sz/1MB,1)) MB"
        Start-Sleep -Seconds (5 + 2*$try)
    }
    if (-not $ok) { Write-Host "FAIL $name" }
}
Write-Host '=== DONE ==='
Get-ChildItem $dl | Select-Object Name, Length | Format-Table -AutoSize
