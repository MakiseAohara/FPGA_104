# ==========================================================================
#  flash_mmt.ps1 —— Ti60F225 位流烧录（JTAG / hiftdi 后端），含全部前置检查
# --------------------------------------------------------------------------
#  为什么要有这个脚本：交接提示词里记了 4 个"缺一个就烧不进去或蓝屏"的前提，
#  以及一次"上过板但没留串口日志"的流程事故。这个脚本把前提全部显式化，
#  并且**打印位流时间戳**，防止烧到旧位流。
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\flash_mmt.ps1
#     powershell ... -File .\flash_mmt.ps1 -Bit D:\FPGA\mmt\out\mmt.bit
#
#  成功判据（脚本会自动检查）：
#     Device ID read from JTAG: 0x10660A79
#     finished with JTAG programming
# ==========================================================================
param(
    [string]$Bit    = 'D:\FPGA\mmt\out\mmt.bit',
    [string]$Board  = 'Generic Board Profile Using FT4232H',
    [string]$Efinity = 'D:\Efinity\2026.1',
    [switch]$Force           # 跳过 FTDI 驱动版本检查（不推荐）
)

$ErrorActionPreference = 'Continue'
$fail = New-Object System.Collections.Generic.List[string]

Write-Host "=== Ti60F225 烧录前置检查 ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ===" -ForegroundColor Cyan

# ---------- ① 位流存在 + 时间戳 ----------
if (-not (Test-Path $Bit)) {
    Write-Host "  FAIL 找不到位流：$Bit" -ForegroundColor Red; exit 1
}
$bi = Get-Item $Bit
Write-Host ""
Write-Host "  位流      : $($bi.FullName)"
Write-Host "  大小      : $($bi.Length) B"
Write-Host "  时间戳    : $($bi.LastWriteTime)   <-- 等下和预期核对，别烧到旧版" -ForegroundColor Yellow

# 若同目录还有别的候选位流，列出来便于比对
$others = Get-ChildItem (Split-Path $Bit -Parent) -Filter *.bit -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -ne $bi.FullName }
if ($others) {
    Write-Host "  同目录其它 .bit：" -ForegroundColor Yellow
    $others | ForEach-Object { Write-Host "      $($_.LastWriteTime)  $($_.Name)  $($_.Length) B" }
}

# 位流比源码旧就警告（防"改了 RTL 却烧旧位流"）
$newerSrc = Get-ChildItem 'D:\FPGA\mmt\rtl','D:\FPGA\mmt\sw' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $bi.LastWriteTime -and $_.Extension -match '\.(v|sv|vh|c|h|S)$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
if ($newerSrc) {
    $fail.Add("位流比这些源文件旧（改了源码没重构建？）：")
    foreach ($f in $newerSrc) { $fail.Add("      $($f.LastWriteTime)  $($f.FullName)") }
} else {
    Write-Host "  OK       位流不旧于任何 rtl/sw 源文件" -ForegroundColor Green
}

# ---------- ①b 位流必须晚于本次 PnR（指挥官指令 #10 之 1c）----------
# 事故背景（2026-10-16）：PnR 因器件容量不足失败，但外层仍用遗留的 work_pnr\mmt.lbf
# 打出了旧位流 —— 文件时间戳是新的、内容却是旧的。此判据专防这一类。
$pnrLog = 'D:\FPGA\mmt\out\efx_pnr.log'
$lbfDir = 'D:\FPGA\mmt\work_pnr'
$stale = $false
if (Test-Path $pnrLog) {
    $pnrTime = (Get-Item $pnrLog).LastWriteTime
    Write-Host "  PnR 日志时间戳 : $pnrTime"
    if ($bi.LastWriteTime -lt $pnrTime) {
        $fail.Add("位流早于 efx_pnr.log（位流 $($bi.LastWriteTime) < PnR $pnrTime）⇒ 拒绝烧录")
        $stale = $true
    } else {
        Write-Host "  OK       位流晚于 efx_pnr.log" -ForegroundColor Green
    }
} else {
    $fail.Add("找不到 out\efx_pnr.log，无法确认位流是否本次构建产物 ⇒ 拒绝烧录")
    $stale = $true
}
# 同时：work_pnr 下不能有比位流更新的 .lbf（说明位流不是它打的）
$newerLbf = Get-ChildItem $lbfDir -Filter *.lbf -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $bi.LastWriteTime }
if ($newerLbf) {
    $fail.Add("work_pnr 下有比位流更新的 .lbf ⇒ 位流不是最新 PnR 的产物：")
    foreach ($f in $newerLbf) { $fail.Add("      $($f.LastWriteTime)  $($f.FullName)") }
    $stale = $true
}
if (-not $stale) { Write-Host "  OK       位流是本次 PnR 之后的产物" -ForegroundColor Green }

# ---------- ② FTDI 驱动版本必须统一（否则 0x000000FC 蓝屏）----------
Write-Host ""
Write-Host "--- FTDI 驱动版本（ftdibus / ftdiport 必须同版本；踩过两次蓝屏 0x000000FC）---"
if (-not $Force) {
    try {
        $drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
               Where-Object { $_.DeviceName -match 'FTDI|USB Serial|FT4232' -or $_.DriverProviderName -match 'FTDI' } |
               Select-Object DeviceName, DriverVersion, DriverProviderName
        if (-not $drv) {
            Write-Host "      (未枚举到 FTDI 驱动；板子没插？)" -ForegroundColor Yellow
        } else {
            $drv | Format-Table -AutoSize | Out-String | Write-Host
            $vers = $drv.DriverVersion | Sort-Object -Unique
            if ($vers.Count -gt 1) {
                $fail.Add("FTDI 驱动版本不一致：$($vers -join ' / ')  ⇒ 可能蓝屏 0x000000FC，先统一再烧")
            } elseif ($vers[0] -ne '2.12.36.4') {
                Write-Host "      注意：版本是 $($vers[0])，已知可用版本是 2.12.36.4（仅提示，不阻塞）" -ForegroundColor Yellow
            } else {
                Write-Host "  OK       FTDI 驱动版本统一且为已知可用版本 $($vers[0])" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "      (驱动枚举失败：$($_.Exception.Message))" -ForegroundColor Yellow
    }
} else {
    Write-Host "      (已用 -Force 跳过)" -ForegroundColor Yellow
}

# ---------- ③ Efinity 运行环境（★ 2026-10-15 实测新增）----------
#  交接/文档里那段命令「只设 EFX_HIFTDI_ENABLE 然后调 python3.bat」在**干净 shell 里跑不起来**，
#  实测两次失败：
#    ① 只设 EFX_HIFTDI_ENABLE → "Fatal Python error: init_fs_encoding ... No module named 'encodings'"
#       （PYTHONHOME 缺省，Python 把 prefix 猜成 D:\Efinity\2026.1）
#    ② 补上 PYTHONHOME 后 → "KeyError: 'EFXPGM_HOME'"（efx_dbg\openocd_manager.py:44 要这个变量）
#  补齐下面 6 个变量后，命令能一路走到 JTAG 连接阶段
#  （无板子时报 "ERROR: No USB target detected, aborting!" —— 这就是链路正常的标志）。
Write-Host ""
Write-Host "--- Efinity 运行环境 ---"
$env:EFINITY_HOME                 = ($Efinity -replace '\\','/')
$env:EFINITY_USER_DIR_INI         = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFINITY_USER_DIR             = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity'
$env:EFXPT_HOME                   = "$($env:EFINITY_HOME)/pt"
$env:EFXPGM_HOME                  = "$($env:EFINITY_HOME)/pgm"
$env:EFXDBG_HOME                  = "$($env:EFINITY_HOME)/debugger"
$env:EFXIPM_HOME                  = "$($env:EFINITY_HOME)/ipm"
$env:PYTHONHOME                   = "$($env:EFINITY_HOME)/python311"
$env:QT_PLUGIN_PATH               = "$($env:EFINITY_HOME)/bin"
$env:QT_QPA_PLATFORM_PLUGIN_PATH  = "$($env:EFINITY_HOME)/python311/platforms"
$env:PATH                         = "$($env:EFINITY_HOME)/python311/bin;$($env:EFINITY_HOME)/bin;$($env:EFINITY_HOME)/scripts;" + $env:PATH
$env:EFX_HIFTDI_ENABLE            = "1"
Write-Host "  OK       PYTHONHOME / EFXPGM_HOME / EFXDBG_HOME / EFXPT_HOME / EFXIPM_HOME 已设" -ForegroundColor Green
Write-Host "  OK       已设 `$env:EFX_HIFTDI_ENABLE = 1（否则报 No Board Profile Selected）" -ForegroundColor Green

# ---------- ④ 工具与脚本存在 ----------
$py = Join-Path $Efinity 'bin\python3.bat'
$prog = Join-Path $Efinity 'pgm\bin\efx_pgm\ftdi_program.py'
foreach ($p in @($py, $prog)) {
    if (Test-Path $p) { Write-Host "  OK       存在：$p" -ForegroundColor Green }
    else { $fail.Add("找不到：$p") }
}

if ($fail.Count -gt 0) {
    Write-Host ""
    foreach ($f in $fail) { Write-Host "  FAIL  $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "前置检查未通过，未执行烧录。" -ForegroundColor Red
    exit 2
}

# ---------- 执行烧录 ----------
Write-Host ""
Write-Host "=== 开始烧录（JTAG）===" -ForegroundColor Cyan
Write-Host "  注意：必须传 .bit，传 .hex 会报格式错" -ForegroundColor Yellow
Write-Host ""

$logDir = Join-Path (Split-Path $Bit -Parent) 'flash_logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("flash_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$out = & $py $prog $Bit -m jtag -b $Board 2>&1
$out | Tee-Object -FilePath $log | ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "=== 判据检查 ===" -ForegroundColor Cyan
$text = ($out | Out-String)
$okId  = $text -match 'Device ID read from JTAG:\s*0x10660A79'
$okFin = $text -match 'finished with JTAG programming'
Write-Host ("  {0}  Device ID read from JTAG: 0x10660A79" -f $(if($okId){'PASS'}else{'FAIL'})) -ForegroundColor $(if($okId){'Green'}else{'Red'})
Write-Host ("  {0}  finished with JTAG programming" -f $(if($okFin){'PASS'}else{'FAIL'})) -ForegroundColor $(if($okFin){'Green'}else{'Red'})
Write-Host "  原始日志：$log"

# ---------- 提醒：串口 ----------
Write-Host ""
Write-Host "下一步：另开一个窗口开串口守护（COM19 @115200），再上电/复位：" -ForegroundColor Cyan
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sw\serial_daemon.ps1" -ForegroundColor White
Write-Host "  看输出（不占串口）：" -ForegroundColor Cyan
Write-Host "    Get-Content D:\FPGA\mmt\out\serial.log -Wait -Tail 30" -ForegroundColor White

if ($okId -and $okFin) { exit 0 } else { exit 1 }
