#!/usr/bin/env python3
"""check_v20.py - confirm v20 did not change decisions.

1. replay the v19_board logs through the (identical) v19/v20 decision logic
2. compare the replay-derived alarm start/end count with the MMT_ALARM lines
   the firmware itself emitted in those logs
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "v19"))
from replay19 import V19                                    # noqa: E402

BOARD = HERE.parent / "v19_board"
RE_OSD = re.compile(r"MMT_OSD .*?\bp=(-?\d+)")
RE_DEC = re.compile(r"MMT_DEC t=(\d+).*?\balarm_req=(\d+).*?\bmotion=(\d+).*?\barea=(\d+).*?\bperson=(-?\d+)")
RE_ALARM = re.compile(r"MMT_ALARM (start|end) ms=(\d+)")


def run(log: Path):
    v = V19()
    motion = area = person = 0
    pending = 0
    fw = []          # firmware's own MMT_ALARM events
    alarm_frames = 0
    dec_frames = 0
    for raw in log.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        m = RE_ALARM.search(s)
        if m:
            fw.append((m.group(1), int(m.group(2))))
            continue
        m = RE_OSD.search(s)
        if m:
            person = v.vote(int(m.group(1)))
            pending = 1
            continue
        m = RE_DEC.search(s)
        if m:
            motion = int(m.group(3))
            area = int(m.group(4))
            st = v.step(motion, area, person, pending)
            pending = 0
            person = 0
            dec_frames += 1
            if st:
                alarm_frames += 1
    return dict(starts=v.starts, ends=v.ends, dec=dec_frames,
                alarm_frames=alarm_frames, fw_starts=sum(1 for x in fw if x[0] == "start"),
                fw_ends=sum(1 for x in fw if x[0] == "end"))


def main():
    ok = True
    for name in ("log_v19_A_dump.log", "log_v19_B_official.log"):
        r = run(BOARD / name)
        same = (r["starts"] == r["fw_starts"] and r["ends"] == r["fw_ends"])
        ok = ok and same
        print("%-26s DEC=%4d 报警帧=%4d | 回放 start/end=%d/%d  "
              "固件 MMT_ALARM start/end=%d/%d  %s"
              % (name, r["dec"], r["alarm_frames"], r["starts"], r["ends"],
                 r["fw_starts"], r["fw_ends"], "一致" if same else "不一致"))
    print("\n结论:", "决策逻辑未改坏（回放与固件自身报警事件一致）" if ok else "不一致，需停下")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
