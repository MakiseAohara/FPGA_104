"""mark.py - 往 capture_session 的 marks.txt 追加一条 MARK（供第二个人/脚本打点）"""
import sys, time
from pathlib import Path
out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(r"out/session_20261101")
text = " ".join(sys.argv[2:]) or "mark"
p = out / "marks.txt"
p.parent.mkdir(parents=True, exist_ok=True)
with p.open("a", encoding="utf-8") as f:
    f.write("%s %s\n" % (time.strftime("%H:%M:%S"), text))
print("marked:", text)