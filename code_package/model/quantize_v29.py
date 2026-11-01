# -*- coding: utf-8 -*-
"""v29 模型 -> 全整数 INT8 TFLite（输入 [-1,1] 归一化，匹配板上现有模型的 int8/scale/zp 口径）"""
import argparse, json, os
import numpy as np
import tensorflow as tf
from tensorflow import keras

def rep_dataset(xva, n=500, norm='pm1'):
    idx = np.linspace(0, len(xva) - 1, min(n, len(xva))).astype(int)
    for i in idx:
        x = xva[i].astype(np.float32) / 127.5 - 1.0 if norm == 'pm1' else xva[i].astype(np.float32) / 255.0
        yield [x[None, :, :, None]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True)
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--n-rep', type=int, default=500)
    ap.add_argument('--input-type', default='int8', choices=['int8','uint8'])
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    model = keras.models.load_model(args.model)
    xva = np.load(os.path.join(args.data, 'val_x.npy'))
    model.export(os.path.join(args.out, 'saved_model'))
    conv = tf.lite.TFLiteConverter.from_saved_model(os.path.join(args.out, 'saved_model'))
    conv.optimizations = [tf.lite.Optimize.DEFAULT]
    conv._experimental_disable_per_channel = True
    conv.representative_dataset = lambda: rep_dataset(xva, args.n_rep, 'pm1' if args.input_type == 'int8' else '0to1')
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    conv.inference_input_type = tf.int8 if args.input_type == 'int8' else tf.uint8
    conv.inference_output_type = tf.int8
    tfl = conv.convert()
    p = os.path.join(args.out, 'v29_person_96_int8.tflite')
    open(p, 'wb').write(tfl)
    it = tf.lite.Interpreter(model_content=tfl)
    it.allocate_tensors()
    ind = it.get_input_details()[0]; outd = it.get_output_details()[0]
    info = {
        'file': p, 'size': len(tfl),
        'input': {'dtype': str(ind['dtype']), 'shape': list(ind['shape']),
                  'scale': float(ind['quantization'][0]), 'zero_point': int(ind['quantization'][1])},
        'output': {'dtype': str(outd['dtype']), 'shape': list(outd['shape']),
                   'scale': float(outd['quantization'][0]), 'zero_point': int(outd['quantization'][1])},
    }
    print(json.dumps(info, indent=2))
    json.dump(info, open(os.path.join(args.out, 'v29_tflite_io.json'), 'w'), indent=2)

if __name__ == '__main__':
    main()


