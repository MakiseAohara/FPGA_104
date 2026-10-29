# v29.2 DAY 固件 + 30 分钟自由采集（WB R/G/B = 0x158 / 0x118 / 0x1A4，自动亮度开）

## 1. 本轮固件

| 项 | 值 |
|---|---|
| 文件 | `tinyml_pdti8_v292_day.bin` |
| 大小 | **306,442 B** |
| **CRC32** | **7CD244BA** |
| SHA256 | `3BDC3B009279167DE623E56B1C68FA60E3B77676EB617469AB82A10B2BB93656` |
| 模型 | v29 第二轮 `v29_person_96_int8.tflite`（101,088 B） |
| 相机 | VTS=1500、EXP20=47824、GC=129、GF=42（DAY 预设） |

改动（`evidence/v29_fw/main_live292.cc`）：
- `WB_R=0x158`、`WB_G=0x118`、**`WB_B=0x1A4`**（只改 WB_B）
- **`AUTOEXP_ON=1`**（自动亮度；AE_TARGET_LO=95 / HI=125）
- 其余宏未动（`LP_CAMFPS_ON=1`、`IR_SOLO_ON=1`、`INPUT_SUB128=1` 等保持）

构建：`python build_v292.py DAY` → **FIRMWARE BUILD PASS**；`python check_v292.py` → **SELFCHECK PASS**。

## 2. 加载与串口确认（原样）

烧 MERGE17（`3A69AAFB…887CF`）→ `MMT_LOADER_READY` → UART 上传固件 →：

```
MMT_LIVE_BOOT v29.2 CROP=1 NORM=0 STRETCH=1 AE=1 LPCAM=1 FW_DEC=1 LOWPOWER=1
MMT_WB_INIT r=344 g=280 b=420 cal=0
```

`r=344=0x158`、`g=280=0x118`、`b=420=0x1A4` ✓ 三个值确认写入。

自动亮度（固件打印标签是 `MMT_AE`，**本固件里没有 `MMT_GAIN*` 字符串**；对应错误标签为 `MMT_AE_ERR`）最先几条：

```
MMT_AE mean=30 act=3 exp 0x0000ffff->0x0000ffff gain 0x0000802a->0x00008f8c
MMT_AE mean=209 act=2 exp 0x0000e146->0x0000c63d gain 0x00008f8c->0x00008f8c
MMT_AE mean=205 act=2 exp 0x0000c63d->0x0000bbf0 gain 0x00008f8c->0x00008f8c
MMT_AE mean=202 act=4 exp 0x0000bbf0->0x0000bbf0 gain 0x00008f8c->0x0000802a
MMT_AE mean=20  act=1 exp 0x0000bbf0->0x0000d27e gain 0x0000802a->0x0000802a
```

**`MMT_AE_ERR` 0 次、`MMT_BRIGHT_ERROR` 0 次。**

## 3. 30 分钟自由采集（16:46:09 → 17:16:09，1800 s）

| 项 | 值 |
|---|---|
| `serial.log` | **5,444,796 B**（30 分钟连续） |
| 缩略图 | **767 张 48×48 PNG**（`thumbs/`，来自 `MMT_THUMB` 4608 hex 字节原样） |
| 报警帧 | 148 |
| 启动日志 | `boot_v292_b0x1A4.log` |

### 亮度（自动亮度效果，采集中实测）

| 指标 | n | min | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|
| `MMT_AE mean` | 58 | 20 | **64** | 219 | 243 | 117.1 |
| `MMT_PP mean_in` | 925 | 24 | **86** | 209 | 237 | 131.1 |

- **中位亮度 64（AE 口径）/ 86（PP 口径）**，高于 60 的告警线但偏低；AE 在 20~243 之间明显振荡（场景明暗交替时 ±12% 步长偏大）。
- 按约定**没有自行改 AE 参数**，仅记录上报。

## 4. 目录

```
evidence/v29_2/long30/
├── tinyml_pdti8_v292_day.bin   306,442 B  CRC32 7CD244BA
├── tinyml_pdti8_v292_day.elf
├── day_build.log / link.log / size.txt / elf-info.txt
├── firmware_identities_v292.json / selfcheck_v292.json
├── serial.log                  5,444,796 B（30 分钟）
├── thumbs/                     767 × 48×48 PNG
├── thumbs_manifest.json        缩略图/亮度统计
├── boot_v292_b0x1A4.log        上电/加载启动日志（含 MMT_WB_INIT）
├── serial_b0x1C4_aborted.log   上一版（B=0x1C4）被中止的短采集，留作对照
└── README.md
```

## 5. 环境适配（仅路径，不改逻辑）

- `build_v292.py` 的 `PROJECT` 指向本机可构建副本 `D:\v7work\tiny_proj`（`D:\FPGA\codex20` 不存在、`D:\FPGA\tinyml` 缺 bsp）。
- `WORK` 指向 **`D:\v292_build`**（原路径含中文导致 riscv `ld.exe` 写 elf 失败）。
- 加载流程：`flash_vendor.ps1` 烧 MERGE17 → 等 `MMT_LOADER_READY` → UART `MMTL` 协议上传 306,442 B → `MMT_LIVE_BOOT`。
