
import re, zlib
from pathlib import Path
p = Path(r'C:\Users\Makise Aohara\Downloads\Ti60F225A_V4_SCH.pdf')
data = p.read_bytes()
streams = []
for m in re.finditer(rb"<<(.*?)>>\s*stream\r?\n", data, re.S):
    start = m.end(); end = data.find(b"endstream", start)
    if end < 0: continue
    raw = data[start:end]
    if b"FlateDecode" in m.group(1):
        try: raw = zlib.decompress(raw)
        except Exception: continue
    streams.append(raw)

cmap = {}
for s in streams:
    for blk in re.findall(rb"beginbfchar(.*?)endbfchar", s, re.S):
        for src, dst in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            try:
                cmap[int(src,16)] = bytes.fromhex(dst.decode()).decode('utf-16-be','ignore')
            except Exception: pass
    for blk in re.findall(rb"beginbfrange(.*?)endbfrange", s, re.S):
        for lo, hi, dst in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            try:
                lo_i, hi_i = int(lo,16), int(hi,16)
                base = bytes.fromhex(dst.decode()).decode('utf-16-be','ignore')
                if len(base)==1:
                    for k in range(lo_i, min(hi_i, lo_i+300)+1):
                        cmap.setdefault(k, chr(ord(base)+k-lo_i))
            except Exception: pass

def score(t):
    return sum(1 for c in t if c.isalnum())

def dec1(b):   # 1 字节码
    return ''.join(cmap.get(x, '') for x in b)
def dec2(b):   # 2 字节码
    return ''.join(cmap.get(b[i] | (b[i+1]<<8), '') for i in range(0, len(b)-1, 2))

parts = []
for s in streams:
    if b"BT" not in s: continue
    for m in re.finditer(rb"\((?:\\.|[^\\()])*\)", s):
        b = m.group(0)[1:-1]
        a1, a2 = dec1(b), dec2(b)
        parts.append(a2 if score(a2) > score(a1) else a1)
text = '\n'.join(parts)
Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\eth_rgmii\sch_text3.txt').write_text(text, encoding='utf-8')
print('长度', len(text), ' CMap', len(cmap))
for kw in ('RGMII','MDIO','MDC','PHY','RJ45','TXD','RXD','ETH'):
    n = text.upper().count(kw)
    if n: print(' 含', kw, n)
print('--- 样例 ---')
print(text[:300].replace('\n',' | '))
