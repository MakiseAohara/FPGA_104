import pathlib
src = pathlib.Path(r'D:\v30_build\m17\ti60f225_oob.xml')
dst = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
data = src.read_bytes()
ins = b'        <efx:design_file name="rtl/ge/udp_test_top.v" version="default" library="default"/>\r\n'
anchor = b'    </efx:design_info>'
data = data.replace(anchor, ins + anchor, 1)
dst.write_bytes(data)
print('wrote minimal patch, size', len(data))
