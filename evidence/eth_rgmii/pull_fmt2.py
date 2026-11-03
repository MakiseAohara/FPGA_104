import base64, json, urllib.request
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
ROOT = WS / "FPGA_104"
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
REPO = "MakiseAohara/FPGA_104"; API = "https://api.github.com"
def call(m, p):
    r = urllib.request.Request(API + p, method=m)
    r.add_header("Authorization", "Bearer " + TOKEN); r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "dsh")
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.loads(resp.read().decode())
head = call("GET", "/repos/%s/git/ref/heads/main" % REPO)["object"]["sha"]
print("main head:", head[:10])
for rel in ("evidence/eth_rgmii/UDP_EVENT_FORMAT.md", "evidence/session_1103/mot_v16.patch",
            "tools/web_monitor.py"):
    try:
        f = call("GET", "/repos/%s/contents/%s" % (REPO, rel))
        data = base64.b64decode(f["content"])
        (ROOT / rel).parent.mkdir(parents=True, exist_ok=True)
        (ROOT / rel).write_bytes(data)
        print("pulled", rel, len(data))
    except Exception as e:
        print("MISS", rel, str(e)[:80])
fmt = ROOT / "evidence/eth_rgmii/UDP_EVENT_FORMAT.md"
if fmt.exists():
    print("==== FORMAT ====")
    print(fmt.read_text(encoding="utf-8")[:2000])
