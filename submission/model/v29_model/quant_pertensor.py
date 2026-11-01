import numpy as np, tensorflow as tf, keras
model = keras.models.load_model(r"D:\FPGA\mmt\work_v29\out\run6\v29_best.keras")
xva = np.load(r"D:\FPGA\mmt\work_v29\data\vww96\val_x.npy")
def rep():
    idx = np.linspace(0, len(xva)-1, 300).astype(int)
    for i in idx:
        yield [ (xva[i].astype(np.float32)/127.5-1.0)[None,:,:,None] ]
conv = tf.lite.TFLiteConverter.from_saved_model(r"D:\FPGA\mmt\work_v29\out\run6\saved_model")
conv.optimizations=[tf.lite.Optimize.DEFAULT]
conv.representative_dataset=rep
conv.target_spec.supported_ops=[tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
conv.inference_input_type=tf.int8
conv.inference_output_type=tf.int8
try:
    conv._experimental_disable_per_channel = True
    print("disable_per_channel set")
except Exception as e:
    print("set failed", e)
tfl = conv.convert()
p = r"D:\FPGA\mmt\work_v29\out\run6\quant\v29_person_96_int8_pertensor.tflite"
open(p,"wb").write(tfl)
print("CONVERT OK", len(tfl))
it = tf.lite.Interpreter(model_path=p)
it.allocate_tensors()
print("LOAD OK", it.get_input_details()[0]['quantization'], it.get_output_details()[0]['quantization'])
