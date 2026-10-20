"""Add the AI project's source/common + source/axi support libraries.

The TinyML accelerator's protected core instantiates helper modules that live in
source/common (FIFO wrapper, reset, APB3, RAM wrappers) and source/axi. Without
them the encrypted envelope cannot resolve its instantiations and the tool
reports "instantiating unknown module '**'".
"""
import shutil
from pathlib import Path

AI = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-15"
          r"\https-github-com-makiseaohara-fpga-104\work\peripherals-20261020\ai_ddr_09")
ROOT = Path(r"_p2a\v7_camera_ai")
XML = ROOT / "ti60f225_oob.xml"
ENC = "gb18030"

SUBDIRS = ["source/common", "source/axi"]


def main():
    added = []
    for sub in SUBDIRS:
        src = AI / Path(sub)
        dst = ROOT / Path(sub)
        if not src.exists():
            print("skip missing", src)
            continue
        for f in src.rglob("*"):
            if f.is_file() and f.suffix in (".v", ".sv", ".vh"):
                rel = f.relative_to(AI)
                out = ROOT / rel
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, out)
                added.append(str(rel).replace("\\", "/"))
    print("copied %d support files" % len(added))

    x = XML.read_text(encoding=ENC)
    new = []
    for rel in sorted(added):
        if rel not in x:
            new.append('        <efx:design_file name="%s" version="default" library="default"/>\n' % rel)
    if not new:
        print("XML already has them")
        return
    import re
    m = re.search(r'^[ \t]*<efx:design_file [^>]*/>\n', x, re.M)
    x = x[:m.start()] + "".join(new) + x[m.start():]
    XML.write_text(x, encoding=ENC)
    print("XML: added %d design_file entries" % len(new))


if __name__ == "__main__":
    main()
