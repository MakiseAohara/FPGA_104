# ============================================================================
#  flash_vendor.ps1 —— 烧录【厂商预编译】位流（指挥官指令 #20）
#
#  与 tools\flash_mmt.ps1 的差异（逐条说明，供审查）：
#    【移除】三条"构建溯源"判据 —— 它们只对"我们自己刚构建出的位流"有意义，
#            对厂商 2026-08 预编译的位流必然误拦：
#              ① 位流不旧于 rtl\sw 源文件
#              ② 位流晚于 out\efx_pnr.log
#              ③ work_pnr 下无比位流更新的 .lbf
#    【新增】sha256 白名单校验（更强）：位流哈希必须等于 -Sha256 传入值，否则拒绝。
#    【保留】以下全部安全防护：
#              · 只下 JTAG（-m jtag），绝不碰 SPI 闪存
#              · 拒绝 .hex（.hex 是写 SPI 闪存的格式）
#              · FTDI 驱动版本必须统一（防蓝屏 0x000000FC）
#              · 传 .bit、目标存在、打印大小/时间戳/哈希
#              · 完整执行日志落盘
#
#  用法：
#    powershell -File tools\flash_vendor.ps1 `
#      -Bit 'D:\FPGA\易灵思\工作区\07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\outflow\ti60f225_oob.bit' `
#      -Sha256 '8E2399D808AD0C027B85ED8BEE97BA98604CEC0C8CF43C71E00E8C42128A4ABA'
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Bit,
    [Parameter(Mandatory=$true)][string]$Sha256,
    [string]$Board = 'Generic Board Profile Using FT4232H',
    # 成功判据里必须逐字出现的器件 ID（Ti60F225 板实测值）
    [string]$ExpectDeviceId = '0x10660A79',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$fail = New-Object System.Collections.ArrayList
$logDir = 'D:\FPGA\mmt\out\evidence\vendor_flash_logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host "=== 厂商位流烧录前置检查 ==="

# ---------- ① 必须是 .bit，且不得是 .hex ----------
Write-Host ""
Write-Host "--- ① 文件类型 ---"
if ($Bit -match '\.hex$') {
    Write-Host "  FAIL 拒绝：.hex 是写 SPI 闪存的格式，本脚本只做 JTAG 临时加载" -ForegroundColor Red
    exit 1
}
if ($Bit -notmatch '\.bit$') { $fail.Add("只接受 .bit，收到: $Bit") }
if (-not (Test-Path $Bit)) { Write-Host "  FAIL 找不到位流：$Bit" -ForegroundColor Red; exit 1 }
$bi = Get-Item $Bit
Write-Host "  文件    : $($bi.FullName)"
Write-Host "  大小    : $($bi.Length) B"
Write-Host "  时间戳  : $($bi.LastWriteTime)"

# ---------- ② sha256 白名单（替代 flash_mmt.ps1 的三条构建溯源判据）----------
Write-Host ""
Write-Host "--- ② sha256 校验 ---"
$h = (Get-FileHash $Bit -Algorithm SHA256).Hash
Write-Host "  实际    : $h"
Write-Host "  期望    : $($Sha256.ToUpper())"
if ($h -ne $Sha256.ToUpper()) {
    $fail.Add("sha256 不匹配 ⇒ 拒绝烧录（可能是别的版本/被改过）")
} else {
    Write-Host "  OK       sha256 一致" -ForegroundColor Green
}

# ---------- ③ FTDI 驱动版本必须统一（否则 0x000000FC 蓝屏；踩过两次）----------
Write-Host ""
Write-Host "--- ③ FTDI 驱动版本 ---"
if (-not $Force) {
    try {
        $drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
               Where-Object { $_.DeviceName -match 'FTDI|USB Serial|FT4232' -or $_.DriverProviderName -match 'FTDI' } |
               Select-Object DeviceName, DriverVersion
        if (-not $drv) {
            Write-Host "      (未枚举到 FTDI 驱动；板子没插？)" -ForegroundColor Yellow
            $fail.Add("未枚举到 FTDI 设备 ⇒ 板子可能没插")
        } else {
            $drv | Format-Table -AutoSize | Out-String | Write-Host
            $vers = $drv.DriverVersion | Sort-Object -Unique
            if ($vers.Count -gt 1) { $fail.Add("FTDI 驱动版本不一致：$($vers -join ' / ') ⇒ 可能蓝屏，先统一") }
            elseif ($vers[0] -ne '2.12.36.4') { Write-Host "      注意：版本 $($vers[0])，已知可用 2.12.36.4（仅提示）" -ForegroundColor Yellow }
            else { Write-Host "  OK       FTDI 驱动统一且为已知可用版本 $($vers[0])" -ForegroundColor Green }
        }
    } catch { Write-Host "      (驱动枚举失败：$($_.Exception.Message))" -ForegroundColor Yellow }
}

# ---------- ④ FTDI/JTAG 占用预检（只检查 + 提示，绝不自动杀进程）----------
# 背景：偶发 DEVICE_NOT_OPENED / No such device，疑似串口监听/调试器占着 FT232H 的 JTAG 通道。
# 该异常若出现在编程完成之后（日志已显示 finished with JTAG programming），不影响编程结果。
# 本段只提示，不计入 $fail，不阻断烧录，绝不 Stop-Process。
Write-Host ""
Write-Host "--- ④ FTDI/JTAG 占用预检（只提示，不自动杀进程）---"
$holders = Get-Process -ErrorAction SilentlyContinue |
           Where-Object { $_.ProcessName -match 'openocd|jtag|efinity_dbg|serial_daemon|efx_dbg' }
if ($holders) {
    Write-Host "  提示：以下进程可能占用 FTDI/JTAG，建议先关闭后再烧录（脚本不会自动杀）：" -ForegroundColor Yellow
    $holders | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-String | Write-Host
} else {
    Write-Host "  OK   未发现明显占用 FTDI 的进程" -ForegroundColor Green
}

# ---------- 汇总 ----------
Write-Host ""
if ($fail.Count -gt 0) {
    Write-Host "=== 前置检查未通过，拒绝烧录 ===" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host "=== 前置检查全部通过：只做 JTAG 临时加载，不写 SPI 闪存 ===" -ForegroundColor Green

# ---------- 环境 ----------
$efi = 'D:/Efinity/2026.1'
$env:EFINITY_HOME                = $efi
$env:EFINITY_USER_DIR_INI        = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFINITY_USER_DIR            = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity'
$env:EFXPT_HOME  = "$efi/pt";  $env:EFXPGM_HOME = "$efi/pgm"
$env:EFXDBG_HOME = "$efi/debugger"; $env:EFXIPM_HOME = "$efi/ipm"
$env:PYTHONHOME  = "$efi/python311"
$env:QT_PLUGIN_PATH = "$efi/bin"
$env:QT_QPA_PLATFORM_PLUGIN_PATH = "$efi/python311/platforms"
$env:PATH = "$efi/python311/bin;$efi/bin;$efi/scripts;" + $env:PATH
$env:EFX_HIFTDI_ENABLE = '1'

# ---------- 烧录（-m jtag = JTAG 临时加载）----------
$prog = "$efi/pgm/bin/efx_pgm/ftdi_program.py"
$py   = "$efi/bin/python3.bat"
$ts   = Get-Date -Format 'yyyyMMdd_HHmmss'
$log  = Join-Path $logDir "vendor_flash_$ts.log"
Write-Host ""
Write-Host "=== 烧录中（-m jtag，只下 .bit）==="
# ftdi_program.py 会把正常进度写 stderr。若 $ErrorActionPreference='Stop'，
# PowerShell 会把它包成 NativeCommandError 并抛异常 ⇒ 成功的烧录也 exit 1。
# 修法：调用期间临时降为 Continue，把 stderr 行当普通文本收集；退出码单独留存。
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$nativeExit = $null
try {
    $out = & $py $prog $Bit -m jtag -b $Board 2>&1
    $nativeExit = $LASTEXITCODE
} catch {
    $out = @("EXCEPTION: $($_.Exception.Message)")
    $nativeExit = -1
} finally {
    $ErrorActionPreference = $prevEap
}
# 2>&1 会把 stderr 变成 ErrorRecord；统一展平成纯文本再匹配判据。
$out = @($out | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
})
$out | ForEach-Object { Write-Host "  $_" }
$out | Out-File $log -Encoding UTF8
@(
  "file   : $($bi.FullName)",
  "size   : $($bi.Length)",
  "mtime  : $($bi.LastWriteTime)",
  "sha256 : $h",
  "mode   : jtag (JTAG 临时加载，未写 SPI 闪存)",
  "board  : $Board",
  "expect : Device ID read from JTAG: $ExpectDeviceId + finished with JTAG programming",
  "nativeExit: $nativeExit",
  "ts     : $ts"
) | Out-File $log -Encoding UTF8 -Append
Write-Host ""
Write-Host "  日志: $log"

# ---------- 判据 ----------
# 成功 = 输出里【同时】出现下面两行（器件 ID 逐字匹配 0x10660A79）：
#   Device ID read from JTAG: 0x10660A79
#   finished with JTAG programming
# 缺任一行 ⇒ exit 1。ftdi_program.py 的 stderr 进度文本不影响判据。
$txt = ($out -join "`n")
$okId = $txt -match ('Device ID read from JTAG:\s*' + [regex]::Escape($ExpectDeviceId) + '(?![0-9A-Fa-f])')
$okFin= $txt -match 'finished with JTAG programming'
Write-Host ""
Write-Host "=== 烧录判据 ==="
Write-Host ("  Device ID read from JTAG : " + $(if($okId){'PASS'}else{'FAIL'}) + "  (期望 $ExpectDeviceId)")
Write-Host ("  finished with JTAG programming : " + $(if($okFin){'PASS'}else{'FAIL'}))
Write-Host ("  native exit code (仅参考，不作判据): $nativeExit")
if ($okId) { "  设备 ID: " + [regex]::Match($txt,'Device ID read from JTAG:\s*(0x[0-9A-Fa-f]+)').Groups[1].Value | Write-Host }
if (-not ($okId -and $okFin)) { Write-Host "  烧录未成功，见日志" -ForegroundColor Red; exit 1 }
Write-Host "  烧录成功" -ForegroundColor Green
exit 0
