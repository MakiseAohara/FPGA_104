#!/usr/bin/env python3
# P1：旧 2025.2 网表 vs V2(2026.1 厂商) 网表的 FF 实例名对比（指挥官 #16 第三条）
import re, sys, collections
INST = re.compile(r'^\s*EFX_FF\s+\\(\S+?)\s+\(')
def names(p):
    s=set()
    with open(p, encoding='utf-8', errors='replace') as f:
        for l in f:
            m=INST.match(l)
            if m: s.add(m.group(1))
    return s
A = names(r'D:\FPGA\易灵思\工作区\07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\outflow\ti60f225_oob.map.v')
B = names(r'D:\FPGA\mmt\_synth_loop\v_vendor\out_v2\ti60f225_oob_top.postsyn.v')
print(f"旧(2025.2) FF = {len(A)}   V2(2026.1) FF = {len(B)}")
onlyA = A - B; onlyB = B - A; both = A & B
print(f"共有 = {len(both)}   旧独有 = {len(onlyA)}   V2独有 = {len(onlyB)}")
def grp(names_, n=3):
    c = collections.Counter()
    for x in names_:
        seg = x.split('/')
        c['/'.join(seg[:n]) if len(seg) > n else '/'.join(seg[:-1]) or '(top)'] += 1
    return c
print("\n== 旧独有 Top 30 ==")
for k,v in grp(onlyA).most_common(30): print(f"  {v:6d}  {k}")
print("\n== V2 独有 Top 30 ==")
for k,v in grp(onlyB).most_common(30): print(f"  {v:6d}  {k}")
print("\n== 共有里与写通路相关的样本 ==")
w = [x for x in both if any(k in x for k in ('ddr_wr_buffer','bank_switch','ddr_buffer','frame_buffer'))]
print(f"  共有中写通路相关 = {len(w)}")
for x in sorted(w)[:15]: print("   ", x)
print("\n== 旧独有里与写通路相关的（前 25）==")
wo = [x for x in onlyA if any(k in x for k in ('ddr_wr_buffer','bank_switch','ddr_buffer','frame_buffer'))]
print(f"  旧独有中写通路相关 = {len(wo)}")
for x in sorted(wo)[:25]: print("   ", x)
