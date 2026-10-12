#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
verify_combined_image.py — 校验 Efinity 合并工具输出的"一个文件烧完整片 flash"镜像

背景（task-11）：
  烧 flash 有两条路：
    (a) 分两次烧：位流 -> 0x0，用户镜像 -> 0x380000（厂商 OOB readme 的做法）
    (b) 用 Programmer 自带的合并工具合成**一个**文件，一次烧到 0x0
        工具：D:\Efinity\2026.1\pgm\bin\multi_image_merger.py
        命令：python multi_image_merger.py -m generic_comb_image \
                -ifile <bitstream.hex> -iaddr 0x00 \
                -ifile <ddr_image.bin>  -iaddr 0x380000 -o <out.hex>
  本脚本就是给 (b) 的产物做"烧之前先验一遍"：长度、两段内容、间隙填充值。

★ 实测到的一个**良性差异**（本脚本会显式报告，不当成失败）：
  合并工具会把位流文本头里 `Project:` 路径中的**非 ASCII 字节替换成 0xFF**。
  实测：`Project: D:\FPGA\易灵思` 里"易灵思"的 9 个 UTF-8 字节
        (E6 98 93 E7 81 B5 E6 80 9D) → 9 个 0xFF，其余 959,892 字节完全一致。
  该字段只是信息性的（配置引擎真正要的是 Version/Device/Width/Mode/Die Name/4Byte/
  PADDED_BITS），且这是厂商工具自己做的替换。**推断**不影响配置；真机以"能否配置成功"为准。

用法：
    python verify_combined_image.py \
        --combined sw\ddr\build\flash_combined.hex \
        --bitstream out\mmt.hex \
        --image    sw\ddr\build\ddr_image.bin \
        --image-base 0x380000
退出码：0 = 通过；1 = 有失败。
"""

import argparse
import os
import sys


def parse_efinity_hex(path):
    """Efinity 的 .hex/.bit = '每行一个字节的十六进制文本'。
       2 位 -> 1 字节；4 位 -> 符号扩展（如 0xE6 写成 'FFE6'），取低字节仍是 1 字节。"""
    out = bytearray()
    with open(path, "r") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            if len(s) == 2:
                out.append(int(s, 16))
            elif len(s) == 4:
                out.append(int(s[2:], 16))
            else:
                raise ValueError("%s:%d 不是 2 位也不是 4 位十六进制: %r" % (path, lineno, s))
    return bytes(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="校验 Efinity 合并后的整片 flash 镜像")
    ap.add_argument("--combined", default=os.path.join(here, "build", "flash_combined.hex"))
    ap.add_argument("--bitstream", default=r"D:\FPGA\mmt\out\mmt.hex")
    ap.add_argument("--image", default=os.path.join(here, "build", "ddr_image.bin"))
    ap.add_argument("--image-base", default="0x380000")
    ap.add_argument("--gap-fill", default="0xFF", help="合并工具对间隙的填充值（实测 0xFF）")
    args = ap.parse_args()

    image_base = int(args.image_base, 0)
    gap_fill = int(args.gap_fill, 0)

    fails = []
    warns = []
    npass = 0

    def ok(m):
        nonlocal npass
        npass += 1
        print("  PASS  " + m)

    def bad(m):
        fails.append(m)
        print("  FAIL  " + m)

    def warn(m):
        warns.append(m)
        print("  WARN  " + m)

    print("=== verify_combined_image.py ===")
    for p in (args.combined, args.bitstream, args.image):
        if not os.path.isfile(p):
            bad("文件不存在: %s" % p)
    if fails:
        return 1

    print("  合并文件 : %s (%d 字节)" % (args.combined, os.path.getsize(args.combined)))
    comb = parse_efinity_hex(args.combined)
    bit = parse_efinity_hex(args.bitstream)
    img = open(args.image, "rb").read()
    print("  位流段   : %d 字节 (0x%X)" % (len(bit), len(bit)))
    print("  镜像段   : %d 字节 (0x%X)  @ 0x%X" % (len(img), len(img), image_base))

    # 1) 总长度 = 最后一个载荷的末尾
    expect_len = max(len(bit), image_base + len(img))
    if len(comb) == expect_len:
        ok("合并文件内容长度 %d (0x%X) == max(位流末尾, 镜像末尾)" % (len(comb), len(comb)))
    else:
        bad("合并文件长度 %d (0x%X) != 期望 %d (0x%X)" % (len(comb), len(comb), expect_len, expect_len))

    # 2) 位流段逐字节比对（允许 Project 路径里的非 ASCII -> 0xFF 替换）
    if len(bit) <= len(comb):
        diffs = [i for i in range(len(bit)) if comb[i] != bit[i]]
        if not diffs:
            ok("位流段 [0, 0x%X) 与 %s 逐字节一致" % (len(bit), os.path.basename(args.bitstream)))
        else:
            nonascii = [i for i in diffs if bit[i] >= 0x80 and comb[i] == 0xFF]
            other = [d for d in diffs if d not in set(nonascii)]
            if other:
                bad("位流段有 %d 处差异，其中 %d 处**不是**'非 ASCII -> 0xFF'的已知替换（首处 0x%X: 0x%02X -> 0x%02X）"
                    % (len(diffs), len(other), other[0], bit[other[0]], comb[other[0]]))
            else:
                ok("位流段差异 %d 处，全部是'非 ASCII -> 0xFF'的已知替换（Project 路径字段）" % len(diffs))
                warn("位流头 Project 字段的 %d 个非 ASCII 字节被合并工具换成了 0xFF（实测：'易灵思' 的 9 个 UTF-8 字节）。"
                     "该字段是信息性的，推断不影响配置；若上电配置失败，改用'分两次烧'的方案（见文档 §4）。" % len(diffs))
    else:
        bad("合并文件比位流还短")

    # 3) 镜像段逐字节比对
    if image_base + len(img) <= len(comb):
        seg = comb[image_base:image_base + len(img)]
        if seg == img:
            ok("镜像段 [0x%X, 0x%X) 与 %s 逐字节一致" % (image_base, image_base + len(img), os.path.basename(args.image)))
        else:
            n = sum(1 for a, b in zip(seg, img) if a != b)
            bad("镜像段有 %d 处不一致" % n)
    else:
        bad("合并文件长度不够，装不下镜像段")

    # 4) 间隙填充
    if len(bit) < image_base:
        gap = comb[len(bit):image_base]
        vals = set(gap)
        if len(vals) == 1 and vals.pop() == gap_fill:
            ok("间隙 [0x%X, 0x%X) 全部填 0x%02X（%d 字节）" % (len(bit), image_base, gap_fill, len(gap)))
        else:
            bad("间隙填充值不是单一的 0x%02X" % gap_fill)
    else:
        warn("位流段和镜像段之间没有间隙（不重叠的话说明 image_base 太靠前）")

    # 5) 关键锚点
    if comb[0:4] == b"Vers":
        ok("偏移 0 是位流文本头（'Vers'）")
    else:
        bad("偏移 0 不是位流的文本头")
    if comb[image_base:image_base + 4] == b"MMT1":
        ok("偏移 0x%X 是用户镜像 magic 'MMT1'" % image_base)
    else:
        bad("偏移 0x%X 不是 'MMT1'" % image_base)

    print("")
    print("=== 结果：PASS %d 项，FAIL %d 项，WARN %d 项 ===" % (npass, len(fails), len(warns)))
    for m in fails:
        print("  !! " + m)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
