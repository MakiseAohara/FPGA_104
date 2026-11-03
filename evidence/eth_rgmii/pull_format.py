import base64, json, urllib.request
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
REPO = "MakiseAohara/FPGA_104"; API = "https://api.github.com"
def call(m, p):
    r = urllib.request.Request(API + p, method=m)
    r.add_header("Authorization", "Bearer " + TOKEN); r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "dsh")
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.loads(resp.read().decode())
r = call("GET", "/repos/%s/contents/evidence/eth_rgmii" % REPO)
names = [x["name"] for x in r] if isinstance(r, list) else []
print("files:", names)
if "UDP_EVENT_FORMAT.md" in names:
    f = call("GET", "/repos/%s/contents/evidence/eth_rgmii/UDP_EVENT_FORMAT.md" % REPO)
    txt = base64.b64decode(f["content"]).decode("utf-8", "replace")
    (WS / "FPGA_104" / "evidence" / "eth_rgmii" / "UDP_EVENT_FORMAT.md").write_text(txt, encoding="utf-8")
    print("FORMAT DOC FOUND, len", len(txt))
    print(txt[:1500])
else:
    print("NO FORMAT DOC YET")
