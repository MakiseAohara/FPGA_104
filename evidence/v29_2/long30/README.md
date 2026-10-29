# v29.2 DAY 固件 + 30 分钟自由采集（WB = 0x158/0x118/0x1A4，GAIN_AUTO 闭环，旧 AE 关闭）

## 1. 本轮固件（修正上一轮的 AUTOEXP 误编）

| 项 | 值 |
|---|---|
| 文件 | `tinyml_pdti8_v292_day.bin` |
| 大小 | **306,242 B** |
| **CRC32** | **3D334E58** |
| SHA256 | `611D5BBF5BAF0B23897C89AC51ACF3FA9E5CEE1DF5C10A35E8175F7CF060607F` |
| 模型 | v29 第二轮 `v29_person_96_int8.tflite`（101,088 B） |

`main_live292.cc` 关键宏：

| 宏 | 值 | 说明 |
|---|---|---|
| `AUTOEXP_ON` | **0** | 旧 AE 关闭（上一轮误开，导致 0x802a→0x8f8c 过曝） |
| `GAIN_AUTO_ON` | **1** | v29.2 新亮度闭环（只调总增益，目标 `GA_TARGET=100`，单步 0.7~1.4×，±15% 死区，空场才调） |
| `WB_R` / `WB_G` / `WB_B` | 0x158 / 0x118 / **0x1A4** | 白平衡 |
| 其余 | 不动 | `LP_CAMFPS_ON=1`、`IR_SOLO_ON=1`、`INPUT_SUB128=1` 等 |

构建：`python build_v292.py DAY` → **FIRMWARE BUILD PASS**；`python check_v292.py` → **SELFCHECK PASS**。
固件内字符串核对：`MMT_GAIN` ✓、`MMT_GAIN_ERR` ✓、**`MMT_AE` ✗（不存在，旧 AE 已剔除）**。

## 2. 加载后串口确认（原样）

```
MMT_LIVE_BOOT v29.2 CROP=1 NORM=0 STRETCH=1 AE=0 LPCAM=1 FW_DEC=1 LOWPOWER=1
MMT_WB_INIT r=344 g=280 b=420 cal=0
MMT_GAIN g=1836->2567 gc=0x00000087 gf=0x00000028 mean=48 target=100
MMT_GAIN g=3589->4542 gc=0x0000008f gf=0x00000023 mean=79 target=100
```

- `AE=0` ✓（旧自动曝光未参与）
- `r=344=0x158`、`g=280=0x118`、`b=420=0x1A4` ✓
- 采集中 **`MMT_AE` 出现 0 次、`MMT_GAIN_ERR` 0 次**（与上一轮形成对比）

## 3. 30 分钟自由采集（17:33:10 → 18:03:10，1800.3 s）

| 项 | 值 |
|---|---|
| `serial.log` | **5,896,605 B** |
| 缩略图 | **807 张 48×48 PNG**（`thumbs/`，`MMT_THUMB` 4608 hex 字节原样） |
| 报警帧 | 32 |
| `MMT_GAIN` 调整次数 | **1 次**（增益落到 4542 后稳定，不再抖动） |
| `MMT_GAIN_ERR` / `MMT_AE` | 0 / 0 |

### 亮度（对比上一轮过曝）

| 轮次 | 固件 | n | min | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|---|
| 上一轮（旧 AE，已作废） | CRC 7CD244BA | 925 | 24 | 86 | 209 | 237 | 131.1 |
| **本轮（GAIN_AUTO）** | **CRC 3D334E58** | **1246** | **53** | **80** | **81** | 218 | **79.9** |

- 本轮亮度 **p50=80、p90=81**，贴近目标 100，**不再出现上一轮 >150 的过曝聚集**（p90 从 209 降到 81）。
- 采集期间未改任何参数。

## 4. 目录

```
evidence/v29_2/long30/
├── tinyml_pdti8_v292_day.bin   306,242 B  CRC32 3D334E58（本轮）
├── tinyml_pdti8_v292_day.elf
├── day_build.log / link.log / size.txt / elf-info.txt
├── firmware_identities_v292.json / selfcheck_v292.json
├── serial.log                  5,896,605 B（30 分钟，本轮）
├── thumbs/                     807 × 48×48 PNG（本轮）
├── thumbs_manifest.json        缩略图/亮度统计（本轮）
├── boot_v292_b0x1A4.log        上电/加载启动日志（AE=0、WB_INIT、GAIN）
├── serial_v292_ae1_overexposed.log  上一轮（旧 AE 过曝）完整 30 分钟日志，保留对照
├── serial_b0x1C4_aborted.log   更早（B=0x1C4）被中止的短采集
└── README.md
```

## 5. 环境适配（仅路径，不改逻辑）

- `PROJECT` → 本机可构建副本 `D:\v7work\tiny_proj`。
- `WORK` → `D:\v292_build`（避开中文路径导致的 ld 写 elf 失败）。
- 加载：`flash_vendor.ps1` 烧 MERGE17（复位到 loader）→ UART `MMTL` 上传 306,242 B → `MMT_LIVE_BOOT`。
