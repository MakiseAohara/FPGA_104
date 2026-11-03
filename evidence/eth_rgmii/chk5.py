import glob, re
from pathlib import Path
pat = re.compile(r"MMT_OSD f=(\d+) chk=([0-9a-f]+) p=(-?\d+) a=(-?\d+) v=(\d+) osd=(\d+) ci=(\d+)")
for f in ["out/hdcp_check/serial.log", "out/final_e15/serial.log", "out/ev3/serial.log", "out/live_base_final/serial.log"]:
    p = Path(f)
    if not p.exists():
        print(f, "MISSING"); continue
    rows = [m.groups() for m in (pat.search(l) for l in p.read_text(encoding="utf-8", errors="replace").splitlines()) if m]
    print("%-32s OSD 行 %3d" % (f, len(rows)))
    for r in rows[:2] + rows[-2:]:
        print("    f=%s chk=%s p=%s a=%s v=%s osd=%s ci=%s" % r)
