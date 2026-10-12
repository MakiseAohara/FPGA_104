#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
verify_image.py — 在 PC 上"当一次 loader"，验证 flash 镜像格式与搬运计划

为什么需要它：loader.c 只能上板跑，而板子还没到能验证的状态（SoC 的 SPI 还没接线）。
但"镜像格式对不对""loader 会不会搬错"这两件事**在 PC 上就能验**：
本脚本用与 sw/ddr/loader.c 完全相同的规则解析镜像头、执行同样的边界检查、
按同样的地址计划把 app/权重"搬"出来，然后和原始文件逐字节比对。

★ 诚实说明：本脚本验证的是**格式与算法**（以及 mkimage.ps1 的输出），
  不是「编译出来的 loader.c 机器码」。机器码本身只做到"编译通过 + 反汇编人工核对"。

用法：
    python verify_image.py                       # 默认 sw\ddr\build\ddr_image.bin
    python verify_image.py <image.bin> [--app <ddr_app.bin>] [--weights <w.bin>]
退出码：0 = 全过；1 = 有失败。
"""

import os
import struct
import sys
import zlib

MAGIC        = 0x31544D4D
VERSION      = 1
HDR_SIZE     = 48
PAYLOAD_OFF  = 64

DDR_HOLE_END   = 0x00000FFF
DDR_PHYS_LIMIT = 0x10000000
# ★ 这两个值必须与 build_ddr.ps1 -FlashBase / mkimage.ps1 -FlashBase 一致。
#   以前它们在这里是**写死的常量**，改了 flash 起始地址（例如位流变大、镜像要前移）时，
#   本脚本会拿旧地址算预算而"假通过" —— 所以现在允许用 --flash-base / --flash-size 覆盖。
FLASH_BASE     = 0x00380000
FLASH_SIZE     = 0x00800000
FLASH_IMG_MAX  = FLASH_SIZE - FLASH_BASE
APP_LIMIT      = 0x00100000

fails = []
oks   = []


def ok(msg):
    oks.append(msg)
    print("  PASS  " + msg)


def bad(msg):
    fails.append(msg)
    print("  FAIL  " + msg)


def crc32_bitwise(data):
    """与 sw\\ddr\\spi_flash.h 的 mmt_crc32 逐行同构（反射，poly 0xEDB88320）"""
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = ((crc >> 1) ^ 0xEDB88320) & 0xFFFFFFFF
            else:
                crc = (crc >> 1) & 0xFFFFFFFF
    return crc ^ 0xFFFFFFFF


def main():
    global FLASH_BASE, FLASH_SIZE, FLASH_IMG_MAX
    here = os.path.dirname(os.path.abspath(__file__))
    args = sys.argv[1:]
    img_path = args[0] if args and not args[0].startswith("--") else os.path.join(here, "build", "ddr_image.bin")
    app_path = None
    w_path = None
    for i, a in enumerate(args):
        if a == "--app" and i + 1 < len(args):
            app_path = args[i + 1]
        if a == "--weights" and i + 1 < len(args):
            w_path = args[i + 1]
        if a == "--flash-base" and i + 1 < len(args):
            FLASH_BASE = int(args[i + 1], 0)
        if a == "--flash-size" and i + 1 < len(args):
            FLASH_SIZE = int(args[i + 1], 0)
    FLASH_IMG_MAX = FLASH_SIZE - FLASH_BASE

    print("=== verify_image.py : 用 loader 的规则在 PC 上验一遍镜像 ===")
    print("flash 布局参数 : base=0x%08X size=%d 预算=%d" % (FLASH_BASE, FLASH_SIZE, FLASH_IMG_MAX))
    if not os.path.isfile(img_path):
        print("找不到镜像: " + img_path)
        return 1
    img = open(img_path, "rb").read()
    print("镜像         : %s  (%d bytes)" % (img_path, len(img)))

    # ---- 1. 头字段 ----
    print("[1] 解析 48 字节镜像头")
    if len(img) < PAYLOAD_OFF:
        bad("镜像比 64 字节还短")
        return 1
    f = struct.unpack_from("<12I", img, 0)
    (magic, version, total_size, app_off, app_ddr, app_len,
     w_off, w_ddr, w_len, payload_crc, payload_len, rsv) = f
    print("      magic=0x%08X version=%d total=%d" % (magic, version, total_size))
    print("      app    : off=%d ddr=0x%08X len=%d" % (app_off, app_ddr, app_len))
    print("      weights: off=%d ddr=0x%08X len=%d" % (w_off, w_ddr, w_len))
    print("      payload: len=%d crc=0x%08X" % (payload_len, payload_crc))

    if magic == MAGIC:
        ok("magic == MMT_IMG_MAGIC")
    else:
        bad("magic 不对")
    if version == VERSION:
        ok("version 支持")
    else:
        bad("version 不支持")
    if total_size == len(img):
        ok("total_size 与实际文件长度一致")
    else:
        bad("total_size=%d 与实际 %d 不一致" % (total_size, len(img)))
    if rsv == 0:
        ok("reserved0 == 0")
    else:
        bad("reserved0 != 0")

    # ---- 2. loader.c hdr_check() 的每一条边界检查（同样顺序）----
    print("[2] 复现 loader.c hdr_check() 的边界检查")
    if total_size <= FLASH_IMG_MAX:
        ok("total_size %d <= flash 预算 %d（8MB - 0x380000）" % (total_size, FLASH_IMG_MAX))
    else:
        bad("镜像超过 flash 预算")
    if payload_len == total_size - PAYLOAD_OFF:
        ok("payload_len == total_size - 64")
    else:
        bad("payload_len 与 total_size 不一致")
    if app_ddr >= DDR_HOLE_END + 1:
        ok("app 落点 0x%08X 不在 0x0-0xFFF 解码空洞里" % app_ddr)
    else:
        bad("app 落点落在解码空洞")
    if app_ddr + app_len <= DDR_PHYS_LIMIT:
        ok("app 落点 + 长度在物理 DDR 内")
    else:
        bad("app 超出物理 DDR")
    if w_len == 0:
        ok("本镜像无权重（w_len = 0）")
    else:
        if w_ddr >= DDR_HOLE_END + 1 and w_ddr + w_len <= DDR_PHYS_LIMIT:
            ok("权重落点 0x%08X..0x%08X 合法" % (w_ddr, w_ddr + w_len - 1))
        else:
            bad("权重落点越界")
        if (w_ddr >= app_ddr + app_len) or (app_ddr >= w_ddr + w_len):
            ok("权重区与 app 区不重叠")
        else:
            bad("权重区与 app 区重叠")
    if (app_len % 4 == 0) and (w_len % 4 == 0) and (app_ddr % 4 == 0) and (w_ddr % 4 == 0):
        ok("长度/落点都是 4 字节对齐")
    else:
        bad("长度/落点不是 4 的倍数")
    if app_off + app_len <= payload_len and (w_len == 0 or w_off + w_len <= payload_len):
        ok("载荷内偏移不越界")
    else:
        bad("载荷内偏移越界")
    # 额外：app 区是否越过 link_ddr.ld 声称的 1MB 上界
    if app_ddr + app_len <= APP_LIMIT or app_ddr >= APP_LIMIT:
        ok("app 不超过 1MB app 区上界（或有意放在其上）")
    else:
        bad("app 跨过 0x00100000 边界（会和权重区打架）")

    # ---- 3. CRC：位运算实现（与 C 同构） vs zlib 参考实现 ----
    print("[3] CRC32 三重比对")
    payload = img[PAYLOAD_OFF:PAYLOAD_OFF + payload_len]
    c_bit  = crc32_bitwise(payload)
    c_zlib = zlib.crc32(payload) & 0xFFFFFFFF
    if c_bit == c_zlib:
        ok("位运算实现 == zlib.crc32（0x%08X）" % c_bit)
    else:
        bad("位运算 0x%08X != zlib 0x%08X" % (c_bit, c_zlib))
    if c_bit == payload_crc:
        ok("头里的 payload_crc 与重算一致（loader 的 verify_crc 会通过）")
    else:
        bad("头里 0x%08X != 重算 0x%08X" % (payload_crc, c_bit))

    # ---- 4. 模拟 loader 的搬运：把 app/权重按地址计划取出来 ----
    print("[4] 模拟搬运（flash -> “DDR”）")
    app_bytes = payload[app_off:app_off + app_len]
    w_bytes = payload[w_off:w_off + w_len] if w_len else b""
    outdir = os.path.join(here, "build", "_emul")
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "app_at_0x%08X.bin" % app_ddr), "wb").write(app_bytes)
    if w_len:
        open(os.path.join(outdir, "weights_at_0x%08X.bin" % w_ddr), "wb").write(w_bytes)
    ok("写出模拟搬运结果到 %s" % outdir)

    if app_path and os.path.isfile(app_path):
        ref = open(app_path, "rb").read()
        if ref == app_bytes[:len(ref)] and len(app_bytes) == ((len(ref) + 3) // 4) * 4:
            ok("镜像里的 app == %s（对齐后 %d 字节）" % (os.path.basename(app_path), len(app_bytes)))
        else:
            bad("镜像里的 app 与 %s 不一致" % app_path)
    if w_path and os.path.isfile(w_path):
        ref = open(w_path, "rb").read()
        if ref == w_bytes[:len(ref)] and len(w_bytes) == ((len(ref) + 3) // 4) * 4:
            ok("镜像里的权重 == %s（对齐后 %d 字节）" % (os.path.basename(w_path), len(w_bytes)))
        else:
            bad("镜像里的权重与 %s 不一致" % w_path)

    # ---- 5. 顺带算启动时间（推算，不是实测）----
    print("[5] 启动时间推算（不是实测）")
    spi_clk = 100e6 / ((2 + 1) * 2)          # MMT_SPI_CLK_DIV=2，厂商同款配置
    per_byte = 8.0 / spi_clk
    t_copy = total_size * per_byte
    print("      SPI 时钟 = %.2f MHz（clkDivider=2，FCLK=100MHz）" % (spi_clk / 1e6))
    print("      逐字节 Fast Read：每字节 %.0f ns" % (per_byte * 1e9))
    print("      搬 %d 字节 ≈ %.3f s（纯 SPI 时间，CPU 轮询开销与之重叠）" % (total_size, t_copy))
    print("      对比：厂商 16MB bootloader 要搬 16MiB ≈ %.2f s" % (16 * 1024 * 1024 * per_byte))

    print("")
    print("=== 结果：%d 项通过，%d 项失败 ===" % (len(oks), len(fails)))
    for m in fails:
        print("  !! " + m)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
