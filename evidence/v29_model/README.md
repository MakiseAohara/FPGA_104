# v29 人检模型（96×96，5 Conv + GAP + 2 FC，INT8，95,922 参数）—— 含场景校准微调

> 目标：符合赛题指标（≤5 卷积 + 2 全连接、≤100K 参数、INT8）；跑通官方 TinyML Generator；场景校准后 F 段可区分。
> 结论（三行）：**95,922 参数 / COCO 验证 69.9%（微调后）/ v29_scene F 段 int8 中位数 有人 +104、无人 −18（acc 96.3%，AUC 0.981）**。

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
- 输出语义：person 分数（class 1），有人为正

## 2. 数据与预处理

- COCO 2017（VWW 口径）：**训练 27,348 / 验证 4,952**（person 框与 crop 区域重叠 ≥0.5% 为正）
- 预处理逐行复现 `evidence/v28_fw/preprocess_core.h`：CROP_MODE=1、3×3 盒 × 2×2 quad mean、1%/99% 分位拉伸、NORM 关闭（`board_preprocess.py`，与 C 逻辑逐像素等价的快速实现）
- 训练增强：水平翻转、**暗光（×0.2~0.6）+ 高斯噪声 + 再次 STRETCH**、对比度、±8% 平移

## 3. 场景校准微调（本轮新增）

- 训练：COCO 12,000 张 + 场景（v29_scene **D+E 段 105 张** + 旧场景训练段 339 张），场景样本重复使每批占 **25%**
- 强增强：亮度 ×0.5~1.3、对比度、水平翻转、±10% 平移、轻微缩放 0.9~1.1
- 验证：**v29_scene F 段整段**（54 张，26 正/28 负）+ COCO 验证（3000 张）
- 训练 8 epoch，按 F 段 AUC+中位差选最佳（epoch 6）

### 结果（INT8 量化后，板上口径 u→(int8)(u−128)）

| 数据集 | n | 有人中位 q | 无人中位 q | 阈值 0 准确率 | AUC |
|---|---|---|---|---|---|
| **F（验证段）** | 54 | **+104** | **−18** | **96.3%** | **0.981** |
| D | 51 | +111 | +61 | 84.3% | 0.752 |
| E | 54 | +109 | −3 | 100% | 1.000 |
| D+E+F | 159 | +109 | −15 | 93.7% | 0.937 |
| COCO 验证 | 3,000 | — | — | **69.9%**（微调前 71.3%） | 0.767 |

> 目标「F 段有人中位 > 0、无人中位 < 0」**已达成**（+104 / −18）。COCO 验证仅下降 1.4 个百分点。

## 4. 旧模型对照（mobilenetv1_person_detect.tflite，D/E/F 段，n=159）

旧模型 tflite 的 `quantized_dimension` 越界（=3），TF 2.16 无法直接加载；`old_model_eval.py` 把它修补为 0 后加载（补丁只动该字段，不改权重）。

| 输入口径 | AUC(D/E/F) | 阈值 0.5 准确率 | 有人中位 | 无人中位 | 分段 AUC（D/E/F） |
|---|---|---|---|---|---|
| **位重解释** `q=(int8)u` | **0.830** | 79.2% | 0.695 | 0.402 | 0.615 / 0.885 / 0.973 |
| **u−128** `q=(int8)(u−128)` | **0.292** | 32.7% | 0.281 | 0.445 | 0.148 / 0.212 / 0.372 |

⇒ 旧模型在「位重解释」口径下明显更好；新模型训练口径是 u−128（与计划中的固件 `INPUT_SUB128=1` 一致），两者不可直接互换。

## 5. 官方 TinyML Generator 产物

`generator/`（官方 `tinyml_generator.py` headless + `bin/tflite.exe`）：
- `defines.v`：AXI_DW=128、CONV_DEPTHW_MODE=LITE、LITE_PARALLEL=4、LITE_AW=7、FC_MODE=DISABLE、CACHE=512
- **微调后重跑 Generator，`defines.v` 与微调前逐字节一致**（只换权重，不改结构）
- `define.cc`：`conv_depthw_mode=1`、`fc_mode=0`
- 加速器兼容结论见 `accel_compat.md`：现位流 LITE 加速器可直接跑，无需改 RTL

## 6. 未完成 / 风险

- **未烧录、未上板**（按要求只做离线训练/量化/生成）
- 固件必须 `INPUT_SUB128=1`；位重解释口径下新模型精度会明显下降
- COCO 数据 27,348（目标 4 万，剩余分片下载受限流影响未补齐）
- D 段无人样本仅 6 张、E 段 2 张，D 段 AUC 0.752 偏低，样本量是主要限制
- 旧版（微调前）产物保留在 `_pre_finetune/`

## 7. 复现

```powershell
python tools/prepare_data_board.py / gen_coco_board.py     # 板上口径 COCO 数据
python tools/train_board.py --data data/vww96_board --out out/b1 --epochs 40
python tools/mix_scene_v29.py --model out/b1/v29_best.keras --coco data/vww96_board ^
  --scene-v29 data/v29_scene --labels-v29 comms/scene_labels_v29/labels_v29_scene.csv ^
  --scene-old data/scene --out out/cal1 --epochs 8 --lr 2e-4
python tools/quantize_v29.py --model out/cal1/v29_scene_best.keras --data data/vww96_board --out out/cal1/quant --input-type int8
python tools/eval_cal.py --tflite out/cal1/quant/v29_person_96_int8.tflite --frames data/v29_scene ^
  --labels comms/scene_labels_v29/labels_v29_scene.csv --coco data/vww96_board --out out/cal1/eval/eval_cal.json
python tools/gen_tinyml.py out/cal1/quant/v29_person_96_int8.tflite out/cal1/gen
```
