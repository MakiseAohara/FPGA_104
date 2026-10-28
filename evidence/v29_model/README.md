# v29 人检模型（96×96，5 Conv + GAP + 2 FC，INT8，95,922 参数）—— 第二轮：白天场景校准

> 本轮在**第一轮（v29_scene 日志解码）**基础上加入白天采集数据混合微调。
> 结论三行：**95,922 参数不变；v29_scene F 段 int8 有人中位 +101 / 无人 −105（阈值 0 准确率 98.1%，AUC 0.986）；白天验证段 +115 / −124（准确率 94.6%，AUC 0.997）；COCO 验证 70.0%（较第一轮 69.4% 未下降）**。

---

## 1. 数据与划分

| 来源 | 用途 | 数量 | 说明 |
|---|---|---|---|
| COCO（vww96_board） | 训练主体 | 14,000 | 板上预处理口径（crop1 + 3×3×2×2 采样 + 1%/99% 拉伸） |
| v29_scene D+E 段 | 训练 | 105 | `evidence/v29_scene/log_v29_scene.log` 解码，uint8(u) 原样 |
| v29_scene F 段 | **验证（整段）** | 54（26 正/28 负） | 不参与训练 |
| 白天 `scene_labels_v29_day` 训练段（wall < 15:13:00） | 训练 | 104（76 正/28 负） | PNG = 像素 u 原样 |
| 白天 **验证段（wall ≥ 15:13:00）** | **验证（整段）** | 56（39 正/17 负） | 不参与训练 |
| scene_labels_existing（训练段） | 训练 | 339 | 旧场景 |
| COCO 验证 | 监控 | 3,000 | 每 epoch 同一子集 |

- 输入一律 **`x = (u − 128) / 127.5`**（对应固件 `INPUT_SUB128=1`）。
- 混合比例：COCO 14,000 + 场景 548×12（重复）= **32% 场景 / 68% COCO**。
- 强增强：水平翻转、亮度 ×0.55~1.35、对比度 ×0.75~1.25、±9 px 平移、缩放 0.85~1.15。
- 训练 12 epoch，按「两验证集中位分离 + AUC + COCO 准确率」综合选优（最佳 epoch 8）。

## 2. 评估结果（INT8 量化后，板上口径 `u → (int8)(u−128)`）

| 数据集 | n | 有人中位 q | 无人中位 q | 无人最高 q | 阈值 0 准确率 | AUC |
|---|---|---|---|---|---|---|
| **v29_scene F（整段验证）** | 54 | **+101** | **−105** | +95 | **98.1%** | **0.986** |
| **白天验证段（wall≥15:13）** | 56 | **+115** | **−124** | −58 | **94.6%** | **0.997** |
| COCO 验证 | 3,000 | +41 | −38 | +118 | **70.0%** | 0.775 |

- 目标「两个验证集有人中位 > +30、无人中位 < −30」**均达成**（+101/−105、+115/−124）。
- COCO 较第一轮 69.4% **+0.6 个点**（要求"下降不超过 3 点"，实际未下降）。
- 第一轮遗留问题（白天有人中位仅 −7、阈值 0 只认 47%）已解决：白天有人中位从 −7 → **+115**。

> 说明：白天数据的 AUC 在第一轮就是 0.992（排序没问题），阈值 0 失效纯粹是**分数整体偏负**；本轮微调把"有人"整体推到正值，排序基本保持（AUC 0.992→0.997）。

## 3. 量化与加速器

- 量化：`quantize_v29.py`（代表数据集 = COCO 板上口径 500 张），输入 INT8 `scale=1/127.5, zp=−1`，输出 INT8 `scale=1/256, zp=−128`（与第一轮/旧模型一致）。
- 模型 101,088 B，95,922 参数（≤100K）。
- 官方 TinyML Generator 重跑：**`defines.v` 与第一轮逐字节一致**（AXI_DW=128 / CONV_DEPTHW_MODE=LITE / LITE_PARALLEL=4 / LITE_AW=7 / FC_MODE=DISABLE / CACHE=512）⇒ 现位流加速器可直接跑，无需改 RTL。
- 兼容性分析见 `accel_compat.md`（第一轮结论不变）。

## 4. 版本目录

| 目录/文件 | 内容 |
|---|---|
| 根目录 `v29_person_96_int8.tflite` | **本轮（第二轮）成品** |
| 根目录 `eval_day.json` | 本轮三数据集评估 |
| 根目录 `mix_result.json` | 本轮训练历史（12 epoch 逐轮指标） |
| 根目录 `generator/` | 本轮 Generator 产物（defines.v / model_data.cc 等） |
| `_round1/` | 第一轮（v29_scene 日志解码 + 微调）的 tflite / eval_log.json / scene_mix_result.json / generator |
| `_pre_finetune/` | COCO 训练、未做场景微调的版本（COCO val 71.3%） |
| `_bad_export/` | 基于 PNG（u+128 显示转换）重建的作废微调版本 |

## 5. 复现

```powershell
# 第二轮混合微调（白天数据）
python tools/mix_scene_day.py --model out/cal2/v29_scene_best.keras ^
  --coco data/vww96_board --log evidence/v29_scene/log_v29_scene.log ^
  --labels comms/scene_labels_v29/labels_v29_scene.csv ^
  --day-labels comms/scene_labels_v29_day/labels_v29_day.csv ^
  --scene-old data/scene --out out/day1 --epochs 12 --lr 1.5e-4
# 量化
python tools/quantize_v29.py --model out/day1/v29_day_best.keras --data data/vww96_board --out out/day1/quant --input-type int8
# 评估（F 段 + 白天验证 + COCO）
python tools/eval_day.py --tflite out/day1/quant/v29_person_96_int8.tflite ^
  --log evidence/v29_scene/log_v29_scene.log ^
  --labels comms/scene_labels_v29/labels_v29_scene.csv ^
  --day-labels comms/scene_labels_v29_day/labels_v29_day.csv ^
  --coco data/vww96_board --out out/day1/eval/eval_day.json
# Generator
python tools/gen_tinyml.py out/day1/quant/v29_person_96_int8.tflite out/day1/gen
```

## 6. 未完成 / 风险

- **未烧板**：模型指标为离线（与板上推理同口径 int8），上板表现仍需实测确认。
- 白天数据仅 171 帧（训练 104 / 验证 56），样本量小；若继续采集，建议保持同一划分策略（按 wall 整段）。
- 场景训练集里"有人"占比 46%，与 COCO 均衡；但 v29_scene D+E 段有人占 92%，样本不均衡已由重复采样与增强缓解。
- 第一轮旧模型 `_round1/` 保留可回退。
