"""Remove duplicated support files that collide with the camera project's own modules.

rtl/reset.v already defines module `reset`, so source/common/common_reset.v
(same module name) must not be compiled in this project.
"""
import re
from pathlib import Path

ROOT = Path(r"_p2a\v7_camera_ai")
XML = ROOT / "ti60f225_oob.xml"
ENC = "gb18030"

DROP = ["source/common/common_reset.v", "source/common/common_reset_ctrl.v"]


def main():
    x = XML.read_text(encoding=ENC)
    for rel in DROP:
        before = x
        x = re.sub(r'^[ \t]*<efx:design_file name="%s"[^>]*/>\n' % re.escape(rel), "", x, flags=re.M)
        if x != before:
            print("removed from XML:", rel)
        f = ROOT / Path(rel)
        if f.exists():
            f.unlink()
            print("deleted file:", rel)
    XML.write_text(x, encoding=ENC)
    print("source/common entries left:", x.count("source/common/"))


if __name__ == "__main__":
    main()
