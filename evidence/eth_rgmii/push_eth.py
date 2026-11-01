"""push_eth.py — 把 ① 的 RGMII 可行性调查与文档更正推到 main（单提交，不 force）。"""
import base64, json, time, urllib.request, urllib.error
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
        req.add_header('User-Agent', 'dsh-eth-push')
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

root = WS / 'FPGA_104'
files = []
for p in sorted((root / 'evidence' / 'eth_rgmii').rglob('*')):
    if p.is_file():
        files.append((p.relative_to(root).as_posix(), p))
for rel in ('docs/赛题完成度看板.md', 'docs/提交材料/拓展项对照.md'):
    p = root / rel
    if p.exists():
        files.append((rel, p))
print('files to push:', len(files))

ref = call('GET', f'/repos/{REPO}/git/ref/heads/main')
head = ref['object']['sha']
commit = call('GET', f'/repos/{REPO}/git/commits/{head}')
tree_sha = commit['tree']['sha']
print('head', head[:10])

entries = []
for rel, p in files:
    data = p.read_bytes()
    blob = call('POST', f'/repos/{REPO}/git/blobs',
                {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
    entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    print(f'  blob {rel} {len(data)} B', flush=True)

tree = call('POST', f'/repos/{REPO}/git/trees', {'base_tree': tree_sha, 'tree': entries})
msg = ('docs(ext1): 澄清 RGMII 在本板不可行（无 PHY），补可行性调查报告\n\n'
       '- 本板 Ti60F225I3-V4 无以太网 PHY/RJ45；YT8531 是 HDMI 座型号 HDMI_TXYT8531SH 的一部分\n'
       '- J7 仅 6 个 3.3V IO，RGMII 需 15 个信号；厂商 GE demo 的 15 条以太网脚全为 GPIOL_*\n'
       '- 工程侧已把 GE MAC/UDP RTL 并入 v7 工程并通过 efx_map（0 错误），但无 PHY 无法上板\n'
       '- 更正 赛题完成度看板 / 拓展项对照 中误写的「板载 PHY=YT8531SC」\n'
       '- 新增 evidence/eth_rgmii/{README.md,vendor_demo_pins.tsv}')
new = call('POST', f'/repos/{REPO}/git/commits', {'message': msg, 'tree': tree['sha'], 'parents': [head]})
call('PATCH', f'/repos/{REPO}/git/refs/heads/main', {'sha': new['sha'], 'force': False})
print('PUSHED', new['sha'])
print('https://github.com/' + REPO + '/commit/' + new['sha'])
