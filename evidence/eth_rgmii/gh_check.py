import json, urllib.request, urllib.error
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
REPO = "MakiseAohara/FPGA_104"
API = "https://api.github.com"
def call(m, p, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(API + p, data=data, method=m)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "dsh")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode(errors="replace")[:200]}
me = call("GET", "/user")
print("user:", me.get("login"), me.get("error", ""))
repo = call("GET", "/repos/" + REPO)
print("repo:", repo.get("full_name"), "default_branch:", repo.get("default_branch"), repo.get("error", ""))
ref = call("GET", "/repos/%s/git/ref/heads/%s" % (REPO, repo.get("default_branch", "main")))
print("head:", ref.get("object", {}).get("sha", ref)[:12] if isinstance(ref.get("object"), dict) else ref)
tree = call("GET", "/repos/%s/contents/" % REPO)
if isinstance(tree, list):
    print("root entries:", ", ".join(t["name"] for t in tree))
