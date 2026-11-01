"""push_audio.py — ⑦ HDMI 音频提示音（RTL + 位流记录 + 文档）推送。"""
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
        req.add_header('User-Agent', 'dsh-audio-push')
        req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')[:250]
            print(f'  HTTP {e.code} {method} {path} {body}', flush=True)
            if e.code in (409, 422, 500, 502, 503) and i + 1 < tries:
                time.sleep(1.5 * (i + 1)); continue
            raise

root = WS / 'FPGA_104'
files = []
for p in sorted((root / 'evidence' / 'audio').rglob('*')):
    if p.is_file():
        files.append((p.relative_to(root).as_posix(), p))
files.append(('docs/提交材料/拓展项对照.md', root / 'docs/提交材料/拓展项对照.md'))
head = call('GET', f'/repos/{REPO}/git/ref/heads/main')['object']['sha']
tree_sha = call('GET', f'/repos/{REPO}/git/commits/{head}')['tree']['sha']
entries = []
for rel, p in files:
    data = p.read_bytes()
    blob = call('POST', f'/repos/{REPO}/git/blobs', {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
    entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    print(f'  blob {rel} {len(data)} B', flush=True)
tree = call('POST', f'/repos/{REPO}/git/trees', {'base_tree': tree_sha, 'tree': entries})
msg = ('feat(hdmi): ⑦ 语音走 HDMI 音频（显示屏自带喇叭，不占 SPI/IO）\n\n'
       '- 顶层 audio_* 原本是悬空隐式 wire（freq=0/word=0），dvi_encoder 一直没收到音频\n'
       '- 新增 rtl/v7/audio/v7_audio_tone.v：48 kHz 整数节拍、64 点正弦表、880/1175/1319 Hz 三音提示\n'
       '- 顶层补充 audio_L/R/valid/freq(4\'d5=48k)/word_len(4\'d3=24bit)，上电自检 0.9 s + 报警循环\n'
       '- 位流 v7_MERGE18_AUDIO.bit 2,838,420 B SHA256 E96C05BF…FF58C；JTAG 烧录 PASS，固件 BC37FEAB 上传 PASS\n'
       '- 时序如实记录：setup 违例 1 条 / hold 违例 7 条（最差 -0.805 ns），回退位流与步骤写在 evidence/audio/README.md\n'
       '- 是否真出声待耳测；无声时按 README 的顺序改采样率/字长码')
new = call('POST', f'/repos/{REPO}/git/commits', {'message': msg, 'tree': tree['sha'], 'parents': [head]})
call('PATCH', f'/repos/{REPO}/git/refs/heads/main', {'sha': new['sha'], 'force': False})
print('PUSHED', new['sha'])
