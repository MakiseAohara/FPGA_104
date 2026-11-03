import pathlib
prj = pathlib.Path(r'D:\eth_build\ge\led_demo.xml')
lines = prj.read_bytes().split(b'\n')
if not any(b'ge_raw_test.v' in l for l in lines):
    for i, l in enumerate(lines):
        if b'name="rtl/top.v"' in l:
            lines.insert(i + 1, b'        <efx:design_file name="rtl/ge_raw_test.v" version="default" library="default"/>')
            break
    prj.write_bytes(b'\n'.join(lines))
    print('added')
else:
    print('present')
