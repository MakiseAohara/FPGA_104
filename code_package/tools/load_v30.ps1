# load_v30.ps1 — 一键：烧 MERGE17 位流 → 下载 v30 固件 → 等 MMT_LOAD_PASS → 打开 mot_view.py --live
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File FPGA_104\tools\load_v30.ps1
#        [-Bit <位流>] [-Fw <固件>] [-Port COM15] [-NoView]
param(
    [string]$Bit  = "",
    [string]$Fw   = "",
    [string]$Port = "COM15",
    [switch]$NoView
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # FPGA_104\
if (-not $Bit) { $Bit = Join-Path $root "evidence\v29_rtl_ir_rot\v7_MERGE17.bit" }
if (-not $Fw)  { $Fw  = Join-Path $root "evidence\v30_mot\fw_v30_final.bin" }
$sha = "3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF"

Write-Host "=== 1/3 烧位流 ===" -ForegroundColor Cyan
$src = Join-Path $root "tools\flash_vendor.ps1"
$tmp = Join-Path $env:TEMP "flash_vendor_utf8.ps1"
[IO.File]::WriteAllText($tmp, [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))
& powershell -NoProfile -ExecutionPolicy Bypass -File $tmp -Bit $Bit -Sha256 $sha -Force
if ($LASTEXITCODE -ne 0) { Write-Host "位流烧录失败，停止" -ForegroundColor Red; exit 1 }

Write-Host "=== 2/3 下载固件（必须等到 MMT_LOAD_PASS）===" -ForegroundColor Cyan
$out = Join-Path $env:TEMP "v30_run"
$log = & py -3 -u (Join-Path $root "evidence\v30_mot\load_retry.py") --image $Fw --out $out --capture-seconds 0 --attempts 6 2>&1 | Tee-Object -Variable lines
$lines | Select-Object -Last 6
if (-not ($lines -match "MMT_LOAD_PASS")) { Write-Host "没等到 MMT_LOAD_PASS，重来一次" -ForegroundColor Red; exit 2 }
Write-Host "MMT_LOAD_PASS 确认" -ForegroundColor Green

if (-not $NoView) {
    Write-Host "=== 3/3 打开查看窗口 ===" -ForegroundColor Cyan
    Start-Process py -ArgumentList "-3", (Join-Path $root "tools\mot_view.py"), "--live", $Port
}