import pathlib
src = pathlib.Path(r'D:\v30_build\m17\ti60f225_oob.xml')
dst = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
data = src.read_bytes()
dst.write_bytes(data + b'\r\n')
print('no-op patch (trailing newline), size', len(data) + 2)
