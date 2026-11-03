import re
from pathlib import Path
lines = Path("out/lp_check/serial.log").read_text(encoding="utf-8", errors="replace").splitlines()
lp = [l for l in lines if "MMT_LP " in l]
mot = [l for l in lines if "MMT_MOT f=" in l]
print("LP 行", len(lp), " MOT 行", len(mot))
for l in lp[-2:]: print(l[:150])
for l in mot[-2:]: print(l[:120])
