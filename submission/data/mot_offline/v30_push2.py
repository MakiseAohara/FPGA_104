"""v30_push2.py - push round-2 deliverables (evidence + tools + out/mot_check)"""
import base64, json, time, urllib.request, urllib.error
from pathlib import Path
WS = Path(r"C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace")
REPO = "MakiseAohara/FPGA_104"
TOKEN = (WS / "_tmp" / "gh_token.txt").read_text(encoding="utf-8").strip()
API = "https://api.github.com"

def call(method, path, payload=None, tries=3):
    data = json.dumps(payload).encode() if payload is not None else None
    for i in range(tries):
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + TOKEN)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("User-Agent", "dsh-v30-2")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            print("  HTTP", e.code, method, path, e.read().decode(errors="replace")[:300], flush=True)
            if e.code in (409, 422, 500, 502, 503) and i + 1 < tries:
                time.sleep(2 * (i + 1)); continue
            raise

root = WS / "FPGA_104"
files = []
for p in sorted((root / "evidence" / "v30_mot").rglob("*")):
    if p.is_file():
        files.append((p.relative_to(root).as_posix(), p))
for name in ("capture_mot.py", "pred_eval.py", "align_eval.py", "mot_view.py", "load_v30.ps1"):
    p = root / "tools" / name
    if p.exists():
        files.append(("tools/" + name, p))
for p in sorted((root / "out" / "mot_check").glob("*")):
    if p.is_file():
        files.append(("out/mot_check/" + p.name, p))
print("files:", len(files), flush=True)

ref = call("GET", "/repos/%s/git/ref/heads/main" % REPO)
head = ref["object"]["sha"]
tree = call("GET", "/repos/%s/git/commits/%s" % (REPO, head))["tree"]["sha"]
print("head", head[:10], flush=True)
entries = []
for rel, p in files:
    data = p.read_bytes()
    blob = call("POST", "/repos/%s/git/blobs" % REPO, {"content": base64.b64encode(data).decode(), "encoding": "base64"})
    entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print("  blob", rel, len(data), flush=True)
new_tree = call("POST", "/repos/%s/git/trees" % REPO, {"base_tree": tree, "tree": entries})
msg = "v30 第二轮（跟踪频率/航迹门控/相机晃动/ID 保持）+ 预测量化评估"
commit = call("POST", "/repos/%s/git/commits" % REPO, {"message": msg, "tree": new_tree["sha"], "parents": [head]})
call("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {"sha": commit["sha"], "force": False})
print("PUSHED", commit["sha"])
print("branch: main")