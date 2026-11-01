r"""capture_session.py - 串口记录 + 键盘 MARK 打点（无窗口）

用法：
  py -3 tools\capture_session.py --out out\session_20261101 [--port COM15]

按键（终端里直接按，不用回车）：
  1 空场开始   2 人进入    3 人离开    4 按 KEY1   5 按 KEY2
  6 听到蜂鸣   7 没听到蜂鸣 8 屏幕显示 LOWPWR  9 屏幕没显示 LOWPWR
  q 退出并存 manifest
额外：每 200 ms 检查 <out>\marks.txt，新行会作为 MARK 插进日志（供第二个人/脚本打点）
"""
import argparse, hashlib, json, sys, time, zlib
from pathlib import Path

import serial

try:
    import msvcrt
except Exception:
    msvcrt = None

KEYS = {
    "1": "空场开始", "2": "人进入", "3": "人离开", "4": "按 KEY1",
    "5": "按 KEY2", "6": "听到蜂鸣", "7": "没听到蜂鸣",
    "8": "屏幕显示 LOWPWR", "9": "屏幕没显示 LOWPWR",
}

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM15")
ap.add_argument("--out", type=Path, default=Path("out/session_20261101"))
ap.add_argument("--minutes", type=float, default=0.0, help="到点自动停止（0=一直录）")
ap.add_argument("--fw", default=r"FPGA_104\evidence\v29_fw\tinyml_pdti8_v292_day.bin")
ap.add_argument("--bit", default=r"FPGA_104\evidence\v29_rtl_ir_rot\v7_MERGE17.bit")
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
logp = a.out / "serial.log"
marksp = a.out / "marks.txt"
if not marksp.exists():
    marksp.write_text("", encoding="utf-8")

def crc32_of(p):
    try:
        return format(zlib.crc32(Path(p).read_bytes()) & 0xffffffff, "08X")
    except Exception:
        return None

def sha_of(p):
    try:
        return hashlib.sha256(Path(p).read_bytes()).hexdigest().upper()
    except Exception:
        return None

marks_seen = 0
log = logp.open("a", encoding="utf-8", newline="\n")
start = time.time()
n_marks = 0

def emit(text):
    global n_marks
    ts = time.strftime("%H:%M:%S") + (".%03d" % int((time.time() % 1) * 1000))
    log.write("%s %s\n" % (ts, text))
    log.flush()

def mark(label):
    global n_marks
    n_marks += 1
    emit("MARK %s %s" % (time.strftime("%H:%M:%S"), label))
    print("\n>>> MARK %s <<<\n" % label, flush=True)

print("=" * 64, flush=True)
print("记录开始：", a.out, " 端口", a.port, flush=True)
print("按键：1 空场 2 人进 3 人离 4 KEY1 5 KEY2 6 蜂鸣响 7 蜂鸣不响 8 有LOWPWR 9 无LOWPWR  q 退出", flush=True)
print("=" * 64, flush=True)

deadline = time.time() + a.minutes * 60 if a.minutes > 0 else None
with serial.Serial(a.port, 115200, timeout=0.05) as port:
    port.reset_input_buffer()
    buf = bytearray()
    try:
        while True:
            if deadline and time.time() > deadline:
                print("\n到时自动停止", flush=True)
                break
            chunk = port.read(max(1, port.in_waiting))
            if chunk:
                buf.extend(chunk)
                while b"\n" in buf:
                    line, tail = buf.split(b"\n", 1)
                    buf[:] = tail
                    emit(line.decode("ascii", errors="replace").rstrip("\r"))
            while msvcrt and msvcrt.kbhit():
                ch = msvcrt.getch().decode("ascii", errors="ignore").lower()
                if ch == "q":
                    raise KeyboardInterrupt
                if ch in KEYS:
                    mark(KEYS[ch])
            if marksp.exists():
                lines = marksp.read_text(encoding="utf-8", errors="replace").splitlines()
                while marks_seen < len(lines):
                    mark(lines[marks_seen].strip() or "(空)")
                    marks_seen += 1
    except KeyboardInterrupt:
        pass

log.close()
man = dict(
    port=a.port,
    start=time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(start)),
    end=time.strftime("%Y-%m-%dT%H:%M:%S"),
    seconds=round(time.time() - start, 1),
    marks=n_marks,
    firmware=dict(path=str(a.fw), crc32=crc32_of(a.fw)),
    bitstream=dict(path=str(a.bit), sha256=sha_of(a.bit)),
    log=str(logp),
)
(a.out / "manifest.json").write_text(json.dumps(man, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("\n记录结束，共 %d 个 MARK，%s" % (n_marks, a.out / "manifest.json"), flush=True)