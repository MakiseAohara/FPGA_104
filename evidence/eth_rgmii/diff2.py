import re, pathlib
def names(p):
    t = pathlib.Path(p).read_text(encoding='utf-8', errors='replace')
    return re.findall(r'<efx:design_file name="([^"]+)"', t)
a = names(r'D:\v30_build\m17\ti60f225_oob.xml')
b = names(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
print('pristine', len(a), 'patched', len(b))
print('only in pristine:', [x for x in a if x not in b])
print('only in patched :', [x for x in b if x not in a][:8], '...')
# 结构对比：把 design_info 段打印出来看看
t = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml').read_text(encoding='utf-8', errors='replace')
i = t.find('<efx:design_info'); j = t.find('</efx:design_info>')
seg = t[i:j]
print(seg[:300].replace('\r',''))
print('--- tail ---')
print(seg[-400:].replace('\r',''))
