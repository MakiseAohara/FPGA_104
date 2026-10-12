# ==========================================================================
#  mkimage.ps1 — 把「DDR 版固件」+「TinyML 模型权重」打成**带头的 flash 镜像**
#                （路线乙′：自建 loader 搬运，不依赖厂商 bootloader）
# --------------------------------------------------------------------------
#  镜像格式（与 sw\ddr\mmt_ddr.h 的 mmt_img_hdr_t 逐字段对应，改一处必须改两处）
#
#      flash 偏移 0                    flash 偏移 64
#      ┌───────────────────┬──────────┬──────────────────────────────┐
#      │ 48 字节镜像头      │ 16B 填充 │ 载荷：app(4字节对齐) + 权重   │
#      └───────────────────┴──────────┴──────────────────────────────┘
#
#  头字段（全部小端 u32）：
#      +0  magic  = 0x31544D4D ("MMT1")
#      +4  version= 1
#      +8  total_size   整个镜像字节数（头+填充+载荷）
#      +12 app_flash_off   app 在载荷内的偏移（= 0）
#      +16 app_ddr_addr    app 搬到 DDR 哪里（= 0x00001000）
#      +20 app_len         app 字节数（4 的倍数，不足补 0）
#      +24 w_flash_off     权重在载荷内的偏移
#      +28 w_ddr_addr      权重搬到 DDR 哪里（= 0x00100000）
#      +32 w_len           权重字节数（4 的倍数）
#      +36 payload_crc     载荷 CRC32（poly 0xEDB88320，init/xorout 0xFFFFFFFF）
#      +40 payload_len     载荷字节数
#      +44 reserved0 = 0
#
#  为什么要有头：loader 只认头里的长度和落点 → 换模型/换内存图**不用重编 loader**。
#
#  用法：
#     powershell -File mkimage.ps1                                  # 只有固件
#     powershell -File mkimage.ps1 -Weights ..\..\weights\model.bin # 固件+权重
#     powershell -File mkimage.ps1 -DryRun                          # 只算尺寸不写文件
#     powershell -File mkimage.ps1 -FlashBase 0x400000              # 换 flash 起始地址
# ==========================================================================
param(
    [string]$App       = '',                                    # 默认 sw\ddr\build\ddr_app.bin
    [string]$Weights   = '',
    [string]$Out       = '',                                    # 默认 sw\ddr\build\ddr_image.bin
    [int]   $FlashBase = 0x380000,
    [int]   $FlashSize = 0x800000,
    [int]   $AppDdr    = 0x00001000,
    [int]   $WeightsDdr= 0x00100000,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $App) { $App = Join-Path $here 'build\ddr_app.bin' }
if (-not $Out) { $Out = Join-Path $here 'build\ddr_image.bin' }

$MAGIC        = 0x31544D4D
$VERSION      = 1
$HDR_SIZE     = 48
$PAYLOAD_OFF  = 64

function Hex([int]$v) { '0x{0:X8}' -f $v }
function Align4([int]$v) { [int](($v + 3) -band (-bnot 3)) }

# ---- CRC32（必须与 sw\ddr\spi_flash.h 的 mmt_crc32 完全一致）----
# 参考值：'123456789' → 0xCBF43926（CRC-32/ISO-HDLC，和 zlib.crc32 相同）
# ★ PowerShell 的坑：0xEDB88320 / 0xCBF43926 / 0xFFFFFFFF 都超出 Int32，
#   PS 会把它们解析成**负的 Int32**，再转 int64 就变成 0xFFFFFFFF........。
#   所以这几个常量一律用十进制 [int64] 写，并且每步都按 32 位掩码收口。
function Get-Crc32([byte[]]$data) {
    [int64]$POLY = 3988292384        # 0xEDB88320
    [int64]$MASK = 4294967295        # 0xFFFFFFFF
    [int64]$crc  = $MASK
    foreach ($b in $data) {
        $crc = ($crc -bxor [int64]$b) -band $MASK
        for ($k = 0; $k -lt 8; $k++) {
            if (($crc -band 1) -ne 0) { $crc = (($crc -shr 1) -bxor $POLY) -band $MASK }
            else                      { $crc =  ($crc -shr 1)               -band $MASK }
        }
    }
    return [int64](($crc -bxor $MASK) -band $MASK)
}

# ---- 自检：CRC 实现对不对（用标准测试向量）----
$probe = [System.Text.Encoding]::ASCII.GetBytes('123456789')
$probeCrc = Get-Crc32 $probe
$expectProbe = [Convert]::ToInt64('CBF43926', 16)
if ($probeCrc -ne $expectProbe) {
    throw ("CRC32 自检失败：'123456789' 算出 0x{0:X8}，应为 0xCBF43926 —— 与 spi_flash.h 不一致，别用这版打包" -f $probeCrc)
}
Write-Output "CRC32 自检     : OK（'123456789' -> 0xCBF43926，与 spi_flash.h 的 mmt_crc32 同一算法）"

if (-not (Test-Path $App)) {
    throw "固件不存在：$App   （先跑 build_ddr.ps1）"
}
$appRaw = [System.IO.File]::ReadAllBytes($App)
if ($appRaw.Length -eq 0) { throw "固件是空文件：$App" }

$wRaw = [byte[]]@()
if ($Weights) {
    if (-not (Test-Path $Weights)) { throw "权重文件不存在：$Weights" }
    $wRaw = [System.IO.File]::ReadAllBytes($Weights)
}

$appLen = Align4 $appRaw.Length
$wLen   = Align4 $wRaw.Length
$payloadLen = $appLen + $wLen
$total  = $PAYLOAD_OFF + $payloadLen
$budget = $FlashSize - $FlashBase

Write-Output "=== mkimage.ps1 : 打 DDR flash 镜像 ==="
Write-Output ("flash 起始    : {0}   预算 {1} bytes（= {2:N2} MB - {3}）" -f (Hex $FlashBase), $budget, ($FlashSize/1MB), (Hex $FlashBase))
Write-Output ("app           : {0}  {1} bytes（对齐后 {2}）" -f $App, $appRaw.Length, $appLen)
if ($wRaw.Length -gt 0) {
    Write-Output ("权重          : {0}  {1} bytes（对齐后 {2} = {3:N1} KiB）" -f $Weights, $wRaw.Length, $wLen, ($wLen/1KB))
} else {
    Write-Output  "权重          : （未提供）"
}
Write-Output ("载荷          : {0} bytes" -f $payloadLen)
Write-Output ("镜像总长      : {0} bytes / 预算 {1} bytes" -f $total, $budget)
Write-Output ("DDR 落点      : app {0} .. {1}  权重 {2} .. {3}" -f `
    (Hex $AppDdr), (Hex ($AppDdr + $appLen - 1)), (Hex $WeightsDdr), (Hex ($WeightsDdr + $wLen - 1)))

if ($total -gt $budget) {
    throw ("镜像 {0} 字节 超过 flash 可用 {1} 字节（{2} 起）。缩小固件/权重，或改 -FlashBase。" -f $total, $budget, (Hex $FlashBase))
}
if ($AppDdr -lt 0x1000) { throw "app 落点在 DDR 解码空洞 0x0-0xFFF 里，禁止" }
if ($WeightsDdr -lt 0x1000) { throw "权重落点在 DDR 解码空洞里，禁止" }
if (($AppDdr + $appLen) -gt $WeightsDdr) { throw "app 区压到了权重区（app 区上界必须 ≤ 权重起始）—— 同步改 link_ddr.ld 的 LENGTH 与本脚本的 -AppDdr/-WeightsDdr" }
if (($WeightsDdr + $wLen) -gt 0x10000000) { throw "权重越过物理 DDR 边界 0x10000000（256MB，推断值）" }

if ($DryRun) { Write-Output "DryRun：未写文件，容量/地址检查通过。"; exit 0 }

# ---- 组装 ---- 
$img = New-Object 'byte[]' $total                # 默认全 0（填充值 0x00）
[Array]::Copy($appRaw, 0, $img, $PAYLOAD_OFF, $appRaw.Length)
if ($wRaw.Length -gt 0) { [Array]::Copy($wRaw, 0, $img, $PAYLOAD_OFF + $appLen, $wRaw.Length) }

$payload = New-Object 'byte[]' $payloadLen
[Array]::Copy($img, $PAYLOAD_OFF, $payload, 0, $payloadLen)
[int64]$crc = Get-Crc32 $payload

function PutU32([byte[]]$buf, [int]$off, [int64]$val) {
    $buf[$off+0] = [byte]( $val         -band 0xFF)
    $buf[$off+1] = [byte](($val -shr  8) -band 0xFF)
    $buf[$off+2] = [byte](($val -shr 16) -band 0xFF)
    $buf[$off+3] = [byte](($val -shr 24) -band 0xFF)
}
PutU32 $img 0  $MAGIC
PutU32 $img 4  $VERSION
PutU32 $img 8  $total
PutU32 $img 12 0                # app_flash_off
PutU32 $img 16 $AppDdr
PutU32 $img 20 $appLen
PutU32 $img 24 $appLen          # w_flash_off（app 之后立刻是权重）
PutU32 $img 28 $WeightsDdr
PutU32 $img 32 $wLen
PutU32 $img 36 $crc
PutU32 $img 40 $payloadLen
PutU32 $img 44 0

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[System.IO.File]::WriteAllBytes($Out, $img)
Write-Output ("已写出        : {0}  ({1} bytes)" -f $Out, $img.Length)
Write-Output ("载荷 CRC32    : 0x{0:X8}" -f $crc)

# ---- 自校验：读回来逐字节核 + 头字段核 + CRC 重算 ----
$chk = [System.IO.File]::ReadAllBytes($Out)
$bad = 0
if ($chk.Length -ne $total) { $bad++ }
for ($i = 0; $i -lt $appRaw.Length; $i++) { if ($chk[$PAYLOAD_OFF + $i] -ne $appRaw[$i]) { $bad++ } }
for ($i = 0; $i -lt $wRaw.Length;   $i++) { if ($chk[$PAYLOAD_OFF + $appLen + $i] -ne $wRaw[$i]) { $bad++ } }
$chkPayload = New-Object 'byte[]' $payloadLen
[Array]::Copy($chk, $PAYLOAD_OFF, $chkPayload, 0, $payloadLen)
[int64]$crc2 = Get-Crc32 $chkPayload
if ($crc2 -ne $crc) { $bad++ }
if ($bad -eq 0) {
    Write-Output ("自校验        : OK（载荷可复现、CRC 一致）")
} else {
    throw ("自校验失败：{0} 处不一致（不要烧这版镜像）" -f $bad)
}

# ---- 地址表（烧写时照它填地址）----
$rpt = [System.IO.Path]::ChangeExtension($Out, '.rpt')
$lines = @(
    "**** mmt DDR image flash map (generated by sw\ddr\mkimage.ps1) ****",
    "Route   : self-built loader in on-chip RAM -> copies image into DDR (NOT the vendor 16MB bootloader)",
    "Flash Address  Length      What",
    ("{0}     0x{1:x8}  FPGA bitstream (.hex from Efinity; must fit below {2})" -f (Hex 0), $FlashBase, (Hex $FlashBase)),
    ("{0}     0x{1:x8}  this image (48B header + pad + app + weights)" -f (Hex $FlashBase), $total),
    ("   -> DDR {0}  app        ({1} bytes)" -f (Hex $AppDdr), $appRaw.Length),
    ("   -> DDR {0}  weights    ({1} bytes)" -f (Hex $WeightsDdr), $wRaw.Length),
    ("   payload CRC32 = 0x{0:X8}" -f $crc),
    "",
    "NOTE 1: loader 只读 header 里声明的长度，**不会**越过镜像末尾读 flash。",
    "NOTE 2: 0x00000000-0x00000FFF 是 DDR 解码空洞，永远不要放东西。",
    "NOTE 3: 位流大小必须 < flash 起始地址；若位流更大，改 -FlashBase 并重跑本脚本（loader 里的",
    "        MMT_FLASH_IMG_BASE 由 build_ddr.ps1 用 -DMMT_FLASH_IMG_BASE=... 同步传进去）。"
)
[System.IO.File]::WriteAllLines($rpt, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("地址表        : {0}" -f $rpt)
$lines | ForEach-Object { Write-Output ("                " + $_) }
