import os, sys, numpy as np, tensorflow as tf, keras
model = keras.models.load_model(r"D:\FPGA\mmt\work_v29\out\run6\v29_best.keras")
xva = np.load(r"D:\FPGA\mmt\work_v29\data\vww96\val_x.npy")
def rep():
    idx = np.linspace(0, len(xva)-1, 300).astype(int)
    for i in idx:
        yield [ (xva[i].astype(np.float32)/127.5-1.0)[None,:,:,None] ]
try:
    model.export(r"D:\FPGA\mmt\work_v29\out\run6\saved_model")
    print("EXPORT OK")
    conv = tf.lite.TFLiteConverter.from_saved_model(r"D:\FPGA\mmt\work_v29\out\run6\saved_model")
    conv.optimizations=[tf.lite.Optimize.DEFAULT]
    conv.representative_dataset=rep
    conv.target_spec.supported_ops=[tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    conv.inference_input_type=tf.int8
    conv.inference_output_type=tf.int8
    tfl = conv.convert()
    open(r"D:\FPGA\mmt\work_v29\out\run6\quant\v29_person_96_int8.tflite","wb").write(tfl)
    print("CONVERT OK", len(tfl))
except Exception as e:
    print("FAIL", type(e).__name__, str(e)[:400])
