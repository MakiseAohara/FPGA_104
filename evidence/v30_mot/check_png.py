from PIL import Image
im = Image.open(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\evidence\v30_mot\out_frame.png")
print("format", im.format, "size", im.size, "mode", im.mode)
px = im.load()
print("pixel(0,0)=", px[0,0], "pixel(10,5)=", px[10,5], "expect", (0*2+0)&0xFF, (10*2+5)&0xFF)
ok = all(px[i,j] == ((i*2+j)&0xFF) for j in range(0,96,7) for i in range(0,96,7))
print("pixels match:", ok)
