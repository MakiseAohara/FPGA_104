import re
from pathlib import Path
lines = Path(r"out\hdcp_check\serial.log").read_text(encoding="utf-8", errors="replace").splitlines()
for tag in ("MMT_FIXED", "MMT_IMGSTAT", "MMT_GE ", "MMT_THUMB_GEO", "MMT_HOTSRC"):
    got = [l for l in lines if tag in l]
    print("==", tag, len(got))
    for l in got[:3]:
        print("   ", l[:230])
