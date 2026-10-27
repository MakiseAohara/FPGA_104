# -*- coding: utf-8 -*-
"""用官方 TinyML Generator（PyQt6 offscreen）为新 tflite 生成 RTL/软件配置与模型数据。"""
import os, sys, json

GEN = r'D:\FPGA\mmt\work_v29\demo\Demo\tinyml-main\tools\tinyml_generator'
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
sys.path.insert(0, GEN)
os.chdir(GEN)

import tinyml_generator as tg
from PyQt6.QtWidgets import QApplication


def find_param(d, key):
    for k, v in d.items():
        if k == key:
            return v
        if isinstance(v, dict) and isinstance(v.get('children'), dict):
            r = find_param(v['children'], key)
            if r is not None:
                return r
    return None


def set_param(key, val):
    v = find_param(tg.params, key)
    if v is None:
        print('WARN param not found:', key)
    else:
        v['val'] = val


def main():
    model = sys.argv[1]
    outdir = sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    app = QApplication([])
    tg.app = app
    w = tg.Widget()
    w.model_file = model
    w.current_dir = outdir
    set_param('AXI_DW', '128')
    set_param('CONV_DEPTHW_MODE', 'LITE')
    set_param('CONV_DEPTHW_LITE_PARALLEL', 4)
    for k in ('ADD_MODE', 'MUL_MODE', 'MIN_MAX_MODE', 'FC_MODE', 'LR_MODE', 'RS_MODE'):
        set_param(k, 'DISABLE')
    set_param('TINYML_CACHE', 'ENABLE')
    set_param('CACHE_DEPTH', '512')
    w.res_utilization = lambda *a, **k: None
    w.parse_model()
    # parse_model 会按 tflite.exe 的报告把模式改成 STANDARD；板上 RTL 固定 LITE，这里强制回 LITE 以保持一致
    set_param('CONV_DEPTHW_MODE', 'LITE')
    set_param('FC_MODE', 'DISABLE')
    set_param('FC_MAX_IN_NODE', 640)
    set_param('FC_MAX_OUT_NODE', 640)
    w.tflite_gen = True
    w.generate()
    print('generated to', w.op_path)
    files = sorted(os.listdir(w.op_path))
    print('files:', files)
    json.dump({'model': model, 'out': w.op_path, 'files': files},
              open(os.path.join(outdir, 'generator_result.json'), 'w'), indent=2)


if __name__ == '__main__':
    main()




