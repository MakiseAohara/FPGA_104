# 加速器兼容性对比（v29 新模型 vs 现位流）

- 新模型：`v29_person_96_int8.tflite`（95,922 参数，全整数 INT8）
- 现位流：`D:\v7work\v7_MERGE14`（板上 MERGE15/MERGE14 使用的 TinyML 加速器配置）
- 工具：官方 TinyML Generator（PyQt6 headless）+ 内置 `bin/tflite.exe`

## 1. 新模型的算子清单（官方 `tflite.exe` 逐层报告）

```
input type: 9, shape: 1x96x96x1        (INT8)
CONV_2D:3      (conv1, 16ch, s2)
CONV_2D:3      (conv2, 32ch, s2)
CONV_2D:3      (conv3, 48ch, s2)
CONV_2D:3      (conv4, 64ch, s2)
CONV_2D:3      (conv5, 80ch, s2)
MEAN:3         (GlobalAveragePooling)
FULLY_CONNECTED:3  (fc1, 80→32)
FULLY_CONNECTED:3  (fc2, 32→2)
SOFTMAX:3
output(0) size: 2, type: 9
```

`conv_depthw_mode:1`（LITE）、`fc_mode:1`（分析器建议 FC 用硬件，见 §4）。

## 2. 生成的 `defines.v` 与现位流 `tinyml_core0_define.v` 逐项对比

| 宏 | 新模型（Generator 生成） | 现位流（`source/tinyml/tinyml_core0_define.v`） | 是否影响 |
|---|---|---|---|
| `AXI_DW` | 128 | 128 | 一致 |
| `CONV_DEPTHW_MODE` | `"LITE"` | `"LITE"` | **一致（关键）** |
| `CONV_DEPTHW_LITE_PARALLEL` | 4 | 4 | **一致（关键）** |
| `CONV_DEPTHW_LITE_AW` | 7 | 7 | **一致（关键）** |
| `CONV_DEPTHW_STD_IN_PARALLEL` | 8 | 4 | 不同，但 LITE 模式不使用 |
| `CONV_DEPTHW_STD_OUT_PARALLEL` | 4 | 1 | 同上 |
| `CONV_DEPTHW_STD_OUT_CH_FIFO_A` | 80 | 1404 | 同上 |
| `CONV_DEPTHW_STD_FILTER_FIFO_A` | 72 | 750 | 同上 |
| `CONV_DEPTHW_STD_CNT_DTH` | 96 | 1404 | 同上 |
| `FC_MODE` | `"DISABLE"`（已按板上 RTL 强制） | `"DISABLE"` | **一致（关键）** |
| `FC_MAX_IN_NODE/OUT_NODE` | 640/640 | 640/640 | 一致 |
| `ADD/MUL/MIN_MAX/LR/RS_MODE` | DISABLE | DISABLE | 一致 |
| `TINYML_CACHE` | `"ENABLE"` | `"ENABLE"` | 一致 |
| `CACHE_DEPTH` | 512 | 512 | 一致 |

> 生成器默认会把有 Dense 层的模型设成 `FC_MODE="STANDARD"`；本工程按现位流 RTL（FC=DISABLE）**强制改回 DISABLE** 后再生成，保证软件端 `define.cc` 的 `fc_mode=0` 与 RTL 一致。

## 3. 结论：现位流加速器**可以直接跑**新模型

1. 新模型的 5 个卷积全部是**普通 `CONV_2D`**（无 depthwise），现位流的 `CONV_DEPTHW_MODE="LITE"` 正是为此配置，且 LITE 的并行参数（4 / AW=7）与生成值逐项一致 ⇒ 卷积层无需改 RTL。
2. `MEAN`（GAP）、`FULLY_CONNECTED`×2、`SOFTMAX` 在现位流里 `FC_MODE="DISABLE"` ⇒ 这些层由 RISC-V 上的 TFLite Micro **软件执行**。新模型这三个层共 2,658 个参数、算力可忽略，软件执行不会成为瓶颈。
3. `defines.v` 与 `define.cc` 的其余项（AXI 128、CACHE 512、ADD/MUL/MINMAX 全 DISABLE）与现位流一致 ⇒ **不需要重新综合 `tinyml_accelerator`**。

## 4. 如果要用 FC 硬件加速（可选，非必需）

Generator 报告 `fc_mode:1`，即 FC 可以走硬件。若要让 FC 上加速器：

1. RTL：`source/tinyml/tinyml_core0_define.v` 改
   - `TML_C0_FC_MODE` `"DISABLE"` → `"STANDARD"`
   - `TML_C0_FC_MAX_IN_NODE` / `TML_C0_FC_MAX_OUT_NODE` 按 Generator 报告的 `fc_max_in_node`（80）设置（现为 640）
2. 需要**重新综合** `tinyml_accelerator.v`（参数变化会改变 RTL 结构），并重跑 PnR/时序。
3. 收益：`fc1`(80×32) + `fc2`(32×2) 约 2.6K MAC，软件执行本来就 <1 ms，**收益可忽略**；不建议为此改 RTL。

## 5. 遗留风险（如实记录）

- `tflite.exe` 的 `:3` 是"模式支持等级"，本工程按 `conv_depthw_mode:1`（LITE）验证过生成通过；但**未在板上实跑新模型**（本次只做离线训练/量化/生成，未烧录）。
- 新模型的输入量化参数（INT8, scale=1/127.5, zp=-1）与旧模型完全一致，配合固件 `INPUT_SUB128=1`（像素减 128）时语义正确；若固件仍是 `INPUT_SUB128=0`，输入会亮度折叠，精度显著下降（已在旧模型上实测：55% vs 71%）。
