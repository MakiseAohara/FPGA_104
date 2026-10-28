#!/usr/bin/env python3
"""replay_ir_solo.py - offline A/B of the IR-solo start path on v28 ticks.

Replays the exact v29-bright decision loop twice over evidence/v28_gate/ticks.csv:
  A) IR_SOLO_ON = 0  (fusion only, i.e. today's behaviour)
  B) IR_SOLO_ON = 1  (fusion OR 6 consecutive ir_hot)
and reports every start that exists only in B (the new path) with its device_ms,
plus whether any of them corresponds to an alarm the fusion path never raised.
"""
import csv
import pathlib

TICKS = pathlib.Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-26\yo\work"
                     r"\FPGA_104-main\evidence\v28_gate\ticks.csv")

# --- constants mirrored from main_live29_bright.cc -------------------------
AI_P_TH = 0
AI_VOTE_N = 3
AI_VOTE_K = 2
AI_P_STRONG = 60
AI_P_OFF = -60
AI_AREA_MIN = 200
AI_AREA_MAX = 20000
DEC_CAND_FRAMES = 6
IR_WIN = 10
IR_NEED = 2
IR_OFF_WIN = 15
IR_SOLO_N = 6


def run(rows, ir_solo_on):
    ai_hist = [-128] * AI_VOTE_N
    ai_idx = ai_fill = 0
    ai_p_now = -128
    person_off = 0
    ir_hist = [0] * IR_OFF_WIN
    ir_idx = 0
    cand_left = 0
    alarm = 0
    starts = []
    for r in rows:
        lp = int(r["lp"])
        ir = int(r["irhot"])
        if lp:
            ir_hist = [0] * IR_OFF_WIN
            ir_idx = 0
            ir_cnt10 = ir_cnt15 = ir_cnt6 = 0
        else:
            ir_hist[ir_idx] = 1 if ir else 0
            ir_idx = (ir_idx + 1) % IR_OFF_WIN
            ir_cnt10 = ir_cnt15 = ir_cnt6 = 0
            for i in range(IR_OFF_WIN):
                v = ir_hist[(ir_idx + IR_OFF_WIN - 1 - i) % IR_OFF_WIN]
                ir_cnt15 += v
                if i < IR_WIN:
                    ir_cnt10 += v
                if i < IR_SOLO_N:
                    ir_cnt6 += v

        motion = int(r["motion"])
        area = int(r["area"])
        if motion and AI_AREA_MIN <= area <= AI_AREA_MAX:
            cand_left = DEC_CAND_FRAMES
        elif cand_left > 0:
            cand_left -= 1

        p = r["p"]
        infer = p not in ("", None)
        person = 0
        if infer:
            p = int(p)
            ai_hist[ai_idx] = p
            ai_idx = (ai_idx + 1) % AI_VOTE_N
            if ai_fill < AI_VOTE_N:
                ai_fill += 1
            ai_p_now = p
            on = sum(1 for i in range(ai_fill) if ai_hist[i] >= AI_P_TH)
            off = sum(1 for i in range(ai_fill) if ai_hist[i] < AI_P_OFF)
            person_off = 1 if (ai_fill >= AI_VOTE_N and off == AI_VOTE_N) else 0
            person = 1 if on >= AI_VOTE_K else 0

        if not alarm:
            fusion = (cand_left > 0) and ((ir_cnt10 >= IR_NEED) or (ai_p_now >= AI_P_STRONG))
            solo = bool(ir_solo_on and ir_cnt6 >= IR_SOLO_N)
            if fusion or solo:
                alarm = 1
                starts.append(dict(ms=int(r["device_ms"]), fusion=int(bool(fusion)),
                                   solo=int(solo), ir_cnt6=ir_cnt6,
                                   motion=motion, area=area,
                                   p="" if not infer else p, person=person))
        else:
            if infer and person_off and ir_cnt15 == 0:
                alarm = 0
    return starts


def main():
    with TICKS.open(encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    print("ticks=%d  irhot=1 占 %.1f%%" %
          (len(rows), 100.0 * sum(1 for r in rows if r["irhot"] == "1") / len(rows)))

    a = run(rows, False)
    b = run(rows, True)
    print("A) IR_SOLO_ON=0  起报 %d 次" % len(a))
    print("B) IR_SOLO_ON=1  起报 %d 次" % len(b))

    a_ms = {s["ms"] for s in a}
    extra = [s for s in b if s["ms"] not in a_ms]
    print()
    print("新路径额外触发: %d 次" % len(extra))
    if extra:
        print()
        print("| # | device_ms | 秒 | ir_cnt6 | motion | area | p | 说明 |")
        print("|---|---|---|---|---|---|---|---|")
        for i, s in enumerate(extra, 1):
            print("| %d | %d | %.1f | %d | %d | %d | %s | 仅 ir_solo 触发 |"
                  % (i, s["ms"], s["ms"] / 1000.0, s["ir_cnt6"], s["motion"],
                     s["area"], s["p"]))
    else:
        print("（无：本段数据里 fusion 路径已覆盖全部起报点）")

    # 每一次 B 的起报按 cause 分类
    only_fusion = sum(1 for s in b if s["fusion"] and not s["solo"])
    both = sum(1 for s in b if s["fusion"] and s["solo"])
    only_solo = sum(1 for s in b if s["solo"] and not s["fusion"])
    print()
    print("B 的起因分布: 仅 fusion %d / 两者同时 %d / 仅 ir_solo %d"
          % (only_fusion, both, only_solo))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
