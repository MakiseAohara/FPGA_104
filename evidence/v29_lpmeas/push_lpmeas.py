"""push_lpmeas.py — ⑤ 降帧复核证据 + 文档口径更正（单提交，不 force）。"""
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
        req.add_header('User-Agent', 'dsh-lpmeas-push')
        req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
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
for p in sorted((root / 'evidence' / 'v29_lpmeas').rglob('*')):
    if p.is_file():
        files.append((p.relative_to(root).as_posix(), p))
for rel in ('evidence/v29_fw/main_live292_lpmeas.cc', 'evidence/v29_fw/build_lpmeas.py',
            'evidence/v29_fw/firmware_identity_lpmeas.json',
            'docs/赛题完成度看板.md', 'docs/提交材料/拓展项对照.md'):
    p = root / rel
    if p.exists():
        files.append((rel, p))
print('files to push:', len(files))

ref = call('GET', f'/repos/{REPO}/git/ref/heads/main')
head = ref['object']['sha']
tree_sha = call('GET', f'/repos/{REPO}/git/commits/{head}')['tree']['sha']
print('head', head[:10])

entries = []
for rel, p in files:
    data = p.read_bytes()
    blob = call('POST', f'/repos/{REPO}/git/blobs',
                {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
    entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    print(f'  blob {rel} {len(data)} B', flush=True)

tree = call('POST', f'/repos/{REPO}/git/trees', {'base_tree': tree_sha, 'tree': entries})
msg = ('fix(lp): 复核 ⑤「降帧未生效」——实为测量口径错误，降帧确实生效\n\n'
       '- 根因：obs_st[31:24] 的 vs_cnt 数 in_vs（= enc_vs，HDMI 输出域），camfps 恒 59~60\n'
       '- 复核：帧缓冲 24x24 签名数真帧，三轮采样（10ms/5ms/去抖）一致降为 1/3.3~1/3.7\n'
       '- 数据：正常 ≈60 帧/s -> 低功耗 ≈17~18 帧/s，与 VTS 0x5dc->0x1194（x3）吻合\n'
       '- 诊断固件 fw_v292_lpmeas.bin 302,226 B CRC32 D2EF9830（基于 lpfix 只加测量）\n'
       '- 板上已刷回交付版 lpfix BC37FEAB；文档更正 ⑤ 状态与说明 3\n'
       '- 另：刷新 赛题完成度看板 ③④⑤⑥ 的过时状态')
new = call('POST', f'/repos/{REPO}/git/commits', {'message': msg, 'tree': tree['sha'], 'parents': [head]})
call('PATCH', f'/repos/{REPO}/git/refs/heads/main', {'sha': new['sha'], 'force': False})
print('PUSHED', new['sha'])
print('https://github.com/' + REPO + '/commit/' + new['sha'])
