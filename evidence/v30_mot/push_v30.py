"""push_v30.py — 用 Git Data API 把 v30 成果一次性提交到 main（单提交，不 force）。"""
import base64, json, os, sys, time, urllib.request, urllib.error
from pathlib import Path

WS = Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace')
REPO = 'MakiseAohara/FPGA_104'
TOKEN = (WS / '_tmp' / 'gh_token.txt').read_text(encoding='utf-8').strip()
API = 'https://api.github.com'

def call(method, path, payload=None, tries=3):
    url = API + path
    data = json.dumps(payload).encode() if payload is not None else None
    for i in range(tries):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header('Authorization', 'Bearer ' + TOKEN)
        req.add_header('Accept', 'application/vnd.github+json')
        req.add_header('User-Agent', 'dsh-v30-push')
        req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')[:300]
            print(f'  HTTP {e.code} {method} {path} {body}', flush=True)
            if e.code in (409, 422, 500, 502, 503) and i + 1 < tries:
                time.sleep(1.5 * (i + 1)); continue
            raise
        except Exception as e:
            print(f'  ERR {method} {path} {e}', flush=True)
            if i + 1 < tries:
                time.sleep(1.5 * (i + 1)); continue
            raise

files = []
for p in sorted((WS / 'FPGA_104' / 'evidence' / 'v30_mot').rglob('*')):
    if p.is_file():
        files.append((p.relative_to(WS / 'FPGA_104').as_posix(), p))
for rel in ('tools/mot_view.py', 'tools/load_v30.ps1'):
    p = WS / 'FPGA_104' / rel
    if p.exists():
        files.append((rel, p))
files.append(('docs/赛题完成度看板.md', WS / 'FPGA_104' / 'docs' / '赛题完成度看板.md'))
print('files to push:', len(files))

ref = call('GET', f'/repos/{REPO}/git/ref/heads/main')
head = ref['object']['sha']
commit = call('GET', f'/repos/{REPO}/git/commits/{head}')
tree_sha = commit['tree']['sha']
print('head', head[:10], 'tree', tree_sha[:10])

entries = []
for rel, p in files:
    data = p.read_bytes()
    blob = call('POST', f'/repos/{REPO}/git/blobs',
                {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
    entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    print(f'  blob {rel} {len(data)} B {blob["sha"][:10]}', flush=True)

tree = call('POST', f'/repos/{REPO}/git/trees',
            {'base_tree': tree_sha, 'tree': entries})
msg = ('feat(v30): 多目标跟踪(IOU Tracker) + 行为预测，固件 312,826 B CRC32 52C82FCF\n\n'
       '- mot_core.h：背景差分+膨胀+连通域 → 两级关联(预测框IOU/质心距离) → 稳定ID+12点轨迹\n'
       '- 行为预测：Q4 速度EMA → 2帧前视 pred、dir、ROI eta；PREWARN 提前退出低功耗，PREDLEAD 报提前量\n'
       '- 验证：主机单测 12/12；真实数据回放 330 帧（确认航迹19、长度中位12、预测误差中位1.5px）\n'
       '- 上板：MERGE17 + v30，MMT_MOT_CFG ver=v30 on=1 pre=1；真人走动验收待补（本轮镜头前无人）\n'
       '- 不改 RTL / 不改 APB 布局；MOT_ON=0 可回到 v29.2 行为')
new = call('POST', f'/repos/{REPO}/git/commits',
           {'message': msg, 'tree': tree['sha'], 'parents': [head]})
call('PATCH', f'/repos/{REPO}/git/refs/heads/main', {'sha': new['sha'], 'force': False})
print('PUSHED', new['sha'])
print('https://github.com/' + REPO + '/commit/' + new['sha'])
