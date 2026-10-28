#!/usr/bin/env python3
"""test_console.py — v29.1 上板测试上位机（唯一打开串口的程序）。

- 默认 COM15 @ 115200；断线自动重连。
- 每行记录 PC 时间（毫秒）；用 MMT_DEC 的 t= 持续拟合 PC↔device_ms 线性映射，两种时间都写进 CSV。
- 全屏大字：等待开始 / 正在测试（阶段、提示、倒计时）/ 已结束；开始、换阶段、结束都有提示音。
- 按脚本 JSON 自动推进阶段。
- 操作者打点：空格=有人进入，回车=离开，M=备注（弹框），S=开始，Esc=退出。
- 实时面板：AI 分数、person、alarm 及 cause、irhot/ir_cnt、motion、低功耗、帧率。
- 输出 timeline.csv / raw_serial.log / meta.json。
- 可选 --load：按 S 后先（可烧位流）再串口上传固件，然后进入脚本阶段。

用法：
  python test_console.py --script scripts/wb.json --out evidence/v29_1/a_wb \
      --load evidence/v29_fw/tinyml_pdti8_v291_daycal.bin --bit evidence/v29_rtl_display/v7_MERGE16.bit
"""
import argparse, binascii, csv, json, os, queue, re, struct, subprocess, sys, threading, time
from collections import deque
from datetime import datetime, timezone, timedelta
from pathlib import Path

EFINITY = Path(r'D:\Efinity\2026.1')
if str(EFINITY / 'python311/Lib/site-packages') not in sys.path:
    sys.path.append(str(EFINITY / 'python311/Lib/site-packages'))
import serial  # pyserial 3.5 (Efinity python311 site-packages)

try:
    import tkinter as tk
    from tkinter import simpledialog
except Exception:
    tk = None
try:
    import winsound
except Exception:
    winsound = None

TZ = timezone(timedelta(hours=8))
FLASH_PS1 = Path(r'C:\Users\Makise Aohara\Documents\Codex\2026-10-15\https-github-com-makiseaohara-fpga-104\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1')
BIT_SHA = '81332CD17DA35CDB7103C666434AE0DF1702A65EBEAEAAEB80AE70C8801F8882'

RE_DEC = re.compile(r'MMT_DEC t=(\d+) f=(\d+) score=(-?\d+).*?alarm_req=(\d+).*?motion=(\d+) irhot=(\d+) area=(\d+).*?rel=(\d+) person=(\d+) ir_cnt=(\d+)')
RE_ALARM = re.compile(r'MMT_ALARM (start|end) ms=(\d+) f=(\d+)(?: dur_ms=(\d+))?(?:.*?person=(\d+).*?motion=(\d+).*?area=(\d+))?(?:.*?cause=(\w+))?(?:.*?reason=(\w+))?')
RE_LP = re.compile(r'MMT_LP f=(\d+) lowpwr=(\d+) fw_lp=(\d+) paused=(\d+) camfps=(\d+)')
RE_AI = re.compile(r'MMT_AI f=(\d+) p=(-?\d+).*?person=(\d+)')
RE_WB = re.compile(r'MMT_WB r=(\d+) g=(\d+) b=(\d+) Rmean=(\d+) Gmean=(\d+) Bmean=(\d+) used=(\d+) skipped=(\d+)')
RE_PRESET = re.compile(r'MMT_CAM_PRESET name=(\w+).*?mean_sensor=(\d+)')

CSV_COLS = ['pc_ms', 'iso', 'device_ms', 'source', 'kind', 'phase', 'alarm', 'cause',
            'person', 'p', 'motion', 'irhot', 'ir_cnt', 'area', 'lowpwr', 'camfps', 'note']


def now_ms():
    return int(time.time() * 1000)


def iso(ms=None):
    return datetime.fromtimestamp((ms if ms is not None else now_ms()) / 1000, TZ).isoformat(timespec='milliseconds')


class Clock:
    """PC 毫秒 ↔ 板端 device_ms 的线性拟合。"""

    def __init__(self):
        self.samples = deque(maxlen=120)
        self.a, self.b = 1.0, 0.0

    def add(self, pc_ms, dev_ms):
        self.samples.append((pc_ms, dev_ms))
        if len(self.samples) < 3:
            self.a, self.b = 1.0, self.samples[0][1] - self.samples[0][0]
            return
        n = len(self.samples)
        sx = sum(s[0] for s in self.samples)
        sy = sum(s[1] for s in self.samples)
        sxx = sum(s[0] * s[0] for s in self.samples)
        sxy = sum(s[0] * s[1] for s in self.samples)
        den = n * sxx - sx * sx
        if den:
            self.a = (n * sxy - sx * sy) / den
            self.b = (sy - self.a * sx) / n

    def device(self, pc_ms):
        if not self.samples:
            return ''
        return int(round(self.a * pc_ms + self.b))


class Recorder:
    def __init__(self, out: Path, script_name):
        out.mkdir(parents=True, exist_ok=True)
        self.out = out
        self.lock = threading.Lock()
        self.tl = (out / 'timeline.csv').open('w', encoding='utf-8', newline='')
        self.w = csv.writer(self.tl)
        self.w.writerow(CSV_COLS)
        self.raw = (out / 'raw_serial.log').open('w', encoding='utf-8', newline='\n')
        self.clock = Clock()
        self.counts = {}
        self.closed = False
        self.t0 = now_ms()
        self.script_name = script_name

    def row(self, source, kind, phase='', note='', **kw):
        with self.lock:
            if self.closed:
                return
            r = dict.fromkeys(CSV_COLS, '')
            r['pc_ms'] = now_ms()
            r['iso'] = iso(r['pc_ms'])
            r['source'] = source
            r['kind'] = kind
            r['phase'] = phase
            r['note'] = note
            r.update({k: v for k, v in kw.items() if k in CSV_COLS})
            if not r['device_ms']:
                r['device_ms'] = self.clock.device(r['pc_ms'])
            self.w.writerow([r[c] for c in CSV_COLS])
            self.tl.flush()
            self.counts[kind] = self.counts.get(kind, 0) + 1

    def raw_line(self, pc_ms, text):
        with self.lock:
            if self.closed:
                return
            self.raw.write('%d\t%s\n' % (pc_ms, text))
            self.raw.flush()

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            self.tl.close()
            self.raw.close()
            meta = dict(script=self.script_name, started=iso(self.t0), ended=iso(),
                        counts=self.counts, clock=dict(a=self.clock.a, b=self.clock.b,
                                                       n=len(self.clock.samples)))
            (self.out / 'meta.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')


class Link:
    """串口：读线程 + 断线重连 + 写（上传固件时暂停读）。"""

    def __init__(self, port, baud, on_line, on_state):
        self.port, self.baud = port, baud
        self.on_line, self.on_state = on_line, on_state
        self.ser = None
        self.lock = threading.Lock()
        self.running = True
        self.paused = False
        self.reconnects = 0
        self.buf = b''
        self.rawbuf = b''
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self.thread.start()

    def _open(self):
        s = serial.Serial(port=None, baudrate=self.baud, timeout=0.05, write_timeout=5)
        s.dtr = False
        s.rts = False
        s.port = self.port
        s.open()
        return s

    def _loop(self):
        while self.running:
            if self.ser is None:
                try:
                    self.ser = self._open()
                    self.on_state('connected', self.reconnects)
                except Exception as exc:
                    self.on_state('disconnected', str(exc))
                    time.sleep(1.0)
                    continue
            if self.paused:
                time.sleep(0.05)
                continue
            try:
                chunk = self.ser.read(512)
            except Exception as exc:
                self.on_state('disconnected', str(exc))
                try:
                    self.ser.close()
                except Exception:
                    pass
                self.ser = None
                self.reconnects += 1
                time.sleep(1.0)
                continue
            if chunk:
                self.buf += chunk
                while b'\n' in self.buf:
                    line, self.buf = self.buf.split(b'\n', 1)
                    self.on_line(line.decode('utf-8', 'replace').rstrip('\r'))

    def write(self, data):
        with self.lock:
            if self.ser is None:
                raise IOError('serial not open')
            self.ser.write(data)

    def wait_line(self, token, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                if token in self._pending:
                    self._pending = self._pending.replace(token, '', 1)
                    return True
            time.sleep(0.02)
        return False

    def raw_until(self, token, timeout):
        """上传期间直接读串口（不经读线程），token 为 bytes。"""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                c = self.ser.read(256)
            except Exception:
                return False
            if c:
                self.rawbuf += c
                if len(self.rawbuf) > 4096:
                    self.rawbuf = self.rawbuf[-4096:]
                if token in self.rawbuf:
                    return True
        return False

    def close(self):
        self.running = False
        try:
            if self.ser:
                self.ser.close()
        except Exception:
            pass


class App:
    def __init__(self, args):
        self.args = args
        self.script = json.loads(Path(args.script).read_text(encoding='utf-8'))
        self.rec = Recorder(Path(args.out), self.script.get('name', Path(args.script).stem))
        self.phases = self.script.get('phases', [])
        self.state = 'idle'
        self.phase = -1
        self.phase_start = 0.0
        self.phase_deadline = 0.0
        self.live = {}
        self.status = '等待开始'
        self.last_mark = ''
        self.gate_msg = ''
        self.link = Link(args.port, 115200, self.on_line, self.on_state)
        self.link._pending = ''
        self.beep = (lambda f, d: winsound.Beep(f, d)) if winsound else (lambda f, d: None)
        self.ui = None
        if tk is not None and not args.no_gui:
            self.ui = UI(self)

    # ---------- 串口回调（读线程） ----------
    def on_line(self, text):
        pc = now_ms()
        self.rec.raw_line(pc, text)
        self.link._pending += text + '\n'
        m = RE_DEC.search(text)
        if m:
            t, f, score, alarm, motion, irhot, area, rel, person, ircnt = m.groups()
            self.rec.clock.add(pc, int(t))
            self.live.update(dec_t=int(t), f=int(f), score=int(score), alarm=int(alarm),
                             motion=int(motion), irhot=int(irhot), area=int(area),
                             person=int(person), ir_cnt=int(ircnt))
            self.rec.row('serial', 'dec', self.phase_name(), alarm=alarm, person=person,
                         motion=motion, irhot=irhot, ir_cnt=ircnt, area=area, device_ms=int(t))
            return
        m = RE_ALARM.search(text)
        if m:
            kind, ms, f, dur, person, motion, area, cause, reason = m.groups()
            self.live.update(alarm_state=kind, cause=cause or '', alarm_ms=int(ms))
            self.rec.row('serial', 'alarm', self.phase_name(), note=text,
                         alarm=kind, cause=cause or '', person=person or '', motion=motion or '',
                         area=area or '', device_ms=int(ms))
            return
        m = RE_LP.search(text)
        if m:
            f, lowpwr, fw_lp, paused, fps = m.groups()
            self.live.update(lowpwr=int(lowpwr), paused=int(paused), camfps=int(fps))
            self.rec.row('serial', 'lp', self.phase_name(), lowpwr=lowpwr, camfps=fps)
            return
        m = RE_AI.search(text)
        if m:
            f, p, person = m.groups()
            self.live.update(p=int(p), person=int(person))
            self.rec.row('serial', 'ai', self.phase_name(), p=p, person=person)
            return
        m = RE_WB.search(text)
        if m:
            self.live.update(wb=m.groups()[:3])
            self.rec.row('serial', 'wb', self.phase_name(), note=text)
            return
        m = RE_PRESET.search(text)
        if m:
            self.live.update(preset=m.group(1), mean_sensor=int(m.group(2)))
            self.rec.row('serial', 'preset', self.phase_name(), note=text)
            return
        if text.startswith('MMT_LIVE_BOOT'):
            self.rec.row('serial', 'boot', self.phase_name(), note=text)

    def on_state(self, what, detail=''):
        if what == 'disconnected':
            self.rec.row('system', 'reconnect', self.phase_name(), note=str(detail)[:120])
        elif what == 'connected' and self.link.reconnects:
            self.rec.row('system', 'reconnected', self.phase_name(), note='count=%d' % self.link.reconnects)

    def phase_name(self):
        return self.phases[self.phase]['name'] if 0 <= self.phase < len(self.phases) else ''

    # ---------- 状态机 ----------
    def start(self):
        if self.state != 'idle':
            return
        self.state = 'loading' if self.args.load else 'running'
        self.status = '加载固件' if self.args.load else '正在测试'
        self.beep(880, 150)
        self.rec.row('script', 'start', '', note=self.script.get('name', ''))
        if self.args.load:
            threading.Thread(target=self._load_then_run, daemon=True).start()
        else:
            self._begin_phases()

    def _load_then_run(self):
        try:
            self._flash_and_upload()
        except Exception as exc:
            self.rec.row('system', 'load_error', '', note=str(exc)[:200])
            self.status = '固件加载失败'
            self.beep(220, 500)
            return
        # 白平衡亮度门：等 MMT_CAM_PRESET 的 mean_sensor，<80 判为灯不够亮
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and 'mean_sensor' not in self.live:
            time.sleep(0.1)
        mean = self.live.get('mean_sensor')
        if mean is not None and mean < 80:
            self.rec.row('system', 'wb_gate_fail', '', note='mean_sensor=%s < 80' % mean)
            self.state = 'idle'
            self.status = '亮度不足'
            self.gate_msg = ('mean_sensor=%s < 80：灯不够亮，这次标定无效。\n'
                             '开灯、把白纸铺满中心后，重新按 S。' % mean)
            self.beep(220, 600)
            return
        self.state = 'running'
        self.status = '正在测试'
        self._begin_phases()

    def _flash_and_upload(self):
        args = self.args
        bit = Path(args.bit) if args.bit else None
        self.link.paused = True
        time.sleep(0.3)
        if bit:
            log = Path(args.out) / 'flash_stdout.log'
            env = os.environ.copy()
            env['PSModulePath'] = (r'C:\Windows\System32\WindowsPowerShell\v1.0\Modules;'
                                   r'C:\Program Files\WindowsPowerShell\Modules')
            cmd = [r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile',
                   '-ExecutionPolicy', 'Bypass', '-File', str(FLASH_PS1), '-Bit', str(bit),
                   '-Sha256', BIT_SHA, '-EfinityHome', str(EFINITY),
                   '-ExpectedDriverVersion', '2.12.36.20', '-UsbUrl', 'hiftdi://0x0403:0x6011/1',
                   '-LogRoot', str(Path(args.out) / 'flash_logs')]
            with log.open('wb') as fh:
                rc = subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env)
            if rc != 0:
                raise RuntimeError('flash exit %d' % rc)
        if not self.link.raw_until(b'MMT_LOADER_READY', 90):
            raise RuntimeError('loader not ready')
        data = Path(args.load).read_bytes()
        crc = binascii.crc32(data) & 0xffffffff
        header = b'MMTL' + struct.pack('<II', len(data), crc)
        accepted = False
        for _ in range(20):
            self.link.write(header)
            if self.link.raw_until(b'MMT_LOAD_ACCEPT', 0.4):
                accepted = True
                break
        if not accepted:
            raise RuntimeError('no MMT_LOAD_ACCEPT')
        for off in range(0, len(data), 64):
            block = data[off:off + 64]
            ok = False
            for _ in range(4):
                self.link.write(block)
                if self.link.raw_until(b'\x06', 6):
                    ok = True
                    break
            if not ok:
                raise RuntimeError('block %d not acked' % (off // 64))
        if not self.link.raw_until(b'MMT_LOAD_PASS', 60):
            raise RuntimeError('no MMT_LOAD_PASS')
        self.link.raw_until(b'MMT_LIVE_BOOT', 30)
        self.link.buf = b''
        self.link.paused = False

    def _begin_phases(self):
        self.phase = 0
        self.phase_start = time.monotonic()
        self.phase_deadline = self.phase_start + self.phases[0]['seconds']
        self.beep(1046, 200)
        self.rec.row('script', 'phase_start', self.phase_name(), note=self.phases[0].get('hint', ''))

    def tick(self):
        if self.state != 'running':
            return
        now = time.monotonic()
        if now >= self.phase_deadline:
            self.rec.row('script', 'phase_end', self.phase_name(), note='')
            self.phase += 1
            if self.phase >= len(self.phases):
                self.state = 'done'
                self.status = '已结束'
                self.beep(660, 500)
                self.rec.row('script', 'end', '', note='')
                self.rec.close()
                self.link.close()
                return
            self.phase_start = now
            self.phase_deadline = now + self.phases[self.phase]['seconds']
            self.beep(1046, 200)
            self.rec.row('script', 'phase_start', self.phase_name(), note=self.phases[self.phase].get('hint', ''))

    def mark(self, kind, note=''):
        if self.state != 'running':
            return
        self.last_mark = '%s %s' % (kind, note)
        self.rec.row('operator', 'mark', self.phase_name(), note=('%s %s' % (kind, note)).strip())
        self.beep(1568, 80)

    def note(self):
        if self.ui is None:
            return
        text = simpledialog.askstring('备注', '输入备注：', parent=self.ui.root)
        if text:
            self.mark('NOTE', text)

    def run(self):
        self.link.start()
        if self.ui is None:
            self._headless()
        else:
            self.ui.run()

    def _headless(self):
        print('headless: 按 Ctrl+C 结束')
        try:
            while self.state != 'done':
                self.tick()
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass


class UI:
    def __init__(self, app):
        self.app = app
        self.root = tk.Tk()
        self.root.attributes('-fullscreen', True)
        self.root.configure(bg='black')
        self.root.bind('<space>', lambda e: app.mark('PERSON_IN'))
        self.root.bind('<Return>', lambda e: app.mark('PERSON_OUT'))
        self.root.bind('<m>', lambda e: app.note())
        self.root.bind('<M>', lambda e: app.note())
        self.root.bind('<s>', lambda e: app.start())
        self.root.bind('<S>', lambda e: app.start())
        self.root.bind('<Escape>', lambda e: self.root.destroy())

        left = tk.Frame(self.root, bg='black')
        left.pack(side='left', fill='both', expand=True)
        right = tk.Frame(self.root, bg='black', width=560)
        right.pack(side='right', fill='y')

        self.lbl_state = tk.Label(left, text='等待开始', fg='#ffd166', bg='black', font=('Microsoft YaHei', 54, 'bold'))
        self.lbl_state.pack(pady=(40, 10))
        self.lbl_phase = tk.Label(left, text='', fg='white', bg='black', font=('Microsoft YaHei', 40))
        self.lbl_phase.pack(pady=6)
        self.lbl_hint = tk.Label(left, text='', fg='#9ad1ff', bg='black', font=('Microsoft YaHei', 26),
                                 wraplength=1100, justify='center')
        self.lbl_hint.pack(pady=10)
        self.lbl_count = tk.Label(left, text='', fg='#7CFC00', bg='black', font=('Consolas', 72, 'bold'))
        self.lbl_count.pack(pady=10)
        self.lbl_mark = tk.Label(left, text='', fg='#ff6b6b', bg='black', font=('Microsoft YaHei', 22))
        self.lbl_mark.pack(pady=6)
        self.lbl_keys = tk.Label(left, text='空格=有人进入   回车=离开   M=备注   S=开始   Esc=退出',
                                 fg='#888888', bg='black', font=('Microsoft YaHei', 16))
        self.lbl_keys.pack(side='bottom', pady=18)

        self.panel = tk.Label(right, text='', fg='#c8facc', bg='black', justify='left',
                              font=('Consolas', 15), anchor='nw')
        self.panel.pack(fill='both', expand=True, padx=16, pady=24)

    def run(self):
        self.root.after(80, self._tick)
        self.root.mainloop()

    def _tick(self):
        app = self.app
        app.tick()
        if app.state == 'idle':
            pre = app.script.get('pre', '按 S 开始')
            if app.gate_msg:
                pre = app.gate_msg + '\n\n' + pre
            self.lbl_state.config(text='等待开始')
            self.lbl_phase.config(text='')
            self.lbl_hint.config(text=pre)
            self.lbl_count.config(text='')
        elif app.state == 'loading':
            self.lbl_state.config(text='加载固件…')
            self.lbl_phase.config(text='')
            self.lbl_hint.config(text='烧位流 + 串口上传，约 2 分钟，请不要动板子')
            self.lbl_count.config(text='')
        elif app.state == 'running':
            ph = app.phases[app.phase]
            remain = max(0, int(round(app.phase_deadline - time.monotonic())))
            self.lbl_state.config(text='正在测试')
            self.lbl_phase.config(text='%d/%d  %s' % (app.phase + 1, len(app.phases), ph['name']))
            self.lbl_hint.config(text=ph.get('hint', ''))
            self.lbl_count.config(text='%d:%02d' % (remain // 60, remain % 60))
        else:
            self.lbl_state.config(text='已结束')
            self.lbl_phase.config(text='')
            self.lbl_hint.config(text='可以关闭窗口（Esc）')
            self.lbl_count.config(text='')
        self.lbl_mark.config(text=app.last_mark)
        self.panel.config(text=self._panel_text())
        self.root.after(80, self._tick)

    def _panel_text(self):
        L = self.app.live
        return ('AI 分数   p=%s  person=%s\n'
                '报警      %s  cause=%s\n'
                '红外      irhot=%s  ir_cnt=%s\n'
                '运动      motion=%s  area=%s\n'
                '低功耗    lowpwr=%s  paused=%s\n'
                '帧率      camfps=%s\n'
                '相机      %s  mean_sensor=%s\n'
                '白平衡    %s\n'
                '板端 t    %s ms  f=%s\n'
                'PC 时钟   %s\n'
                '串口      %s') % (
            L.get('p', '-'), L.get('person', '-'),
            L.get('alarm_state', L.get('alarm', '-')), L.get('cause', '-'),
            L.get('irhot', '-'), L.get('ir_cnt', '-'),
            L.get('motion', '-'), L.get('area', '-'),
            L.get('lowpwr', '-'), L.get('paused', '-'),
            L.get('camfps', '-'),
            L.get('preset', '-'), L.get('mean_sensor', '-'),
            L.get('wb', '-'),
            L.get('dec_t', '-'), L.get('f', '-'),
            iso(), self.app.link.port)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--script', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--port', default='COM15')
    ap.add_argument('--load')
    ap.add_argument('--bit')
    ap.add_argument('--no-gui', action='store_true')
    args = ap.parse_args()
    App(args).run()


if __name__ == '__main__':
    main()
