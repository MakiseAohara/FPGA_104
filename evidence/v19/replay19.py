#!/usr/bin/env python3
"""replay19.py - replay v18 capture logs through the v19 decision logic (PC side).

The v19 state machine, transcribed from main_live19.cc:

    ai_hist[N=3] holds raw p;  on >= K=2 frames with p >= AI_P_TH(0)  -> person=1
    off  = frames with p <  AI_P_OFF(-40); g_person_off = (fill==3 and off==3)
    cand_left = DEC_CAND_FRAMES(6) when motion && AI_AREA_MIN<=area<=AI_AREA_MAX
    alarm start: person && (cand_left>0 || ai_p_now >= AI_P_STRONG(60))
    alarm end  : infer_ran && g_person_off
"""
import re
import sys
from pathlib import Path

AI_P_TH = 0
AI_VOTE_N = 3
AI_VOTE_K = 2
AI_P_STRONG = 60
AI_P_OFF = -40
DEC_CAND_FRAMES = 6
AI_AREA_MIN = 30
AI_AREA_MAX = 4000


class V19:
    def __init__(self):
        self.hist = [-128] * AI_VOTE_N
        self.idx = 0
        self.fill = 0
        self.p_now = -128
        self.off_all = 0
        self.rel = 0
        self.cand_left = 0
        self.alarm = 0
        self.starts = 0
        self.ends = 0

    def vote(self, p):
        self.hist[self.idx] = p
        self.idx = (self.idx + 1) % AI_VOTE_N
        if self.fill < AI_VOTE_N:
            self.fill += 1
        self.p_now = p
        on = sum(1 for i in range(self.fill) if self.hist[i] >= AI_P_TH)
        off = sum(1 for i in range(self.fill) if self.hist[i] < AI_P_OFF)
        self.rel = off
        self.off_all = 1 if (self.fill >= AI_VOTE_N and off == AI_VOTE_N) else 0
        return 1 if on >= AI_VOTE_K else 0

    def step(self, motion, area, person, infer_ran):
        cand = motion and (AI_AREA_MIN <= area <= AI_AREA_MAX)
        if cand:
            self.cand_left = DEC_CAND_FRAMES
        elif self.cand_left > 0:
            self.cand_left -= 1
        if not self.alarm:
            if person and (self.cand_left > 0 or self.p_now >= AI_P_STRONG):
                self.alarm = 1
                self.starts += 1
        else:
            if infer_ran and self.off_all:
                self.alarm = 0
                self.ends += 1
        return self.alarm


def replay(path: Path):
    ph = None
    stats = {}
    v = V19()
    motion = 0
    area = 0
    person = 0
    pending = False
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = raw.split("\t", 1)[-1].strip()
        m = re.match(r"^### PHASE (\w+)", s)
        if m:
            ph = m.group(1)
            stats.setdefault(ph, {"frames": 0, "alarm": 0, "p": []})
            continue
        if ph is None:
            continue
        if s.startswith("MMT_OSD"):
            x = re.search(r"\bp=(-?\d+)", s)
            if x:
                person = v.vote(int(x.group(1)))
                pending = True
                stats[ph]["p"].append(int(x.group(1)))
            continue
        if s.startswith("MMT_DEC"):
            x = re.search(r"\bmotion=(\d+)", s)
            if x:
                motion = int(x.group(1))
            x = re.search(r"\barea=(\d+)", s)
            if x:
                area = int(x.group(1))
            st = v.step(motion, area, person, 1 if pending else 0)
            pending = False
            stats[ph]["frames"] += 1
            if st:
                stats[ph]["alarm"] += 1
            person = 0            # cleared after each DEC, like infer_ran
    return stats, v


def main():
    base = Path(__file__).resolve().parent.parent
    logs = {
        "round1(原版)": base / "merge14_v18" / "log_merge14_v18.log",
        "dump": base / "merge14_v18_dump" / "log_merge14_v18_dump.log",
    }
    ok = True
    for name, p in logs.items():
        if not p.is_file():
            print("missing", p)
            continue
        st, v = replay(p)
        print(f"== {name}   {p.name}")
        for ph, d in st.items():
            if d["frames"]:
                r = d["alarm"] / d["frames"]
                print("   %-6s 帧%4d 报警%4d (%5.1f%%)  p均%7.1f  n_p=%d"
                      % (ph, d["frames"], d["alarm"], r * 100,
                         (sum(d["p"]) / len(d["p"])) if d["p"] else 0, len(d["p"])))
        print("   alarm start=%d end=%d" % (v.starts, v.ends))

    # ---- acceptance checks from the task
    print("\n-- 判定 --")
    st, _ = replay(logs["dump"])
    q = st.get("quiet", {"frames": 0, "alarm": 0})
    c1 = q["alarm"] == 0
    print("dump 静默段 0 帧报警: %s (报警 %d/%d)"
          % ("OK" if c1 else "FAIL", q["alarm"], q["frames"]))
    st1, _ = replay(logs["round1(原版)"])
    m1 = st1.get("p1m", {"frames": 0, "alarm": 0})
    r1 = m1["alarm"] / m1["frames"] if m1["frames"] else 0
    c2 = r1 >= 0.90
    print("第一轮 p1m 报警占比 >=90%%: %s (%.1f%%)"
          % ("OK" if c2 else "FAIL", r1 * 100))
    _, vw = replay(logs["dump"])
    w = st["walk"]
    rw = w["alarm"] / w["frames"] if w["frames"] else 0
    c3 = (vw.starts == 5 and 0.40 <= rw <= 0.65)
    print("dump 走入段 5 次独立起止 且 占比 40~65%%: %s (start=%d end=%d 占比 %.1f%%)"
          % ("OK" if c3 else "FAIL", vw.starts, vw.ends, rw * 100))
    ok = c1 and c2 and c3
    print("\nRESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
