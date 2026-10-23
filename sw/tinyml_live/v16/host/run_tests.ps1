# run_tests.ps1 — 电脑端一键验证（v16）
#  1) 编译并运行 test_preprocess.c / test_autoexp.c / test_camctrl.c（MinGW gcc）
#  2) 每个测试日志保存到 host\logs\
#  3) 输出 PASS/FAIL 汇总；全部通过时 exit 0
param(
    [string]$Gcc = ""
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$inc  = Join-Path (Split-Path -Parent $root) 'v16'   # sw\tinyml_live\v16
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# 找 gcc
$candidates = @()
if ($Gcc) { $candidates += $Gcc }
$candidates += @(
    'D:\tools\class\mingw64\bin\gcc.exe',
    'C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\gcc.exe',
    'gcc.exe'
)
$gccPath = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { $gccPath = $c; break }
    $w = @(& where.exe $c 2>$null)
    if ($w.Count -gt 0) { $gccPath = $w[0]; break }
}
if (-not $gccPath) {
    Write-Host 'FAIL: 未找到 gcc（可用 -Gcc <path> 指定）' -ForegroundColor Red
    exit 2
}
Write-Host ("gcc: " + $gccPath)
& $gccPath --version 2>&1 | Select-Object -First 1 | ForEach-Object { "      " + $_ }

$tests = @('test_preprocess', 'test_autoexp', 'test_camctrl')
$results = @()
foreach ($t in $tests) {
    $src = Join-Path $root ($t + '.c')
    $exe = Join-Path $logs ($t + '.exe')
    $lg  = Join-Path $logs ($t + '.log')
    Write-Host ("== 编译 " + $t)
    & $gccPath -O2 -std=c99 -Wall -Wextra -I $inc -o $exe $src 2>&1 | Tee-Object -FilePath ($lg + '.build.txt') | ForEach-Object { "   " + $_ }
    $cc = $LASTEXITCODE
    if ($cc -ne 0) {
        $results += [pscustomobject]@{ Test = $t; Compile = $cc; Run = -1; Result = 'FAIL(compile)' }
        continue
    }
    Write-Host ("== 运行 " + $t)
    & $exe 2>&1 | Tee-Object -FilePath $lg | ForEach-Object { "   " + $_ }
    $rc = $LASTEXITCODE
    $txt = @(Get-Content -LiteralPath $lg -EA 0)
    $passLines = @($txt | Where-Object { $_ -match '^PASS' }).Count
    $failLines = @($txt | Where-Object { $_ -match '^FAIL' }).Count
    $result = if ($rc -eq 0 -and $failLines -eq 0) { 'PASS' } else { 'FAIL' }
    $results += [pscustomobject]@{ Test = $t; Compile = 0; Run = $rc; Result = $result;
                                   Pass = $passLines; Fail = $failLines }
}

Write-Host ''
Write-Host '================ 汇总 ================'
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Result -ne 'PASS' })
$summary = Join-Path $logs 'SUMMARY.txt'
$lines = @()
$lines += ('date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$lines += ('gcc : ' + $gccPath)
foreach ($r in $results) {
    $lines += ("{0,-16} {1}  compile={2} run={3}" -f $r.Test, $r.Result, $r.Compile, $r.Run)
}
$lines += ('TOTAL: {0} tests, {1} failed' -f $results.Count, $failed.Count)
$lines | Set-Content -LiteralPath $summary -Encoding UTF8
Write-Host ("SUMMARY: " + $summary)
if ($failed.Count -eq 0) {
    Write-Host 'RESULT: ALL HOST TESTS PASS' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'RESULT: HOST TESTS FAILED' -ForegroundColor Red
    exit 1
}
