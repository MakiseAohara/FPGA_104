# 下载 COCO parquet 分片（带重试，可断点续传）
$ErrorActionPreference = 'Continue'
$dl = 'D:\FPGA\mmt\work_v29\data\coco'
$tree = Get-Content 'D:\FPGA\mmt\work_v29\dl\coco_tree.json' -Raw | ConvertFrom-Json
$base = 'https://hf-mirror.com/datasets/detection-datasets/coco/resolve/main/'

# 选择：val 全部 2 个 + train 前 16 个
$want = @()
$want += ($tree | Where-Object path -match 'val-')
$want += ($tree | Where-Object path -match 'train-' | Select-Object -First 16)

foreach ($item in $want) {
    $name = Split-Path $item.path -Leaf
    $out = Join-Path $dl $name
    $expect = [int64]$item.size
    if ((Test-Path $out) -and ((Get-Item $out).Length -ge $expect)) { Write-Host "SKIP $name ($([math]::Round($expect/1MB)) MB)"; continue }
    $ok = $false
    for ($try = 1; $try -le 10; $try++) {
        & curl.exe -4 -sL -C - --max-time 900 -o $out ($base + $item.path + '?download=true')
        $sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
        if ($sz -ge $expect) { Write-Host "OK   $name $([math]::Round($sz/1MB,1)) MB (try $try)"; $ok = $true; break }
        else { Write-Host "retry $name try=$try got=$([math]::Round($sz/1MB,1)) MB / $([math]::Round($expect/1MB,1)) MB"; Start-Sleep -Seconds (10 + 5*$try) }
    }
    if (-not $ok) { Write-Host "FAIL $name" }
}
Write-Host '=== DONE ==='
Get-ChildItem $dl | Select-Object Name, Length | Format-Table -AutoSize
