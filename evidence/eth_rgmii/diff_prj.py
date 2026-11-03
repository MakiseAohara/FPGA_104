import xml.etree.ElementTree as ET
NS = {'efx': 'http://www.efinixinc.com/enf_proj'}
def names(p):
    t = ET.parse(p); r = t.getroot()
    return [d.get('name') for d in r.iter('{http://www.efinixinc.com/enf_proj}design_file')]
a = names(r'D:\v30_build\m17\ti60f225_oob.xml')
b = names(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
print('orig count', len(a), 'new count', len(b))
sa, sb = set(a), set(b)
print('lost:', sorted(sa - sb))
print('added:', len(sb - sa))
