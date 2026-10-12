# ==========================================================================
#  pack_image.ps1 -- 把「RISC-V 固件」和「TinyML 模型权重」打包成**一个**
#                    flash 镜像，好让 16MB bootloader 一次搬进 DDR。
# --------------------------------------------------------------------------
#  为什么需要这一步（外行也看得懂版）
#  ---------------------------------------------------------------------
#  板子上的 flash 只有 8MB（GD25LQ64），布局是固定的：
#       flash 0x000000  放 FPGA 位流（.hex）
#       flash 0x380000  放"用户软件镜像"
#  而 SoC 片内 RAM 里那支 bootloader 干的事是：
#       「从 flash 0x380000 读 16MB，写到 DDR 0x00001000，然后跳到 0x1000」
#  （证据：ref_files\bootloader_16MB\SapphireSoc\bootloader.hex 反汇编
#    0x5d0 lui a4,0x1000 → 长度 0x01000000；0x5d8 lui a2,0x380 → 源 0x00380000；
#    0x5d4 lui a3,0x1 → 目标 0x00001000；0x5ec jalr → 0x1000）
#  它只会搬"一个连续镜像"，它不知道固件和权重是两样东西。
#  所以：必须先在 PC 上把
#        [ 固件.bin ][ 填充 ][ 权重.bin ]
#  拼成一个连续文件，再烧到 flash 0x380000。
#  拼完之后，固件在 DDR 0x00001000，权重正好落在 DDR 0x00100000。
#
#  ---------------------------------------------------------------------
#  用法
#  ---------------------------------------------------------------------
#     # 只有固件（先跑通 DDR 启动，权重以后再放）
#     powershell -File pack_image.ps1
#
#     # 固件 + 权重
#     powershell -File pack_image.ps1 -Weights .\weights\mobilenet_int8.bin
#
#     # 只想看会不会超容量，不写文件
#     powershell -File pack_image.ps1 -Weights .\weights\x.bin -DryRun
#
#  ⚠️⚠️ 本脚本是**路线甲（厂商 bootloader）**用的旧打包器，格式与当前 loader **不兼容**：
#      · 它产出「纯拼接」文件：app 直接放镜像开头，**没有 48 字节镜像头**
#      · 现行方案用 mkimage.ps1：开头 48B 头 + 载荷从第 64 字节开始
#      · 两者默认输出名**曾经相同**（build\ddr_image.bin）——这是个真陷阱：
#        先跑 mkimage.ps1 再跑本脚本，会把镜像悄悄覆盖成"没带头"的版本；
#        上板后 loader 的 magic 检查会失败（好在它**拒绝跳转**，不会乱飞）。
#      → 因此本脚本默认输出已改名为 LEGACY_routeA_image.bin，避免撞车。
#      → 现在的正常流程：build_ddr.ps1 → mkimage.ps1 → verify_flash_layout.ps1
#
#  ⚠️ 全程**不碰** Efinity 流程，只是本地做文件拼接 + 自校验。
# ==========================================================================
param(
    [string]$App        = 'D:\FPGA\mmt\sw\build\mmt_fw.bin',   # 用 sw\ddr\link_ddr.ld 链出来的 .bin
    [string]$Weights    = '',                                  # 模型权重原始二进制，可空
    [string]$Out        = 'D:\FPGA\mmt\sw\ddr\build\LEGACY_routeA_image.bin',
    [int]   $AppRegion  = 0xFF000,     # app 区字节数 = 0x00100000 - 0x00001000 = 1020K
    [int]   $ImageMax   = 0x480000,    # flash 0x380000..0x800000 的可用长度 = 4.5MB
    [int]   $FlashBase  = 0x380000,    # 用户镜像在 flash 里的固定起始地址
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$DdrBase       = 0x00001000          # app 在 DDR 里的起始（sapphire_soc.v:11628）
$WeightsDdr    = $DdrBase + $AppRegion   # = 0x00100000，权重在 DDR 里的起始
$Pad           = [byte]0x00          # 填充值：0x00（不用 0xFF，便于区分"没放东西"）

function Hex([int]$v) { '0x{0:X8}' -f $v }

if (-not (Test-Path $App)) { throw "固件不存在：$App  （先跑 sw\build_sw.ps1，并用 sw\ddr\link_ddr.ld 重新链接）" }
$appBuf = [System.IO.File]::ReadAllBytes($App)
Write-Output ("固件      : {0}  ({1} bytes = {2:N0} B)" -f $App, $appBuf.Length, $appBuf.Length)

if ($appBuf.Length -gt $AppRegion) {
    throw ("固件 {0} 字节 超过 app 区 {1} 字节 -- 要么缩小固件，要么同步改 link_ddr.ld 的 LENGTH 和本脚本的 -AppRegion" -f $appBuf.Length, $AppRegion)
}

$wBuf = [byte[]]@()
if ($Weights) {
    if (-not (Test-Path $Weights)) { throw "权重文件不存在：$Weights" }
    $wBuf = [System.IO.File]::ReadAllBytes($Weights)
    Write-Output ("权重      : {0}  ({1} bytes = {2:N1} KiB)" -f $Weights, $wBuf.Length, ($wBuf.Length / 1KB))
}

$total = $AppRegion + $wBuf.Length
Write-Output ("app 区    : {0} bytes，DDR {1} .. {2}" -f $AppRegion, (Hex $DdrBase), (Hex ($WeightsDdr - 1)))
Write-Output ("权重落点  : DDR {0} .. {1}" -f (Hex $WeightsDdr), (Hex ($WeightsDdr + $wBuf.Length - 1)))
Write-Output ("镜像总长  : {0} bytes / flash 预算 {1} bytes" -f $total, $ImageMax)

if ($total -gt $ImageMax) {
    throw ("app+权重 = {0} 字节，超过可用 {1} 字节（= flash 8MB - 0x380000）。必须缩小权重或固件。" -f $total, $ImageMax)
}
if ($total -gt 0x1000000) {
    throw "内部错误：镜像超过 bootloader 会搬的 16MB"
}

if ($DryRun) {
    Write-Output "DryRun：未写文件。容量检查通过。"
    exit 0
}

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$img = New-Object 'byte[]' $total
for ($i = 0; $i -lt $total; $i++) { $img[$i] = $Pad }
[Array]::Copy($appBuf, 0, $img, 0, $appBuf.Length)
if ($wBuf.Length -gt 0) { [Array]::Copy($wBuf, 0, $img, $AppRegion, $wBuf.Length) }

[System.IO.File]::WriteAllBytes($Out, $img)
Write-Output ("已写出    : {0}  ({1} bytes)" -f $Out, $img.Length)

# ---- 自校验：把写出的文件读回来，逐字节核对两个载荷 ----
$chk = [System.IO.File]::ReadAllBytes($Out)
$bad = 0
if ($chk.Length -ne $total) { $bad++ }
for ($i = 0; $i -lt $appBuf.Length; $i++)      { if ($chk[$i] -ne $appBuf[$i]) { $bad++ } }
for ($i = 0; $i -lt $wBuf.Length; $i++)        { if ($chk[$AppRegion + $i] -ne $wBuf[$i]) { $bad++ } }
if ($bad -eq 0) {
    Write-Output ("自校验    : OK（固件 {0} B + 权重 {1} B 逐字节可复现）" -f $appBuf.Length, $wBuf.Length)
} else {
    throw ("自校验失败：{0} 处不一致（不要烧这版镜像）" -f $bad)
}

# ---- 给 Efinity Programmer / soc_combine_hex 用的地址表 ----
$rpt = [System.IO.Path]::ChangeExtension($Out, '.rpt')
$lines = @(
    "**** mmt DDR image flash map (generated by sw\ddr\pack_image.ps1) ****",
    "Flash Address  Length      What",
    ("{0}     0x{1:x8}  FPGA bitstream (.hex from Efinity outflow; must fit below 0x380000)" -f (Hex 0), 0x380000),
    ("{0}     0x{1:x8}  this packed image  (= app.bin + pad + weights.bin)" -f (Hex $FlashBase), $total),
    ("   -> DDR {0}  app.bin        ({1} bytes)" -f (Hex $DdrBase), $appBuf.Length),
    ("   -> DDR {0}  weights.bin    ({1} bytes)" -f (Hex $WeightsDdr), $wBuf.Length),
    "",
    "NOTE: 镜像尾部到 flash 0x800000 之间的内容不会被使用；",
    "      bootloader 仍会从 flash 0x380000 连读 16MB，超出闪存的部分是未定义值，",
    "      落在 DDR 0x00480000..0x01000FFF（见 docs\DDR固件与模型放置方案.md 的 R4 区）——不要用。"
)
[System.IO.File]::WriteAllLines($rpt, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("地址表    : {0}" -f $rpt)
$lines | ForEach-Object { Write-Output ("            " + $_) }
