#!/usr/bin/env python3
"""patch19.py - build main_live19.cc from main_live18.cc per the v19 decision diff.

Besides the specified diff this also adds two fields to the MMT_DEC line:
    t=<device ms>   person=<last_person>
They are required to build ticks.csv (device milliseconds / person) and the
contact sheet labels; without them the firmware emits no device timestamp.
"""
import io
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src" / "main_live18.cc"
DST = HERE / "src" / "main_live19.cc"

s = io.open(SRC, encoding="utf-8").read()
orig = s
applied = []


def sub(pattern, repl, label, flags=0):
    global s
    new, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n == 0:
        print("MISS:", label)
        sys.exit(1)
    s = new
    applied.append(label)


# ---- 1. decision macros -----------------------------------------------------
sub(r"#define AI_P_TH\s+\(-40\)[^\n]*",
    "#define AI_P_TH          (0)", "AI_P_TH 0")
sub(r"#define AI_VOTE_N\s+4\b[^\n]*",
    "#define AI_VOTE_N        3", "AI_VOTE_N 3")
sub(r"#define AI_VOTE_K\s+1\b[^\n]*",
    "#define AI_VOTE_K        2\n"
    "#define AI_P_STRONG      60\n"
    "#define AI_P_OFF         (-40)", "AI_VOTE_K 2 + AI_P_STRONG/AI_P_OFF")
sub(r"#define DEC_CAND_FRAMES\s+8\b[^\n]*",
    "#define DEC_CAND_FRAMES  6", "DEC_CAND_FRAMES 6")

# ---- 2. ai_vote_update rewrite ---------------------------------------------
old_vote = re.search(
    r"static int ai_vote_update\(int p\)\s*\{.*?\n\}",
    s, re.S)
if not old_vote:
    print("MISS: ai_vote_update block")
    sys.exit(1)
new_vote = """static int ai_p_now = -128, g_person_off = 0;

static int ai_vote_update(int p)
{
   ai_hist[ai_idx] = p;
   ai_idx = (ai_idx + 1) % AI_VOTE_N;
   if (ai_fill < AI_VOTE_N) ai_fill++;
   ai_p_now = p;
   int on = 0, off = 0;
   for (int i = 0; i < ai_fill; ++i) {
      if (ai_hist[i] >= AI_P_TH) on++;
      if (ai_hist[i] <  AI_P_OFF) off++;
   }
   rel_cnt = off;
   g_person_off = (ai_fill >= AI_VOTE_N && off == AI_VOTE_N) ? 1 : 0;
   return (on >= AI_VOTE_K) ? 1 : 0;
}

static void ai_reset(void)
{
   ai_idx = 0; ai_fill = 0; ai_p_now = -128; g_person_off = 0; rel_cnt = 0;
   for (int i = 0; i < AI_VOTE_N; ++i) ai_hist[i] = -128;
}"""
s = s[:old_vote.start()] + new_vote + s[old_vote.end():]
applied.append("ai_vote_update + ai_reset")

# ---- 3. alarm start condition ----------------------------------------------
sub(r"if \(\(cand_left > 0\) && person\) \{",
    "if (person && ((cand_left > 0) || (ai_p_now >= AI_P_STRONG))) {",
    "alarm start: strong AI can open")

# ---- 4. alarm release: AI only, motion ignored ------------------------------
old_rel = re.search(
    r"if \(\(!motion\) && \(!person\)\) rel_cnt\+\+; else rel_cnt = 0;\s*\n"
    r"\s*if \(rel_cnt >= DEC_RELEASE_FRAMES\) \{\s*\n"
    r"(\s*)bsp_printf\(\"MMT_ALARM end ms=%d f=%d dur_ms=%d\\n\\r\",\s*\n"
    r"\s*\(int\)now, \(int\)g_frame, \(int\)now - alarm_start_ms\);\s*\n"
    r"\s*alarm_on = 0; rel_cnt = 0;\s*\n\s*\}",
    s, re.S)
if not old_rel:
    print("MISS: release block")
    sys.exit(1)
new_rel = """if (infer_ran && g_person_off) {   /* 解除只看 AI，与运动无关 */
           bsp_printf("MMT_ALARM end ms=%d f=%d dur_ms=%d\\n\\r",
                      (int)now, (int)g_frame, (int)now - alarm_start_ms);
           alarm_on = 0;
        }"""
s = s[:old_rel.start()] + new_rel + s[old_rel.end():]
applied.append("alarm release: AI-only")

# ---- 5. LP entry clears AI history -----------------------------------------
sub(r"(\n(\s*)infer_paused = 1;)",
    r"\1\n\2ai_reset(); last_person = 0;   /* 进入低功耗清空 AI 历史 */",
    "LP entry: ai_reset")

# ---- 6. version strings -----------------------------------------------------
sub(r'MMT_LIVE_BOOT v18', 'MMT_LIVE_BOOT v19', "boot string v19")
sub(r'MMT_CFG v18', 'MMT_CFG v19', "cfg string v19")

# ---- 7. device ms + person on the MMT_DEC line ------------------------------
sub(r'bsp_printf\("MMT_DEC f=%d score=%d',
    'bsp_printf("MMT_DEC t=%d f=%d score=%d', "DEC: add t=")
sub(r'"rtl_alarm=%d cand=%d rel=%d\\n\\r",\s*\n(\s*)\(int\)frame, \(int\)score',
    '"rtl_alarm=%d cand=%d rel=%d person=%d\\\\n\\\\r",\n'
    r'\1(int)now_ms(), (int)frame, (int)score', "DEC: add person=")
sub(r'\(int\)area, \(int\)conf_rtl, alarm_rtl, cand_left, rel_cnt\);',
    '(int)area, (int)conf_rtl, alarm_rtl, cand_left, rel_cnt, last_person);',
    "DEC: person arg")

io.open(DST, "w", encoding="utf-8", newline="\n").write(s)
print("wrote", DST)
print("changed:", len(applied), "edits,", len(s) - len(orig), "bytes delta")
for a in applied:
    print("  -", a)
