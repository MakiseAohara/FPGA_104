"""capture_mot.py - v30 A-E 上板采集（带提示音与大字提示）"""
import argparse, json, sys, time
from pathlib import Path
import serial
try:
    import winsound
except Exception:
    winsound = None

STEPS = []
def add(name, secs, prompt):
    STEPS.append((name, secs, prompt))

add("READY", 60, "准备：站到画面外。听到提示音后 A0 开始（45 秒后）")
add("A0", 10, "空场 10 秒：所有人离开画面")
for i in range(1, 21):
    d = ["左", "右", "下", "上"][(i - 1) % 4]
    add("A%d" % i, 10, "第 %d/20 次：从【%s】侧走进画面 → 中间停 3 秒 → 走出去" % (i, d))
add("B1", 20, "站定 20 秒：站在画面中间，正面朝镜头，不要动")
add("B2", 45, "慢走来回 3 趟（慢一点，每趟约 7 秒）")
add("B3", 35, "快走来回 3 趟（比刚才快一倍）")
add("C1", 30, "一只手拿会晃的东西（毛巾/纸板）在画面一侧持续摆动，同时人在另一侧走动")
add("D", 30, "手持/轻转摄像头晃动 3 次，每次 3 秒，中间停 5 秒（看是否产生航迹/预警）")
add("E", 60, "空场 60 秒：全部离开画面")

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM15")
ap.add_argument("--out", type=Path, default=Path("out/mot_check"))
ap.add_argument("--scale", type=float, default=1.0)
ap.add_argument("--only", default="", help="只跑指定阶段，逗号分隔，例如 D,E")
a = ap.parse_args()
if a.only:
    want = set(x.strip() for x in a.only.split(",") if x.strip())
    STEPS = [st for st in STEPS if st[0] in want or (st[0].startswith("A") and "A" in want)]
    if not STEPS:
        raise SystemExit("no steps selected")
a.out.mkdir(parents=True, exist_ok=True)

def beep(n=1):
    if winsound:
        for _ in range(n):
            winsound.Beep(1300, 300)
            time.sleep(0.1)

log = (a.out / "serial.log").open("w", encoding="utf-8", newline="\n")
buf = bytearray()
man = dict(start=time.strftime("%Y-%m-%dT%H:%M:%S"), steps=[])
print("=" * 60, flush=True)
print("准备开始：A 阶段 20 次进入，听到提示音就按屏幕上写的方式做", flush=True)
print("=" * 60, flush=True)
beep(3)
time.sleep(3)

with serial.Serial(a.port, 115200, timeout=0.05) as port:
    port.reset_input_buffer()
    for name, secs, prompt in STEPS:
        beep(1)
        t0 = time.monotonic()
        print("\n>>> [%s] %s（%ds）" % (name, prompt, int(secs * a.scale)), flush=True)
        print("=" * 60, flush=True)
        n = 0
        while time.monotonic() - t0 < secs * a.scale:
            chunk = port.read(max(1, port.in_waiting))
            if not chunk:
                continue
            buf.extend(chunk)
            while b"\n" in buf:
                line, tail = buf.split(b"\n", 1)
                buf[:] = tail
                text = line.decode("ascii", errors="replace").rstrip("\r")
                log.write("%s %8.3f %s\n" % (name, time.monotonic() - t0, text))
                n += 1
        log.flush()
        man["steps"].append(dict(name=name, prompt=prompt, dur_s=round(secs * a.scale, 1), lines=n))
    beep(2)
log.close()
man["end"] = time.strftime("%Y-%m-%dT%H:%M:%S")
(a.out / "manifest.json").write_text(json.dumps(man, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("DONE", len(STEPS), "steps")