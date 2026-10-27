# v29 人检模型（96×96，5 Conv + GAP + 2 FC，INT8，95,922 参数）

> 任务：训练符合赛题指标（≤5 卷积 + 2 全连接、≤100K 参数、INT8）的人体检测模型，跑通官方 TinyML Generator，并与现位流加速器比对。
> 结论（三行）：**95,922 参数 / COCO 验证准确率 71.3%（板上口径 AUC 0.784）/ 场景留出集 55.4%（域差异大，如实记录）**。

---

## 1. 模型（严格按任务书）

```
输入 96×96×1
Conv3x3 s2 16 + BN + ReLU -> 48×48×16
Conv3x3 s2 32 + BN + ReLU -> 24×24×32
Conv3x3 s2 48 + BN + ReLU -> 12×12×48
Conv3x3 s2 64 + BN + ReLU -> 6×6×64
Conv3x3 s2 80 + BN + ReLU -> 3×3×80
GlobalAveragePooling
Dense 32 + ReLU
Dense 2 + Softmax
```

- 参数量 **95,922**（`model_summary.txt`，截图 `model_summary.png`）
- 输出语义：person 分数（class 1），有人为正

## 2. 数据（按板上固件预处理复现）

- 来源：COCO 2017（`detection-datasets/coco` parquet），VWW 口径
- **标签**：person 框与 **crop 区域**（1920×1080 画面中间 1080×1080）的重叠面积 / 1080² ≥ 0.5% 为正
- **预处理**（`board_preprocess.py`，逐行复现 `evidence/v28_fw/preprocess_core.h`）：
  CROP_MODE=1（x0=420, 1080×1080）、PP_BOX=3×3 盒、每盒 2×2 quad mean、1%/99% 分位拉伸、NORM 关闭
- 规模：**训练 27,348 / 验证 4,952**（pos 约 53%/52%）；COCO 分片仍在补齐（目标 4 万）
- 训练增强（`train_board.py`）：水平翻转、**暗光（亮度×0.2~0.6）+ 高斯噪声 + 再次 STRETCH**、对比度、±8% 平移

## 3. 训练与量化

- Adam + cosine，batch 128，40 epoch（实际按 best val 取 27 epoch 的权重），训练 27,348 图
- 归一化 `x/127.5-1`（与固件 `(int8)(u-128)` 对齐）
- 量化：`model.export()` → SavedModel → `TFLiteConverter.from_saved_model`（绕过 TF2.16+Keras3 的 `LLVM ERROR`），per-tensor INT8
- 产物 `v29_person_96_int8.tflite`（101,088 B）：
  - input **INT8, scale=0.0078431377 (=1/127.5), zero_point=-1**（与板上旧模型完全一致）
  - output INT8, scale=0.00390625 (1/256), zero_point=-128

## 4. 评估（板上口径：像素 u → (int8)(u-128)）

| 数据集 | 样本 | 准确率@0.5 | AUC | 正均值 | 负均值 |
|---|---|---|---|---|---|
| COCO 验证（板上预处理） | 3,000 | **71.3%** | **0.784** | 0.644 | 0.365 |
| 场景留出集（v25/v27/v28 段，`label_intruder`） | 148 | 55.4% | 0.575 | 0.208 | 0.166 |
| 场景训练段（旧固件段，`label_intruder`） | 339 | 78.2% | 0.902 | 0.255 | 0.073 |

**结论**：COCO 域与旧固件场景段表现正常；**新固件场景留出段（v25/v27/v28）准确率只有 55.4%，tp=1/fn=66**，属于明显域差异，且「闯入者 vs 桌前室友」在单帧外观上不可分（该判定应由 RTL/融合逻辑结合位置/时序完成，不是单帧 person 模型能解决）。本次**未做场景微调**（339 张样本过拟合严重，实测微调后场景 val 仍 50%）。

### v27 板上帧新旧分数对比（`eval_b1.json`）

| 帧 | 旧模型 p | 新模型 p | 新模型 q |
|---|---|---|---|
| frame_0001 | 0.156 | 0.332 | -43 |
| frame_0002 | 0.191 | 0.285 | -55 |
| frame_0003 | 0.668 | 0.078 | -108 |
| frame_0004 | 0.125 | 0.145 | -91 |
| frame_0005 | 0.344 | 0.035 | -119 |
| frame_0006 | 0.285 | 0.113 | -99 |
| frame_0007 | 0.211 | 0.090 | -105 |
| frame_0008 | 0.297 | 0.117 | -98 |
| frame_0009 | 0.254 | 0.316 | -47 |
| frame_0010 | 0.457 | 0.051 | -115 |

（旧模型分数取自 `evidence/v27_gate/frames.csv` 的板上实测 `p`；新模型为离线推理。）

## 5. 官方 TinyML Generator 产物

`generator/` 目录（PyQt6 headless 调用官方 `tinyml_generator.py`）：
- `defines.v`：AXI_DW=128、CONV_DEPTHW_MODE=LITE、LITE_PARALLEL=4、LITE_AW=7、FC_MODE=DISABLE、CACHE=512 —— 与现位流逐项一致
- `define.cc` / `define.h`：`conv_depthw_mode=1`、`fc_mode=0`
- `v29_person_96_int8_model_data.cc/.h`：模型权重数据

**加速器兼容性**：见 `accel_compat.md` —— 现位流 LITE 卷积加速器**可直接跑新模型**；GAP/FC/Softmax 走 CPU；无需重新综合 RTL。

## 6. 未完成 / 风险

- **未烧录、未上板**（按要求只做离线训练/量化/生成）
- 固件必须 `INPUT_SUB128=1`；若仍为 0（位重解释），输入亮度折叠，实测精度从 71.3% 掉到 55%~56%
- COCO 数据 27,348 张（目标 4 万），剩余分片下载中；加大数据后可再提升
- 场景留出集（v25/v27/v28）域差异大，55.4%，需要更多新固件场景数据或时序/位置特征

## 7. 复现

```powershell
# 环境：conda env v29 (Python 3.11) + tensorflow-intel 2.16.2 + keras 3.3.3 + PyQt6
python tools/prepare_data_board.py --parquet-dir <coco parquet> --out data/vww96_board   # 或 gen_coco_board.py
python tools/train_board.py --data data/vww96_board --out out/b1 --epochs 40
python tools/quantize_v29.py --model out/b1/v29_best.keras --data data/vww96_board --out out/b1/quant --input-type int8
python tools/eval_board.py --new out/b1/quant/v29_person_96_int8.tflite --coco-data data/vww96_board --scene-data data/scene --frames <evidence/v27_gate> --out out/b1/eval
python tools/gen_tinyml.py out/b1/quant/v29_person_96_int8.tflite out/b1/gen
```
