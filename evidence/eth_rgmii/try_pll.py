# -*- coding: utf-8 -*-
"""try_pll.py <name> - 换 pll_def 并跑 interface，打印 issue 摘要。"""
import re, sys, pathlib, subprocess
name = sys.argv[1]
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml')
t = p.read_text(encoding='utf-8')
t = re.sub(r'(<efxpt:pll name="ge_0_gclk_pll" pll_def=")[A-Z0-9_]+(")', r'\g<1>' + name + r'\g<2>', t)
p.write_text(t, encoding='utf-8')
r = subprocess.run([r'D:\Efinity\2026.1\bin\efx_run.bat', 'ti60f225_oob.xml', '-f', 'interface'],
                   cwd=r'D:\eth_build\m17_ge', capture_output=True, text=True, errors='replace', timeout=600)
iss = pathlib.Path(r'D:\eth_build\m17_ge\outflow\design_issue.xml')
msg = 'no issue file'
if iss.exists():
    txt = iss.read_text(encoding='utf-8', errors='replace')
    msgs = re.findall(r'severity="(\w+)".*?message="([^"]*)"', txt)
    msg = '; '.join('%s:%s' % (s, m[:60]) for s, m in msgs) or 'clean'
print(name, '->', 'PASS' if 'interface :\tPASS' in (r.stdout or '') else 'FAIL', '|', msg[:200])
