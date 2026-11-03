import json, time, urllib.request, urllib.error
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
ROOT = WS / "FPGA_104"
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
REPO = "MakiseAohara/FPGA_104"; API = "https://api.github.com"

def call(m, p, payload=None, tries=4):
    data = json.dumps(payload).encode() if payload is not None else None
    last = None
    for i in range(tries):
        try:
            r = urllib.request.Request(API + p, data=data, method=m)
            r.add_header("Authorization", "Bearer " + TOKEN)
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "dsh")
            r.add_header("Content-Type", "application/json")
            with urllib.request.urlopen(r, timeout=120) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            return {"__error__": e.code, "body": e.read().decode()[:400]}
        except Exception as e:
            last = e; time.sleep(2 + i)
    raise last

body = (ROOT / "evidence/ISSUE_DISPLAY_GE_2026-11-03.md").read_text(encoding="utf-8")
title = "【显示】GE 位流 HDMI 黑屏/冻结：CDC 违例已修但画面仍不输出（附时序证据、已排除项与计划）"
iss = call("POST", "/repos/%s/issues" % REPO, {"title": title, "body": body})
print("ISSUE:", iss.get("html_url") or iss)
