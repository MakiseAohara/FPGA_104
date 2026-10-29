# v29.3 决策修改 + 30 分钟空场景采集（empty30）

## 固件（决策三处修改版）
- 文件 `tinyml_pdti8_v292_day.bin`，**306,194 B**，**CRC32 C15D47FD**
- `AUTOEXP_ON=0`、`GAIN_AUTO_ON=1`（目标/上限不变）、WB **R=0x158 G=0x118 B=0x1A4**
- 修改点（`main_live292.cc`）：
  1. `static int quiet_cnt = 0;`（L392）+ `#define REL_QUIET_FRAMES 6`（L111）
  2. `dec_update` 候选逻辑：`if (cand) { cand_left = DEC_CAND_FRAMES; quiet_cnt = 0; } else { if (cand_left > 0) cand_left--; if (quiet_cnt < 1000) quiet_cnt++; }`（L449-450）
  3. fusion：`((ir_cnt10 >= IR_NEED) || (ai_p_now >= AI_P_STRONG && ir_cnt10 >= 1))`（L455）；解除：`(ir_cnt15 == 0 || quiet_cnt >= REL_QUIET_FRAMES)`（L477）
- build `FIRMWARE BUILD PASS`；check `SELFCHECK PASS`

## 加载确认（原样）
```
MMT_LIVE_BOOT v29.2 CROP=1 NORM=0 STRETCH=1 AE=0 LPCAM=1 FW_DEC=1 LOWPOWER=1
MMT_WB_INIT r=344 g=280 b=420 cal=0
```

## 采集（空场景，无人值守）
- 开始（本机）：**2026-10-29 18:45:55.258**
- 结束（本机）：**2026-10-29 19:15:55.408**（1800.15 s）
- `serial.log`：**32,195 行**，每行前缀本机毫秒时间戳；9,780,928 B
- 缩略图：**1043 张 48×48 PNG**
- `MMT_ALARM start` / `MMT_ALARM end`：**21 / 21**；`MMT_AE`：0

## 文件
```
evidence/v29_3/empty30/
├── serial.log        32,195 行（毫秒时间戳）
├── manifest.json     开始/结束本机时间、行数、缩略图数
├── thumbs/           1043 × 48×48 PNG
├── tinyml_pdti8_v292_day.bin/.elf   306,194 B  CRC32 C15D47FD
├── day_build.log / selfcheck_v292.json / firmware_identities_v292.json
└── README.md
```
