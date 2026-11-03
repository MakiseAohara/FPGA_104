
import re, zlib, sys
from pathlib import Path
p = Path(r'C:\Users\Makise Aohara\Downloads\Ti60F225A_V4_SCH.pdf')
data = p.read_bytes()

# 1) 收集所有流并解压
streams = []
for m in re.finditer(rb"<<(.*?)>>\s*stream\r?\n", data, re.S):
    start = m.end(); end = data.find(b"endstream", start)
    if end < 0: continue
    raw = data[start:end]
    if b"FlateDecode" in m.group(1):
        try: raw = zlib.decompress(raw)
        except Exception: continue
    streams.append(raw)

# 2) 解析 ToUnicode CMap
cmap = {}
for s in streams:
    if b"beginbfchar" not in s and b"beginbfrange" not in s:
        continue
    for blk in re.findall(rb"beginbfchar(.*?)endbfchar", s, re.S):
        for src, dst in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            try:
                code = int(src, 16)
                u = bytes.fromhex(dst.decode()).decode('utf-16-be', 'ignore')
                cmap.setdefault(code, u)
            except Exception: pass
    for blk in re.findall(rb"beginbfrange(.*?)endbfrange", s, re.S):
        for lo, hi, dst in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            try:
                lo_i, hi_i = int(lo,16), int(hi,16)
                base = bytes.fromhex(dst.decode()).decode('utf-16-be','ignore')
                if len(base) == 1:
                    for k in range(lo_i, min(hi_i, lo_i+400)+1):
                        cmap.setdefault(k, chr(ord(base)+k-lo_i))
            except Exception: pass
print('CMap 条目:', len(cmap))

# 3) 用 map 还原文本
out = []
for s in streams:
    if b"BT" not in s: continue
    for m in re.finditer(rb"\((?:\\.|[^\\()])*\)", s):
        b = m.group(0)[1:-1]
        try: t = b.decode('latin-1')
        except Exception: continue
        codes = [ord(c) for c in t]
        out.append(''.join(cmap.get(c, '') for c in codes))
text = '\n'.join(out)
Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\eth_rgmii\sch_text2.txt').write_text(text, encoding='utf-8')
print('还原文本长度:', len(text))
for kw in ('RGMII','MDIO','MDC','PHY','ETH','RJ45','TXD','RXD'):
    n = text.upper().count(kw)
    if n: print('  含', kw, n, '次')
print('--- 样例 ---')
print(text[:400].replace('\n',' | '))
