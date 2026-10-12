# ==========================================================================
#  verify_flash_layout.ps1 — flash 布局 + 镜像自洽性自动校验
# --------------------------------------------------------------------------
#  输入：位流文件（Efinity 的 .hex 或 .bit，或纯 .bin）+ 用户镜像 ddr_image.bin
#  输出：布局表 + 重叠/越界/对齐检查 + 镜像头字段/CRC 复核 + PASS/FAIL 与退出码
#
#  ★ 为什么需要它：烧写之前"位流 + 镜像"必须和 flash 容量、loader 读的地址三者自洽。
#    这类错的典型表现是"烧完上电没反应"或"上电乱飞"，在 PC 上先算一遍能省掉一整轮上板调试。
#
#  ★ Efinity 的 .hex/.bit 是**每行一个字节的十六进制文本**（不是 Intel HEX！）
#      · 一行 = 一个字节；byte ≥ 0x80 时写成 4 位十六进制（高位补 FF，例如 0xE6 → "FFE6"）
#      · 文件开头是纯文本头：Version / Generated / Project / Family / Device / Width /
#        Mode / Die Name / 4Byte / PADDED_BITS，后面用 0x0A 填充到固定位置，然后是位流数据
#      · 所以**文件大小 ≈ 真实字节数 × 3**！磁盘上 2.75MB 的 .hex，真正写进 flash 的只有 ~0.92MB
#    （实测依据见 docs\Flash布局与镜像一致性.md §1）
#
#  用法：
#     powershell -File verify_flash_layout.ps1
#     powershell -File verify_flash_layout.ps1 -Bitstream D:\FPGA\mmt\out\mmt.hex -Image D:\FPGA\mmt\sw\ddr\build\ddr_image.bin
#     powershell -File verify_flash_layout.ps1 -ImageBase 0x380000 -FlashSize 0x800000
#  退出码：0 = 全部 PASS；1 = 有 FAIL。
# ==========================================================================
param(
    [string]$Bitstream  = 'D:\FPGA\mmt\out\mmt.hex',
    [string]$Image      = '',
    [int]   $FlashSize  = 0x800000,     # GD25LQ64 = 8MB（参考资料\_目录说明.md:67）
    [int]   $ImageBase  = 0x380000,     # 用户镜像起始（厂商约定；loader 的 MMT_FLASH_IMG_BASE）
    [int]   $BitBase    = 0x000000,     # 位流起始（SPI Active 必须从 0 开始）
    [int]   $SectorSize = 0x1000,       # GD25LQ64 扇区 4KB（擦除粒度，真机确认见文档 §5）
    [switch]$SkipBitstream
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Image) { $Image = Join-Path $here 'build\ddr_image.bin' }

$MAGIC        = [int64]0x31544D4D
$VERSION      = 1
$HDR_SIZE     = 48
$PAYLOAD_OFF  = 64
$DDR_HOLE_END = [int64]0x00000FFF
$DDR_LIMIT    = [int64]0x10000000     # 物理 DDR 256MB（推断）
$APP_LIMIT    = [int64]0x00100000

$fails = New-Object System.Collections.ArrayList
$warns = New-Object System.Collections.ArrayList
$pass  = 0

function Hex([int64]$v) { '0x{0:X8}' -f $v }
function KB([int64]$v)  { '{0:N1} KiB' -f ($v / 1KB) }
function Ok($m)   { $script:pass++;  Write-Output ("  PASS  " + $m) }
function Bad($m)  { [void]$script:fails.Add($m); Write-Output ("  FAIL  " + $m) }
function Warn($m) { [void]$script:warns.Add($m); Write-Output ("  WARN  " + $m) }

# ---- CRC32（与 sw\ddr\spi_flash.h 的 mmt_crc32 同算法：poly 0xEDB88320 反射）----
# 注意：PowerShell 里 0xEDB88320 / 0xFFFFFFFF 会被解析成负 Int32，必须用十进制 [int64]。
function Get-Crc32([byte[]]$data) {
    [int64]$POLY = 3988292384
    [int64]$MASK = 4294967295
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

Write-Output "======================================================"
Write-Output " verify_flash_layout.ps1 — flash 布局与镜像一致性校验"
Write-Output "======================================================"
Write-Output ("flash 容量     : {0} ({1})" -f (Hex $FlashSize), (KB $FlashSize))
Write-Output ("位流起始       : {0}" -f (Hex $BitBase))
Write-Output ("用户镜像起始   : {0}" -f (Hex $ImageBase))
Write-Output ("扇区粒度(假定) : {0}" -f (Hex $SectorSize))
Write-Output ""

# ======================================================================
# 1. 位流
# ======================================================================
$bitBytes = [int64]0
$bitDisk  = [int64]0
$bitTextHdr = ''
if ($SkipBitstream) {
    Warn "跳过位流检查（-SkipBitstream）"
} else {
    Write-Output "[1] 位流"
    if (-not (Test-Path $Bitstream)) {
        Bad ("位流文件不存在: {0}" -f $Bitstream)
    } else {
        $bitDisk = (Get-Item $Bitstream).Length
        $ext = [System.IO.Path]::GetExtension($Bitstream).ToLower()
        Write-Output ("      文件    : {0}  ({1} 字节 = {2})" -f $Bitstream, $bitDisk, (KB $bitDisk))

        if ($ext -eq '.bin') {
            # 纯二进制：文件大小就是字节数
            $bitBytes = $bitDisk
            Write-Output ("      格式    : 纯二进制 .bin")
            Ok ("位流字节数 = {0}（按文件大小，.bin 无文本膨胀）" -f $bitBytes)
        } else {
            # Efinity .hex/.bit：每行一个字节的十六进制文本
            $lines = Get-Content $Bitstream
            [int64]$n2 = 0; [int64]$n4 = 0; $nOther = 0
            foreach ($l in $lines) {
                if     ($l.Length -eq 2) { $n2++ }
                elseif ($l.Length -eq 4) { $n4++ }
                else                     { $nOther++ }
            }
            $bitBytes = $n2 + $n4            # 4 位行的高位 FF 是符号扩展，仍是 1 个字节
            # --- 解出开头的文本头 ---
            # ⚠️ 不能用"遇到第一个不可打印字节就停"：位流头里的 Project 路径可能含中文（UTF-8 多字节），
            #    会把 Device/Mode/Width 这些后面的字段全截掉（本脚本第一版就踩了这个坑）。
            #    正确做法：先按"每行 1 字节"解出前面一段，再用 "PADDED_BITS" 之后的 0x0A 填充段定位头尾。
            $probe = [Math]::Min(2000, $lines.Count)
            $bytes = New-Object 'System.Collections.Generic.List[byte]'
            for ($i = 0; $i -lt $probe; $i++) {
                $l = $lines[$i]
                if     ($l.Length -eq 2) { $bytes.Add([Convert]::ToByte($l, 16)) }
                elseif ($l.Length -eq 4) { $bytes.Add([Convert]::ToByte($l.Substring(2, 2), 16)) }
                else { $bytes.Add([byte]0x3F) }   # '?'
            }
            $ba = $bytes.ToArray()
            # 可打印视图（LF -> '|'，其余不可打印 -> '.'）
            $sb = New-Object System.Text.StringBuilder
            foreach ($b in $ba) {
                if     ($b -eq 10)                 { [void]$sb.Append('|') }
                elseif ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
                else                               { [void]$sb.Append('.') }
            }
            $bitTextHdr = $sb.ToString()
            # 文本头长度：定位 "PADDED_BITS"，再跳过其后的 0x0A 填充，第一个非 0x0A 字节即位流数据起点
            $hdrLen = [int64]0
            $needle = [System.Text.Encoding]::ASCII.GetBytes('PADDED_BITS')
            for ($i = 0; $i -lt ($ba.Length - $needle.Length); $i++) {
                $hit = $true
                for ($k = 0; $k -lt $needle.Length; $k++) { if ($ba[$i+$k] -ne $needle[$k]) { $hit = $false; break } }
                if ($hit) {
                    $j = $i + $needle.Length
                    while (($j -lt $ba.Length) -and ($ba[$j] -ne 10)) { $j++ }   # 跳过 ": 0" 之类
                    while (($j -lt $ba.Length) -and ($ba[$j] -eq 10)) { $j++ }   # 跳过 LF 填充
                    $hdrLen = $j
                    break
                }
            }
            Write-Output ("      格式    : Efinity 文本 hex（每行 1 字节；2 位行 {0}，4 位行 {1}，异常行 {2}）" -f $n2, $n4, $nOther)
            # Project 行按 UTF-8 单独解一次（工程路径里可能含中文，可打印视图会把它们变成 '.'）
            $pj = [System.Text.Encoding]::ASCII.GetBytes('Project: ')
            for ($i = 0; $i -lt ($ba.Length - $pj.Length); $i++) {
                $hit = $true
                for ($k = 0; $k -lt $pj.Length; $k++) { if ($ba[$i+$k] -ne $pj[$k]) { $hit = $false; break } }
                if ($hit) {
                    $j = $i + $pj.Length; $seg = New-Object 'System.Collections.Generic.List[byte]'
                    while (($j -lt $ba.Length) -and ($ba[$j] -ne 10)) { $seg.Add($ba[$j]); $j++ }
                    $path = [System.Text.Encoding]::UTF8.GetString($seg.ToArray())
                    Write-Output ("      Project : {0}   ← 位流头里记录的工程路径" -f $path)
                    if ($path -notmatch 'mmt') { Warn ("位流头里的工程路径 '{0}' 不含 'mmt' —— 请确认这份位流确实是本工程的（可能是陈旧文件）" -f $path) }
                    else { Ok ("位流头里的工程路径含 'mmt'：{0}" -f $path) }
                    break
                }
            }
            Write-Output ("      文本头  : {0}" -f ($bitTextHdr.Substring(0, [Math]::Min(220, $bitTextHdr.Length))))
            if ($hdrLen -gt 0) {
                Write-Output ("      文本头长: {0} 字节（'PADDED_BITS' 之后 LF 填充结束处）；其余 {1} 字节是位流数据" -f $hdrLen, ($bitBytes - $hdrLen))
            } else {
                Write-Output ("      文本头长: 无法定位 PADDED_BITS（前 {0} 行内没找到），只做字节数检查" -f $probe)
            }
            Write-Output ("      解码字节: {0} = {1} = {2} MiB" -f $bitBytes, (KB $bitBytes), [Math]::Round($bitBytes / 1MB, 3))
            Write-Output ("      ★ 注意  : 磁盘 {0} 字节只是 ASCII 展开（约 3 倍），真正写进 flash 的是解码后的 {1} 字节" -f $bitDisk, $bitBytes)
            if ($nOther -ne 0) { Bad ("位流里有 {0} 行既不是 2 位也不是 4 位十六进制，格式与预期不符" -f $nOther) }
            else                { Ok "位流文本格式可解析（每行 1 字节）" }
            if ($bitTextHdr -match 'Device:\s*Ti60F225') { Ok "位流头里 Device = Ti60F225（与板卡一致）" }
            else { Warn ("位流头里没看到 'Device: Ti60F225'，请人工确认这份位流是不是本板卡的") }
            if ($bitTextHdr -match 'Mode:\s*active')     { Ok "位流头里 Mode = active（SPI Active 配置，可从 flash 0x0 启动）" }
            else { Warn "位流头里没看到 'Mode: active' —— 从 flash 0x0 启动的假设需要人工确认" }
            if ($bitTextHdr -match 'Width:\s*1')         { Ok "位流头里 Width = 1（与 mmt.xml:205 的 width=1 一致）" }
            else { Warn "位流头里没看到 'Width: 1'，和 mmt.xml:205 不一致，请确认" }
        }
    }
}

# ======================================================================
# 2. 用户镜像
# ======================================================================
Write-Output ""
Write-Output "[2] 用户镜像"
$imgLen = [int64]0
$hdrOk  = $false
$h = $null
$imgBytes = $null
if (-not (Test-Path $Image)) {
    Bad ("镜像不存在: {0}（先跑 build_ddr.ps1）" -f $Image)
} else {
    $imgBytes = [System.IO.File]::ReadAllBytes($Image)
    $imgLen = $imgBytes.Length
    Write-Output ("      文件    : {0}  ({1} 字节 = {2})" -f $Image, $imgLen, (KB $imgLen))
    if ($imgLen -lt $PAYLOAD_OFF) {
        Bad "镜像比 64 字节还短，连头都不完整"
    } else {
        $f = @()
        for ($i = 0; $i -lt 12; $i++) { $f += [int64]$imgBytes[$i*4] + ([int64]$imgBytes[$i*4+1] -shl 8) + ([int64]$imgBytes[$i*4+2] -shl 16) + ([int64]$imgBytes[$i*4+3] -shl 24) }
        $h = [pscustomobject]@{
            Magic=$f[0]; Version=$f[1]; Total=[int64]$f[2]; AppOff=[int64]$f[3]; AppDdr=[int64]$f[4]; AppLen=[int64]$f[5]
            WOff=[int64]$f[6]; WDdr=[int64]$f[7]; WLen=[int64]$f[8]; Crc=[int64]$f[9]; PayloadLen=[int64]$f[10]; Rsv=[int64]$f[11]
        }
        Write-Output "      镜像头（48 字节，小端）:"
        Write-Output ("        +0  magic          = {0}   （应为 0x31544D4D = 'MMT1'）" -f (Hex $h.Magic))
        Write-Output ("        +4  version        = {0}" -f $h.Version)
        Write-Output ("        +8  total_size     = {0} ({1} 字节)" -f (Hex $h.Total), $h.Total)
        Write-Output ("        +12 app_flash_off  = {0}" -f $h.AppOff)
        Write-Output ("        +16 app_ddr_addr   = {0}" -f (Hex $h.AppDdr))
        Write-Output ("        +20 app_len        = {0} ({1} 字节)" -f (Hex $h.AppLen), $h.AppLen)
        Write-Output ("        +24 w_flash_off    = {0}" -f $h.WOff)
        Write-Output ("        +28 w_ddr_addr     = {0}" -f (Hex $h.WDdr))
        Write-Output ("        +32 w_len          = {0} ({1} 字节)" -f (Hex $h.WLen), $h.WLen)
        Write-Output ("        +36 payload_crc    = {0}" -f (Hex $h.Crc))
        Write-Output ("        +40 payload_len    = {0} ({1} 字节)" -f (Hex $h.PayloadLen), $h.PayloadLen)
        Write-Output ("        +44 reserved0      = {0}" -f $h.Rsv)

        # --- 头字段逐条校验（与 loader.c hdr_check() 完全相同的判据）---
        if ($h.Magic -eq $MAGIC) { Ok "magic 正确（loader 的魔数检查会过）" ; $hdrOk = $true }
        else {
            Bad ("magic = {0}，不是 0x31544D4D —— loader 会在 '[2] image header' 处报错并**拒绝跳转**。" -f (Hex $h.Magic))
            Warn "如果这个文件是 pack_image.ps1（路线甲那个旧打包器）生成的，那它**本来就没有 48 字节头**，格式与本 loader 不兼容。"
        }
        if ($h.Version -eq $VERSION) { Ok "version = 1（loader 支持）" } else { Bad ("version = {0}，loader 只支持 1" -f $h.Version) }
        if ($h.Total -eq $imgLen) { Ok "total_size 与实际文件长度一致" } else { Bad ("total_size={0} 与实际 {1} 不一致" -f $h.Total, $imgLen) }
        if ($h.Rsv -eq 0) { Ok "reserved0 = 0" } else { Warn ("reserved0 = {0}（应为 0）" -f $h.Rsv) }
        if ($h.PayloadLen -eq ($h.Total - $PAYLOAD_OFF)) { Ok "payload_len == total_size - 64（loader 的判据）" }
        else { Bad ("payload_len={0} 与 total_size-64={1} 不一致 —— loader 会拒绝" -f $h.PayloadLen, ($h.Total - $PAYLOAD_OFF)) }
        if ($h.AppDdr -gt $DDR_HOLE_END) { Ok ("app 落点 {0} 不在 DDR 解码空洞(0x0-0xFFF)里" -f (Hex $h.AppDdr)) }
        else { Bad ("app 落点 {0} 落在解码空洞里" -f (Hex $h.AppDdr)) }
        if (($h.AppDdr + $h.AppLen) -le $DDR_LIMIT) { Ok "app 落点+长度在物理 DDR 内" } else { Bad "app 越过物理 DDR 边界" }
        if ($h.WLen -eq 0) { Ok "本镜像无权重（w_len = 0）" }
        else {
            if ((($h.WDdr -gt $DDR_HOLE_END) -and (($h.WDdr + $h.WLen) -le $DDR_LIMIT))) { Ok ("权重落点 {0}..{1} 合法" -f (Hex $h.WDdr), (Hex ($h.WDdr + $h.WLen - 1))) }
            else { Bad "权重落点越界" }
            if ((($h.WDdr -ge ($h.AppDdr + $h.AppLen)) -or ($h.AppDdr -ge ($h.WDdr + $h.WLen)))) { Ok "权重区与 app 区不重叠" }
            else { Bad "权重区与 app 区重叠" }
        }
        if ((($h.AppLen % 4) -eq 0) -and (($h.WLen % 4) -eq 0) -and (($h.AppDdr % 4) -eq 0) -and (($h.WDdr % 4) -eq 0)) { Ok "长度/落点都是 4 字节对齐（loader 的 32 位搬运要求）" }
        else { Bad "长度/落点不是 4 的倍数 —— loader 的 spi_flash_to_mem 会直接返回失败" }
        if ((($h.AppOff + $h.AppLen) -le $h.PayloadLen) -and (($h.WLen -eq 0) -or (($h.WOff + $h.WLen) -le $h.PayloadLen))) { Ok "载荷内偏移不越界" }
        else { Bad "载荷内偏移越界" }
        if ($h.AppLen -le ($APP_LIMIT - $h.AppDdr)) { Ok "app 不超过 link_ddr.ld 的 1020K app 区上界" }
        else { Bad "app 越过 0x00100000（会和权重区打架）—— link_ddr.ld 的 ASSERT 本应在链接期就拦住" }
        if (($h.Total - $PAYLOAD_OFF) -le ($FlashSize - $ImageBase)) { Ok ("镜像 {0} 字节 ≤ 用户区预算 {1} 字节" -f $h.Total, ($FlashSize - $ImageBase)) }
        else { Bad ("镜像 {0} 字节 超过 flash 用户区预算 {1} 字节" -f $h.Total, ($FlashSize - $ImageBase)) }

        # --- CRC32 独立重算 ---
        $payload = New-Object 'byte[]' $h.PayloadLen
        [Array]::Copy($imgBytes, $PAYLOAD_OFF, $payload, 0, [int]$h.PayloadLen)
        [int64]$crc = Get-Crc32 $payload
        if ($crc -eq $h.Crc) { Ok ("payload CRC32 = {0}，与重算一致（loader 的 CRC 校验会过）" -f (Hex $crc)) }
        else { Bad ("payload CRC32 头里={0} 重算={1} —— loader 会拒绝跳转" -f (Hex $h.Crc), (Hex $crc)) }

        # --- 载荷顺序假设（loader 的 CRC 只在这种布局下能验）---
        if (($h.AppOff -eq 0) -and ($h.WOff -eq $h.AppLen)) { Ok "标准载荷布局（app 在前、权重紧随），loader 的分段 CRC 能覆盖整段载荷" }
        else { Warn "非标准载荷布局（app_flash_off / w_flash_off 不是 0 / app_len）—— loader 会打印 '(payload layout unexpected -> skip CRC)' 并跳过 CRC 校验" }

        # --- 与 loader 编译期的 flash 基址对照（头里没有这个字段，只能提示）---
        Warn ("镜像头里**没有** flash 起始地址字段；loader 用的是编译期常量 MMT_FLASH_IMG_BASE。本脚本按 {0} 计算，请确认 build_ddr.ps1 的 -FlashBase 与烧写地址一致。" -f (Hex $ImageBase))
    }
}

# ======================================================================
# 3. 布局表
# ======================================================================
Write-Output ""
Write-Output "[3] flash 布局表"
$bitEnd  = $BitBase + $bitBytes
$imgEnd  = $ImageBase + $imgLen
$gap     = $ImageBase - $bitEnd
Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '区', '起始', '长度(字节)', '结束(含)', '说明')
Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '--------------------------', '------------', '------------', '------------', '----')
Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '位流(FPGA config)', (Hex $BitBase), $bitBytes, (Hex ($bitEnd - 1)), 'SPI Active 从 0 读；' + $bitTextHdr.Split('|')[0])
if ($gap -gt 0) {
    Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '（间隙·未使用）', (Hex $bitEnd), $gap, (Hex ($ImageBase - 1)), '浪费但无害；也可以把镜像前移到这里（需同步改 loader 的编译常量）')
} elseif ($gap -lt 0) {
    Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '（重叠!!）', (Hex $ImageBase), (-$gap), (Hex ($bitEnd - 1)), '★ 位流与用户镜像重叠')
}
if ($imgLen -gt 0) {
    Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '用户镜像(头+app+权重)', (Hex $ImageBase), $imgLen, (Hex ($imgEnd - 1)), 'loader 从这里读 48B 头')
    Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '  └ app 载荷', (Hex ($ImageBase + $PAYLOAD_OFF)), $h.AppLen, (Hex ($ImageBase + $PAYLOAD_OFF + $h.AppLen - 1)), '搬到 DDR ' + (Hex $h.AppDdr))
    if ($h.WLen -gt 0) {
        Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '  └ 权重载荷', (Hex ($ImageBase + $PAYLOAD_OFF + $h.AppLen)), $h.WLen, (Hex ($ImageBase + $PAYLOAD_OFF + $h.AppLen + $h.WLen - 1)), '搬到 DDR ' + (Hex $h.WDdr))
    }
}
Write-Output ("  {0,-26} {1,-12} {2,-12} {3,-12} {4}" -f '（剩余可用）', (Hex $imgEnd), ($FlashSize - $imgEnd), (Hex ($FlashSize - 1)), '')

Write-Output ""
Write-Output "[4] 布局检查"
if ($SkipBitstream -or $bitBytes -eq 0) { Warn "位流未检查，跳过重叠/越界判定" }
else {
    if ($bitEnd -le $ImageBase) { Ok ("位流结束 {0} ≤ 用户镜像起始 {1}（不重叠，间隙 {2} = {3}）" -f (Hex ($bitEnd - 1)), (Hex $ImageBase), $gap, (KB $gap)) }
    else { Bad ("位流结束 {0} 越过用户镜像起始 {1} —— 烧进去会互相覆盖！要么缩小位流，要么把镜像起始改到 {2} 之后（需同步改 build_ddr.ps1/mkimage.ps1 的 -FlashBase 与 loader 的 MMT_FLASH_IMG_BASE）" -f (Hex ($bitEnd - 1)), (Hex $ImageBase), (Hex $bitEnd)) }
    if ($bitEnd -le $FlashSize) { Ok ("位流结束 {0} ≤ flash 容量 {1}" -f (Hex ($bitEnd - 1)), (Hex $FlashSize)) }
    else { Bad "位流超出 flash 容量" }
}
if ($imgLen -gt 0) {
    if ($imgEnd -le $FlashSize) { Ok ("镜像结束 {0} ≤ flash 容量 {1}（剩余 {2} = {3}）" -f (Hex ($imgEnd - 1)), (Hex $FlashSize), ($FlashSize - $imgEnd), (KB ($FlashSize - $imgEnd))) }
    else { Bad ("镜像结束 {0} 超出 flash 容量 {1}" -f (Hex ($imgEnd - 1)), (Hex $FlashSize)) }
    if (($ImageBase % $SectorSize) -eq 0) { Ok ("用户镜像起始 {0} 是 {1} 字节扇区对齐的（擦除不会误伤位流区）" -f (Hex $ImageBase), $SectorSize) }
    else { Bad ("用户镜像起始 {0} 不是 {1} 扇区对齐 —— 写镜像前的擦除会覆盖前一个扇区" -f (Hex $ImageBase), $SectorSize) }
    if (($BitBase % $SectorSize) -eq 0) { Ok "位流起始 0x0 是扇区对齐的" } else { Bad "位流起始不是扇区对齐" }
    $imgSectors = [Math]::Ceiling($imgLen / $SectorSize)
    Write-Output ("  INFO  镜像需要擦除 {0} 个 {1} 字节扇区（{2} 起始）" -f $imgSectors, $SectorSize, (Hex $ImageBase))
}

# ======================================================================
# 5. 结果
# ======================================================================
Write-Output ""
Write-Output "======================================================"
Write-Output (" 结果：PASS {0} 项，FAIL {1} 项，WARN {2} 项" -f $pass, $fails.Count, $warns.Count)
Write-Output "======================================================"
if ($fails.Count -gt 0) {
    Write-Output "失败项："
    foreach ($m in $fails) { Write-Output ("  !! " + $m) }
}
if ($warns.Count -gt 0) {
    Write-Output "提醒项（不一定是错，但要有人确认）："
    foreach ($m in $warns) { Write-Output ("  ~ " + $m) }
}
Write-Output ""
Write-Output "烧写步骤（详见 docs\Flash布局与镜像一致性.md §4）："
if ($SkipBitstream) { Write-Output ("  1) 位流        -> flash {0}" -f (Hex $BitBase)) }
else                { Write-Output ("  1) 位流        -> flash {0}（{1} 字节）" -f (Hex $BitBase), $bitBytes) }
Write-Output ("  2) 用户镜像    -> flash {0}（{1} 字节）" -f (Hex $ImageBase), $imgLen)
Write-Output "  3) 读回比对（Efinity Programmer 的 verify / 或调试器读 flash）"
if ($fails.Count -gt 0) { exit 1 } else { exit 0 }
