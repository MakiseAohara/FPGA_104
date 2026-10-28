# v29 人检模型（96×96，5 Conv + GAP + 2 FC，INT8，95,922 参数）—— 场景校准微调（日志解码版）

> 数据来源已更正：**全部场景帧从 `evidence/v29_scene/log_v29_scene.log` 的 `MMT_IMG` 十六进制字节解码**，像素 = 字节原样 `uint8(u)`（不 +128、不做 int8 转换），**不使用任何 PNG / frames_v29_scene.zip**。
> 结论（三行）：**95,922 参数 / COCO 验证 69.4% / v29_scene F 段 int8 中位数 有人 +100、无人 −91（阈值 0 准确率 94.4%，AUC 0.985）**。

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

- 参数量 **95,922**（`model_summary.txt` / `model_summary.png`）
- 量化后：输入 INT8 `scale=1/127.5, zero_point=-1`；输出 INT8 `scale=1/256, zero_point=-128`
- 板上口径：固件 `INPUT_SUB128=1`，像素 `u → (int8)(u-128)`，对应训练归一化 `x=(u-128)/127.5`

## 2. 日志解码与自检（必须先通过）

- 日志：`evidence/v29_scene/log_v29_scene.log`（8,243,348 B）。`log_v29_scene.sha256.txt` 记载 8,206,080 B / `A6D9F27A…`，差值 37,268 B 恰为行数 ⇒ **同一份内容的 LF/CRLF 差异**；`part01..part10` 之和 = 8,243,348 B = 单文件，内容一致。
- 解析：`decode_scene_log.py` 复刻 `export_scene.py` 的 `parse()`（`MMT_IMGSTAT` 开帧、`MMT_IMG` 96 行 × 96 字节），帧号不连续则丢弃当前组。
- **自检**（旧模型 `mobilenetv1_person_detect.tflite`，输入 `q=u.view(int8)`，与日志中的板上 `p` 比较）：

| 范围 | 相关系数 | mean\|Δ\| | \|Δ\|≤2 占比 |
|---|---|---|---|
| **D+E+F（训练/验证相关段）** | **0.9993** | 1.6 | **79.9%** |
| A/B/C（含 `p=-128` 的无推理帧） | 0.54 / 0.73 / 0.99 | — | — |
| 全部 330 帧 | 0.9574 | 4.24 | 71.5% |

> A/B 段含 `p=-128`（固件未做 AI 采样）的帧，模型输出不可比；剔除后 D/E/F 达到 0.9993（与任务书给出的 0.9992 一致）。

## 3. 场景校准微调

- 训练：COCO 12,000 张 + 场景（v29_scene **D+E 段 105 张** + 旧场景训练段 339 张），场景样本重复使每批占 **25%**
- 强增强：亮度 ×0.5~1.3、对比度、水平翻转、±10% 平移、缩放 0.9~1.1
- 验证：**F 段整段**（54 张，26 正/28 负）+ COCO 验证（3000 张）
- 8 epoch，按 F 段 AUC+中位差选最佳（epoch 3）

### 结果（INT8 量化后，板上口径 `u→(int8)(u−128)`）

| 数据集 | n | 有人中位 q | 无人中位 q | 阈值 0 准确率 | AUC |
|---|---|---|---|---|---|
| **F（验证段）** | 54 | **+100** | **−91** | **94.4%** | **0.985** |
| D | 51 | +114 | −65 | 90.2% | 0.933 |
| E | 54 | +111 | −46 | 94.4% | 0.971 |
| D+E+F | 159 | +110 | −89 | 93.1% | 0.972 |
| COCO 验证 | 3,000 | — | — | **69.4%** | 0.773 |

> 目标「F 段有人中位 > 0、无人中位 < 0」**已达成**（+100 / −91），分离比 PNG 版更干净（PNG 版为 +104 / −18）。

## 4. 旧模型两口径对照（D/E/F 段，n=159）

旧模型 tflite 的 `quantized_dimension` 越界（=3），TF 2.16 无法直接加载；`old_model_eval.py` 已修补该字段（只动该字段，不改权重）。

| 输入口径 | AUC(D/E/F) | 阈值 0.5 准确率 |
|---|---|---|
| **位重解释** `q=(int8)u` | **0.830** | 79.2% |
| **u−128** `q=(int8)(u−128)` | 0.292 | 32.7% |

## 5. 官方 TinyML Generator

`generator/`（官方 `tinyml_generator.py` headless + `bin/tflite.exe`）：
- `defines.v`：AXI_DW=128、CONV_DEPTHW_MODE=LITE、LITE_PARALLEL=4、LITE_AW=7、FC_MODE=DISABLE、CACHE=512
- **日志版微调后重跑 Generator，`defines.v` 与上一版逐字节一致**（只换权重）
- 加速器兼容见 `accel_compat.md`：现位流 LITE 加速器可直接跑，无需改 RTL

## 6. 版本与作废说明

- `_pre_finetune/`：COCO 训练、未做场景微调的版本（COCO val 71.3%）
- `_bad_export/`：**基于 PNG（`u+128` 显示转换）重建的微调版本，已作废**（PNG 像素不是固件喂给模型的字节）
- 当前根目录：日志解码 → 微调 → 量化 → Generator 的最终版本

## 7. 复现

```powershell
python tools/decode_scene_log.py --log evidence/v29_scene/log_v29_scene.log ^
  --old-model <person_detect_fixed.tflite> --labels comms/scene_labels_v29/labels_v29_scene.csv --out scene_log_check.json
python tools/mix_scene_log.py --model out/b1/v29_best.keras --coco data/vww96_board ^
  --log evidence/v29_scene/log_v29_scene.log --labels comms/scene_labels_v29/labels_v29_scene.csv ^
  --scene-old data/scene --out out/cal2 --epochs 8 --lr 2e-4
python tools/quantize_v29.py --model out/cal2/v29_scene_best.keras --data data/vww96_board --out out/cal2/quant --input-type int8
python tools/eval_log.py --tflite out/cal2/quant/v29_person_96_int8.tflite --log evidence/v29_scene/log_v29_scene.log ^
  --labels comms/scene_labels_v29/labels_v29_scene.csv --coco data/vww96_board --out out/cal2/eval/eval_log.json
python tools/gen_tinyml.py out/cal2/quant/v29_person_96_int8.tflite out/cal2/gen
```

## 8. 未完成 / 风险

- **未烧录、未上板**（按要求只做离线训练/量化/生成）
- 固件必须 `INPUT_SUB128=1`
- COCO 训练数据 27,348（目标 4 万，剩余分片下载受限流影响未补齐）
- 旧模型 tflite 的 `quantized_dimension` 修补属于离线评估手段，不代表板上推理路径
