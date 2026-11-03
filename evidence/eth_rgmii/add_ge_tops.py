import pathlib, re
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
prj_p = ROOT / 'ti60f225_oob.xml'
prj = prj_p.read_text(encoding='utf-8')
for rel in ['rtl/ge/udp_test_top.v', 'rtl/ge/util_gmii_to_rgmii.v']:
    if 'name="%s"' % rel in prj:
        continue
    prj = prj.replace('    </efx:design_info>',
        '        <efx:design_file name="%s" version="default" library="default"/>\n    </efx:design_info>' % rel, 1)
prj_p.write_text(prj, encoding='utf-8')
print('ge entries now:', len(re.findall(r'rtl/ge/', prj)))
