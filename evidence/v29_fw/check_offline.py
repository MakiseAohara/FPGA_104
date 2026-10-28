"""Compare generated-model TFLite Micro C++ Invoke against model reference inference."""
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT.parent/'v29_litert_runtime'))
import numpy as np
from ai_edge_litert.interpreter import Interpreter,OpResolverType

spec=importlib.util.spec_from_file_location('scene_export',ROOT/'evidence/v29_scene/export_scene.py')
scene=importlib.util.module_from_spec(spec);spec.loader.exec_module(scene)
frames=[row for row in scene.parse()[0] if row['stage']=='F']
work=ROOT.parent/'v29_host_build'
data=b''.join(row['pixels'].tobytes() for row in frames)
(work/'F_pixels_u8.bin').write_bytes(data)
run=subprocess.run([str(work/'offline_invoke.exe'),str(work/'F_pixels_u8.bin'),str(work/'c_scores.csv')],capture_output=True,timeout=180)
(HERE/'offline_invoke.log').write_bytes(run.stdout+run.stderr)
print('C_INVOKE_EXIT',run.returncode,run.stderr.decode(errors='replace')[-900:],flush=True)
if run.returncode:raise SystemExit(run.returncode)
with (work/'c_scores.csv').open(newline='') as stream:c_scores=list(csv.DictReader(stream))
model=ROOT.parent/'v29_today_snapshot/evidence/v29_model/v29_person_96_int8.tflite'
interpreter=Interpreter(model_path=str(model),num_threads=1)
interpreter.allocate_tensors()
ind=interpreter.get_input_details()[0];out=interpreter.get_output_details()[0]
assert list(ind['shape'])==[1,96,96,1] and list(out['shape'])==[1,2]
rows=[]
for image,c in zip(frames,c_scores):
    centered=(image['pixels'].astype(np.int16)-128).astype(np.int8)
    interpreter.set_tensor(ind['index'],centered[None,:,:,None]);interpreter.invoke()
    ref=int(interpreter.get_tensor(out['index'])[0,1]);actual=int(c['person'])
    rows.append(dict(device_ms=image['t'],f=image['f'],reference_p=ref,c_person_p=actual,
        abs_error=abs(ref-actual),raw_pixels_sha256=hashlib.sha256(image['pixels'].tobytes()).hexdigest()))
assert len(rows)==len(frames)==len(c_scores)
with (HERE/'F_frame_scores.csv').open('w',encoding='utf-8',newline='') as stream:
    writer=csv.DictWriter(stream,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
result=dict(model_commit='aea24d501f9c7e4df7297a40a9b58d1c6dd8f74e',
    model_sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
    F_frames=len(rows),max_abs_error=max(r['abs_error'] for r in rows),
    within_one=sum(r['abs_error']<=1 for r in rows),passed=all(r['abs_error']<=1 for r in rows),
    input_shape=list(map(int,ind['shape'])),output_shape=list(map(int,out['shape'])),
    input_quantization=list(ind['quantization']),output_quantization=list(out['quantization']),
    kPersonIndex=1,kNotAPersonIndex=0,
    reference_source='aea24d5 eval_log.py input and class-1 scoring rule, reconstructed using LiteRT default kernels, matching eval_log.py default interpreter invocation',
    original_per_frame_reference_file_present=False,original_F_class_labels_present=False,
    ground_truth_F_medians_verified=False,
    scope='actual board TFLite Micro C++ sources and generated model, shared C input centering and Invoke; host driver OP_ERR invokes existing software fallbacks, no hardware emulation')
(HERE/'offline_check.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result),flush=True)
raise SystemExit(0 if result['passed'] else 1)
