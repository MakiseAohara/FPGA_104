import json, urllib.request
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
REPO = "MakiseAohara/FPGA_104"
API = "https://api.github.com"
def call(m, p):
    r = urllib.request.Request(API + p, method=m)
    r.add_header("Authorization", "Bearer " + TOKEN); r.add_header("Accept", "application/vnd.github+json"); r.add_header("User-Agent", "dsh")
    import urllib.error
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": e.code}
for d in ("", "code_package", "evidence", "submission"):
    r = call("GET", "/repos/%s/contents/%s" % (REPO, d))
    if isinstance(r, list):
        print(d or "(root)", "->", len(r), "entries:", ", ".join(x["name"] for x in r[:14]))
    else:
        print(d, r)
