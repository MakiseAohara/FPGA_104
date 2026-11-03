# -*- coding: utf-8 -*-
"""clean_ge.py - 只保留厂商工程里真正被编译的那批 GE 文件。"""
import pathlib, re, shutil
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
ge = ROOT / 'rtl' / 'ge'
# 删除 Quartus IP / 重复 / 未使用的顶层
for rel in ['heijin_test/ip', 'heijin_test/rgmii2gmii_altera', 'heijin_test/mdio',
            'heijin_test/ethernet_test.v', 'heijin_test/eth_test_tb.v',
            'rgmii']:
    p = ge / rel
    if p.is_dir():
        shutil.rmtree(p)
    elif p.exists():
        p.unlink()
keep = sorted(p for p in ge.rglob('*.v'))
print('kept %d files:' % len(keep))
for p in keep:
    print('  ', p.relative_to(ROOT).as_posix())
# 重建工程文件表里的 rtl/ge 条目
prj_p = ROOT / 'ti60f225_oob.xml'
prj = prj_p.read_text(encoding='utf-8')
prj = re.sub(r'\s*<efx:design_file name="rtl/ge/[^"]+"[^/]*/>', '', prj)
ins = ''.join('        <efx:design_file name="%s" version="default" library="default"/>\n'
              % p.relative_to(ROOT).as_posix() for p in keep)
prj = prj.replace('    </efx:design_info>', ins + '    </efx:design_info>', 1)
prj_p.write_text(prj, encoding='utf-8')
print('project xml ge entries:', len(keep))
