"""mot_view.py — v30 多目标跟踪实时/回放查看窗口（给视频用）

用法：
  py -3 tools\mot_view.py --live COM15
  py -3 tools\mot_view.py --replay FPGA_104\evidence\v30_mot\board_v30f\serial.log
  py -3 tools\mot_view.py --replay <log> --save-mp4 D:\out\v30.mp4

画面：96×96 灰度放大 6×（576×576），ROI=(16,16,80,80) 黄框；
每个目标画框 + ID + 最近 20 帧轨迹线 + 2 帧预测箭头；
MMT_PREWARN → 顶部红底"预警"横幅；MMT_ALARM start → 整屏红框 + "ALARM"。

依赖：只用标准库 + pyserial + tkinter。--save-mp4 有 imageio 就直出 mp4，
没有就把 PPM 序列写到 <路径>_frames\ 并打印一条 ffmpeg 命令。
"""
import argparse, re, sys, time, os, tempfile
from collections import deque, OrderedDict

try:
    import tkinter as tk
except Exception as e:
    print('需要 tkinter：', e); sys.exit(2)

W = H = 96
ZOOM = 6
ROI = (16, 16, 80, 80)

ap = argparse.ArgumentParser()
ap.add_argument('--live', metavar='PORT')
ap.add_argument('--replay', metavar='LOG')
ap.add_argument('--save-mp4', dest='mp4')
ap.add_argument('--speed', type=float, default=1.0, help='回放倍速（1.0 = 实时）')
ap.add_argument('--fps', type=int, default=2)
a = ap.parse_args()
if not a.live and not a.replay:
    ap.error('需要 --live 或 --replay')

RE_TRK = re.compile(r'MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) '
                    r'v16=(-?\d+),(-?\d+) dir=(\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+) eta=(-?\d+)')
RE_MOT = re.compile(r'MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+)')
RE_THUMB = re.compile(r'MMT_THUMB t=\d+ f=(\d+) alarm=(\d+) p=(-?\d+) ([0-9a-f]{4608})')
RE_IMG = re.compile(r'MMT_IMG (\d\d) ([0-9a-f]{192})')
RE_ALARM = re.compile(r'MMT_ALARM (start|end) ms=(\d+)')
RE_PRE = re.compile(r'MMT_PREWARN f=(\d+) id=(\d+) eta=(-?\d+) ms=(\d+)')

state = dict(frame=None, tracks=OrderedDict(), trails={}, prewarn_until=0.0,
             alarm=False, alarm_until=0.0, p=0, conf=0, nd=0)
frames_out = []

def thumb_to_frame(hexs):
    small = bytes.fromhex(hexs)
    buf = bytearray(W * H)
    for y in range(H):
        sy = (y // 2) * 48
        for x in range(W):
            buf[y * W + x] = small[sy + (x // 2)]
    return bytes(buf)

def img_rows(y, hexs, cache):
    cache[y] = bytes.fromhex(hexs)
    if len(cache) == H:
        return b''.join(cache[i] for i in range(H))
    return None

def handle_line(line, img_cache):
    m = RE_THUMB.search(line)
    if m:
        state['frame'] = thumb_to_frame(m.group(4))
        state['p'] = int(m.group(3))
        state['alarm'] = bool(int(m.group(2)))
        return
    m = RE_IMG.search(line)
    if m:
        f = img_rows(int(m.group(1)), m.group(2), img_cache)
        if f: state['frame'] = f
        return
    m = RE_TRK.search(line)
    if m:
        g = m.groups()
        tid = int(g[1])
        tr = dict(f=int(g[0]), cx=int(g[2]), cy=int(g[3]),
                  box=(int(g[4]), int(g[5]), int(g[6]), int(g[7])),
                  v=(int(g[8]) / 16.0, int(g[9]) / 16.0), dir=int(g[10]),
                  conf=int(g[13]), pred=(int(g[14]), int(g[15])), eta=int(g[16]))
        if tr['conf']:
            state['tracks'][tid] = tr
            state['trails'].setdefault(tid, deque(maxlen=20)).append((tr['cx'], tr['cy']))
        return
    m = RE_MOT.search(line)
    if m:
        state['nd'] = int(m.group(2)); state['conf'] = int(m.group(4))
        live = set()
        f = int(m.group(1))
        for tid, tr in list(state['tracks'].items()):
            if tr['f'] >= f - 2: live.add(tid)
        for tid in list(state['tracks']):
            if tid not in live:
                state['tracks'].pop(tid, None); state['trails'].pop(tid, None)
        return
    m = RE_PRE.search(line)
    if m:
        state['prewarn_until'] = time.monotonic() + 3.0
        return
    m = RE_ALARM.search(line)
    if m:
        state['alarm'] = (m.group(1) == 'start')
        state['alarm_until'] = time.monotonic() + (0.0 if m.group(1) == 'end' else 5.0)

root = tk.Tk()
root.title('v30 MOT viewer — 96x96 x6  (ROI 16..80)')
root.configure(bg='#101010')
canvas = tk.Canvas(root, width=W * ZOOM, height=H * ZOOM, bg='black', highlightthickness=0)
canvas.pack(side='left')
side = tk.Frame(root, bg='#101010')
side.pack(side='right', fill='y')
status = tk.Label(side, text='等待数据…', bg='#101010', fg='#9fe', justify='left', font=('Consolas', 11))
status.pack(anchor='nw', padx=10, pady=10)
help_txt = tk.Label(side, text='黄框=ROI\n红框=目标\n线=20帧轨迹\n箭头=2帧预测\nPREWARN→顶部横幅\nALARM→整屏红框',
                    bg='#101010', fg='#777', justify='left', font=('Consolas', 10))
help_txt.pack(anchor='nw', padx=10, pady=4)

photo = None
img_item = canvas.create_image(0, 0, anchor='nw')
banner = canvas.create_rectangle(0, 0, W * ZOOM, 34, fill='#a00', outline='')
banner_txt = canvas.create_text(W * ZOOM // 2, 17, text='预警 PREWARN', fill='white', font=('Microsoft YaHei', 16, 'bold'))
canvas.itemconfigure(banner, state='hidden'); canvas.itemconfigure(banner_txt, state='hidden')
alarm_box = canvas.create_rectangle(3, 3, W * ZOOM - 3, H * ZOOM - 3, outline='#ff2222', width=6, state='hidden')
alarm_txt = canvas.create_text(W * ZOOM - 70, 22, text='ALARM', fill='#ff3333', font=('Consolas', 18, 'bold'), state='hidden')

def render():
    global photo
    if state['frame']:
        buf = state['frame']
        ppm = b'P6\n%d %d\n255\n' % (W, H) + b''.join(bytes((v, v, v)) for v in buf)
        fd, path = tempfile.mkstemp(suffix='.ppm'); os.write(fd, ppm); os.close(fd)
        photo = tk.PhotoImage(file=path, format='ppm'); os.unlink(path)
        photo = photo.zoom(ZOOM)
        canvas.itemconfigure(img_item, image=photo)
    canvas.delete('ov')
    x0, y0, x1, y1 = ROI
    canvas.create_rectangle(x0 * ZOOM, y0 * ZOOM, x1 * ZOOM, y1 * ZOOM, outline='#e0c000', dash=(4, 4), tags='ov')
    for tid, tr in state['tracks'].items():
        bx = tr['box']
        canvas.create_rectangle(bx[0] * ZOOM, bx[1] * ZOOM, bx[2] * ZOOM, bx[3] * ZOOM, outline='#ff4040', width=2, tags='ov')
        canvas.create_text(bx[0] * ZOOM + 3, max(8, bx[1] * ZOOM - 9), text='ID%d' % tid, fill='#ff8080',
                           anchor='w', font=('Consolas', 10, 'bold'), tags='ov')
        pts = list(state['trails'].get(tid, []))
        if len(pts) > 1:
            flat = []
            for (cx, cy) in pts:
                flat += [cx * ZOOM, cy * ZOOM]
            canvas.create_line(*flat, fill='#40c0ff', width=2, tags='ov')
        px, py = tr['pred']
        canvas.create_line(tr['cx'] * ZOOM, tr['cy'] * ZOOM, px * ZOOM, py * ZOOM, fill='#00ff80', width=2, arrow='last', tags='ov')
    now = time.monotonic()
    pre = now < state['prewarn_until']
    canvas.itemconfigure(banner, state='normal' if pre else 'hidden')
    canvas.itemconfigure(banner_txt, state='normal' if pre else 'hidden')
    alm = state['alarm'] or now < state['alarm_until']
    canvas.itemconfigure(alarm_box, state='normal' if alm else 'hidden')
    canvas.itemconfigure(alarm_txt, state='normal' if alm else 'hidden')
    status.configure(text='帧 %s  检测 %d  确认 %d\nAI p=%s\n目标 %s' % (
        state.get('f', '-'), state['nd'], state['conf'], state['p'],
        ', '.join('ID%d' % t for t in state['tracks']) or '—'))
    if a.mp4:
        frames_out.append(bytes(state['frame']) if state['frame'] else bytes(W * H))

def pump_replay():
    if not queue:
        root.after(200, root.destroy); return
    t_next = queue[0][0]
    now = time.monotonic() - t0
    while queue and (now * a.speed) >= queue[0][0]:
        handle_line(queue.pop(0)[1], img_cache)
    render()
    root.after(max(20, int(1000.0 / a.fps / a.speed)), pump_replay)

def pump_live():
    import serial
    global ser
    while ser.in_waiting:
        raw = ser.readline()
        if not raw: break
        handle_line(raw.decode('ascii', errors='replace'), img_cache)
    render()
    root.after(int(1000 / a.fps), pump_live)

if a.replay:
    queue = []
    t = 0.0
    cur_t = None
    for line in open(a.replay, encoding='utf-8', errors='replace'):
        m = re.search(r'MMT_(THUMB|IMG)\b', line)
        if not m:
            handle_line(line, {})   # 非图像行先不回放（Tracks 也按行序处理）
            continue
        queue.append((t, line))
        cur_t = (cur_t or 0.0) + 1.0 / a.fps
        t = cur_t
    # 重新组织：图像行按 2fps 排时间轴，非图像行直接并入前一行
    t0 = time.monotonic(); img_cache = {}
    root.after(100, pump_replay)
else:
    import serial
    ser = serial.Serial(a.live, 115200, timeout=0.05)
    img_cache = {}
    root.after(100, pump_live)

root.mainloop()
if a.mp4 and frames_out:
    try:
        import imageio
        w = imageio.get_writer(a.mp4, fps=a.fps)
        for f in frames_out:
            w.append_data([[ (v, v, v) for v in f[y*W:(y+1)*W]] for y in range(H)])
        w.close()
        print('已写', a.mp4, len(frames_out), '帧')
    except Exception as e:
        d = a.mp4 + '_frames'; os.makedirs(d, exist_ok=True)
        for i, f in enumerate(frames_out):
            ppm = b'P6\n%d %d\n255\n' % (W, H) + b''.join(bytes((v, v, v)) for v in f)
            open(os.path.join(d, 'f%05d.ppm' % i), 'wb').write(ppm)
        print('没有 imageio，已把', len(frames_out), '帧 PPM 写到', d)
        print('转 mp4：ffmpeg -framerate %d -i %s\\f%%05d.ppm -pix_fmt yuv420p %s' % (a.fps, d, a.mp4))
