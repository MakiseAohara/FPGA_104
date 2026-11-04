"""Audit old image provenance and replay the exact C trackers, offline only.

No person boxes/identities are annotated in these recordings. Output counts and
same-track future-observation errors are regression proxies, not MOT accuracy.
The old ai.txt/ir.txt contain constants injected by export scripts and are never
used here. Real device timestamps and AI outputs are recovered from originals.
"""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import zipfile

HERE = Path(__file__).absolute().parent
PROJECT = HERE.parents[1]
FRAME_BYTES = 96 * 96


def digest(data):
    return hashlib.sha256(data).hexdigest()


def audit_sources(old_repo, capture_root, raw_root):
    # Pillow is needed only for pixel-by-pixel source verification, never for
    # altering recorded content or guessing labels.
    from PIL import Image
    datasets = []
    raw_path = raw_root / 'real/frames.bin'
    raw = raw_path.read_bytes()
    archive = old_repo / 'evidence/v29_scene/frames_v29_scene.zip'
    stamps, scores, segments = [], [], []
    with zipfile.ZipFile(archive) as source:
        names = sorted(n for n in source.namelist() if n.lower().endswith('.png'))
        assert len(names) * FRAME_BYTES == len(raw)
        for i, name in enumerate(names):
            match = re.fullmatch(r'([A-F])_t(\d+)_p(-?\d+)\.png', Path(name).name)
            assert match, name
            image = Image.open(io.BytesIO(source.read(name))).convert('L')
            assert image.size == (96, 96)
            assert image.tobytes() == raw[i*FRAME_BYTES:(i+1)*FRAME_BYTES], (i, name, 'pixel mismatch')
            segments.append(match[1])
            stamps.append(int(match[2]))
            scores.append(int(match[3]))
    datasets.append(dict(
        id='recorded_scene', name='历史实拍：六段场景（稀疏）', raw_path=str(raw_path),
        frames=len(stamps), width=96, height=96, timestamps_ms=stamps, ai_scores=scores,
        ir_counts=[None]*len(stamps), segments=segments, source='offline_recording',
        raw_sha256=digest(raw),
        provenance=dict(images_zip=str(archive), metadata='每张 PNG 文件名中的设备 t、AI 输出 p；逐像素与 frames.bin 验证一致'),
        notes='真实 96×96 设备记录，约 3.26 秒转储一帧，含阶段间断。AI 分数是模型输出，-128 可能为暂停推理哨兵，均非人工真值。无逐帧人工框/身份标签，红外未随像素保存；旧 ai.txt/ir.txt 的 90/3 是脚本固定输入，已弃用。不能用于 400ms 预测精度结论。'))
    spec = [
        ('recorded_walk', '历史实拍：单人走动（缩略图）', 'board_walk', capture_root/'v30t2/serial.log'),
        ('recorded_two_person', '历史实拍：双人片段（缩略图）', 'two_person_prev', capture_root/'v30t6/serial.log'),
    ]
    pattern = re.compile(r'MMT_THUMB t=(\d+) f=(\d+) alarm=(\d+) p=(-?\d+) ([0-9a-fA-F]{4608})')
    for ident, name, folder, log in spec:
        raw_path = raw_root / folder / 'frames.bin'
        raw = raw_path.read_bytes()
        stamps, scores, original_ids = [], [], []
        for line in log.read_text(encoding='utf8', errors='replace').splitlines():
            match = pattern.fullmatch(line.strip())
            if not match:
                continue
            pixels = Image.frombytes('L', (48,48), bytes.fromhex(match[5]))
            pixels = pixels.resize((96,96), Image.Resampling.NEAREST).tobytes()
            i = len(stamps)
            assert pixels == raw[i*FRAME_BYTES:(i+1)*FRAME_BYTES], (folder, i, 'pixel mismatch')
            stamps.append(int(match[1]))
            original_ids.append(int(match[2]))
            scores.append(int(match[4]))
        assert len(stamps) * FRAME_BYTES == len(raw)
        datasets.append(dict(
            id=ident, name=name, raw_path=str(raw_path), frames=len(stamps), width=96, height=96,
            timestamps_ms=stamps, ai_scores=scores, ir_counts=[None]*len(stamps),
            original_frame_numbers=original_ids, source='offline_recording', raw_sha256=digest(raw),
            provenance=dict(serial_log=str(log), metadata='MMT_THUMB 设备 t/f/p；48×48 最近邻放大到 96×96，逐像素与 frames.bin 验证一致'),
            notes='历史板端 48×48 缩略图 ×2 最近邻放大，约 1.6–1.9 秒转储一帧。名称来自操作记录，不是逐帧人体身份或框真值。AI 输出不是人工标签，红外缺失；旧固定 90/3 输入弃用。不能用于 400ms 预测精度结论。'))
    for dataset in datasets:
        times = dataset['timestamps_ms']
        if any(b <= a for a,b in zip(times,times[1:])):
            raise ValueError('Non-monotonic recorded timestamps: '+dataset['id'])
        delta = [b-a for a,b in zip(times,times[1:])]
        dataset['sampling'] = dict(median_ms=statistics.median(delta), min_ms=min(delta), max_ms=max(delta),
                                   nominal_400ms_future_pairs=sum(d<=500 for d in delta))
    return datasets


def compile_runners(output):
    runner = HERE / 'recording_replay.c'
    dev = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not dev.exists():
        raise FileNotFoundError('MSVC compiler environment missing: '+str(dev))
    batch = output / 'build_recording_replay.bat'
    lines = ['@echo off', f'call "{dev}" >nul 2>&1', 'if errorlevel 1 exit /b 1', f'cd /d "{output}"']
    for variant in ['baseline', 'optimized']:
        define = '/DBASELINE' if variant == 'baseline' else ''
        lines += [f'cl /nologo /utf-8 /W3 /O2 {define} "{runner}" /Fe:recording_{variant}.exe > build_{variant}.log 2>&1',
                  'if errorlevel 1 exit /b 1']
    lines.append('exit /b 0')
    batch.write_text('\n'.join(lines)+'\n', encoding='utf8')
    result = subprocess.run([str(batch)], capture_output=True, text=True, errors='replace')
    if result.returncode:
        raise RuntimeError('Recording runner build failed; see '+str(output/'build_optimized.log'))


def proxy_summary(rows, horizon_steps=2):
    ids = set()
    counts, observed_counts, det_counts, personlike_counts, errors, stationary_errors = [], [], [], [], [], []
    pair_count = 0
    for row in rows:
        tracks = row['tracks']
        counts.append(sum(t['confirmed'] and t['active'] for t in tracks))
        observed_counts.append(sum(t['confirmed'] and t['active'] and t['misses']==0 for t in tracks))
        det_counts.append(row['n_det'])
        personlike_counts.append(row.get('personlike_count',0))
        ids.update(t['id'] for t in tracks if t['confirmed'])
    # The future item is exactly i + 2 in this deliberately normalized replay,
    # never the next record with firmware f+1 (multiple MOT steps may share f).
    for i in range(len(rows)-horizon_steps if horizon_steps else 0):
        future = {t['id']:t for t in rows[i+horizon_steps]['tracks']
                  if t['confirmed'] and t['active'] and t['misses']==0}
        for track in rows[i]['tracks']:
            if not track['confirmed'] or not track['active'] or track['misses']:
                continue
            target = future.get(track['id'])
            if target is None:
                continue
            errors.append(math.hypot(track['px']-target['cx'], track['py']-target['cy']))
            stationary_errors.append(math.hypot(track['cx']-target['cx'], track['cy']-target['cy']))
            pair_count += 1
    def describe(values):
        return dict(pairs=len(values), median_px=round(statistics.median(values),4), mean_px=round(statistics.mean(values),4)) if values else dict(pairs=0, median_px=None, mean_px=None)
    total = max(1,len(rows))
    return dict(
        frames=len(rows), confirmed_ids=len(ids), confirmed_track_frames=sum(counts),
        frames_with_observed_confirmed_track=sum(n>0 for n in observed_counts),
        output_coverage_pct=round(100*sum(n>0 for n in observed_counts)/total,3),
        personlike_output_coverage_pct=round(100*sum(n>0 for n in personlike_counts)/total,3),
        frames_with_two_personlike_outputs=sum(n>=2 for n in personlike_counts),
        frames_with_two_confirmed_tracks=sum(n>=2 for n in counts),
        average_observed_tracks=round(sum(observed_counts)/total,4),
        average_detection_count=round(sum(det_counts)/total,4),
        prediction_to_same_track_future_observation=describe(errors),
        stationary_to_same_track_future_observation=describe(stationary_errors),
        lookahead_replay_samples=horizon_steps,
        caveat='Output-coverage/ID counts are regression proxies, not recall/ID switches. Same-ID future observation is tracker-derived, not independent ground truth; pair sets differ across variants.')


def replay(datasets, output, with_recorded_time=False):
    report = []
    for dataset in datasets:
        ident = dataset['id']
        folder = output / ident
        folder.mkdir(exist_ok=True)
        ai = folder/'ai_observed.txt'
        ir = folder/'ir_unknown.txt'
        stamps = folder/'time_ms.txt'
        # No fabricated positive evidence: unknown IR remains disabled (0),
        # real classifier scores remain outputs, not person presence truth.
        ai.write_text('\n'.join(str(v if v is not None else -128) for v in dataset['ai_scores'])+'\n')
        ir.write_text(('0\n')*dataset['frames'])
        stamps.write_text('\n'.join(str(v) for v in dataset['timestamps_ms'])+'\n')
        entry = dict(id=ident, input_frames=dataset['frames'], sampling=dataset['sampling'],
                     source='offline_recording', human_box_or_id_ground_truth=False,
                     evidence_input='observed classifier scores, unknown IR=0; no inferred person labels', variants={})
        for variant in ['baseline','optimized']:
            mode = 'recorded_time' if with_recorded_time else 'normalized_200ms'
            args = [output/f'recording_{variant}.exe', dataset['raw_path'], ai, ir, stamps,
                    '1' if with_recorded_time else '0']
            run = subprocess.run([str(v) for v in args], capture_output=True, text=True, timeout=60)
            (folder/f'{variant}_{mode}.jsonl').write_text(run.stdout,encoding='utf8')
            (folder/f'{variant}_{mode}.stderr.txt').write_text(run.stderr,encoding='utf8')
            if run.returncode:
                raise RuntimeError(f'Replay failed: {ident}/{variant}: {run.stderr}')
            rows = [json.loads(line) for line in run.stdout.splitlines() if line.strip()]
            assert len(rows) == dataset['frames']
            # A 400ms physical target has no nearby observation in the sparse
            # material. Do not compare it to an observation 3–6 seconds later.
            entry['variants'][variant] = proxy_summary(rows, None if with_recorded_time else 2)
        report.append(entry)
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--old-repo',type=Path,default=Path(r'D:\FPGA\netfix04'))
    ap.add_argument('--capture-root',type=Path,default=Path(r'D:\v30_build'))
    ap.add_argument('--raw-root',type=Path,default=Path(r'D:\v30_build\mot_off'))
    ap.add_argument('--out',type=Path,default=HERE/'recording_evaluation')
    ap.add_argument('--index-only',action='store_true')
    ap.add_argument('--saved-index',type=Path,help='Replay audited portable pixels; verify their stored SHA256 without original archives')
    ap.add_argument('--recorded-time',action='store_true', help='Use real sparse timestamps; metrics still not prediction ground truth')
    a=ap.parse_args();a.out.mkdir(exist_ok=True,parents=True)
    if a.saved_index:
        datasets=json.loads(a.saved_index.read_text(encoding='utf8'))['datasets']
        for d in datasets:
            p=Path(d['raw_path'])
            if not p.is_absolute():p=a.saved_index.absolute().parent/p
            assert digest(p.read_bytes())==d['raw_sha256'],d['id']+' pixel digest mismatch'
            d['raw_path']=str(p)
    else:
        datasets=audit_sources(a.old_repo,a.capture_root,a.raw_root)
        index=dict(schema=1,datasets=datasets)
        (HERE/'recordings_index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2),encoding='utf8')
    for d in datasets:print(d['id'],d['frames'],d['sampling'],flush=True)
    if a.index_only:return
    compile_runners(a.out)
    metrics = replay(datasets,a.out,a.recorded_time)
    report=dict(schema=1,evaluation_mode='recorded_sparse_time' if a.recorded_time else 'normalized_200ms_regression',
                header_sha256={name:digest((PROJECT/'evidence/v30_mot'/file).read_bytes()) for name,file in [('baseline','mot_core_baseline.h'),('optimized','mot_core.h')]},
                source_index=str(HERE/'recordings_index.json'),physical_400ms_accuracy_measurable=False,
                datasets=metrics,notes=[
                    'No manually annotated boxes or person identities were found. Names/prompts do not prove per-frame labels.',
                    'Recordings are sparse (1.6–3.3s), not 200ms video. Normalized 200ms mode is a controlled algorithm regression and cannot claim real-world 400ms accuracy.',
                    'Old constant ai=90/ir=3 files are excluded. Actual classifier scores were recovered; IR is unknown and disabled.',
                    'Physical-time mode omits future-position error because no approximately 400ms target observation exists.',
                    'ID count reductions can hide tracking loss; always inspect output coverage alongside fragmentation proxies.',
                    'Do not claim MOTA, IDF1, ID-switch accuracy or real-person forecast accuracy from this report.'])
    path=HERE/('recordings_report_recorded_time.json' if a.recorded_time else 'recordings_report.json')
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print('REPORT',path,flush=True)
    for d in metrics:
        print(d['id'],{name: {'ids':v['confirmed_ids'],'coverage_pct':v['output_coverage_pct'],
                             'two_tracks':v['frames_with_two_confirmed_tracks']} for name,v in d['variants'].items()},flush=True)


if __name__=='__main__':main()
