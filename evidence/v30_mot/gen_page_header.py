import pathlib, hashlib
root = pathlib.Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104")
src = (root / "tools" / "page.html").read_bytes()
out = root / "evidence" / "v30_mot" / "page_html.h"
lines = []
lines.append("/* generated from tools/page.html  (%d bytes, sha256 %s) */" % (len(src), hashlib.sha256(src).hexdigest()[:16]))
lines.append("#ifndef PAGE_HTML_H")
lines.append("#define PAGE_HTML_H")
lines.append("static const unsigned char page_html[%d] = {" % len(src))
for i in range(0, len(src), 16):
    lines.append("   " + ", ".join("0x%02X" % b for b in src[i:i+16]) + ",")
lines.append("};")
lines.append("#define PAGE_HTML_LEN %d" % len(src))
lines.append("#endif")
out.write_text("\n".join(lines) + "\n", encoding="ascii")
print("wrote page_html.h", len(src), "bytes ->", out.stat().st_size)
