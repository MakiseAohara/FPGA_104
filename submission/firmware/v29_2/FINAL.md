# FINAL —— v29.2 DAY 定版固件（板子上正在跑的这一版）

本目录的 `main_live292.cc` 就是**编译出板子上当前运行固件**的那份源码（不是早前放入的另一份）。

## 固件

| 项 | 值 |
|---|---|
| 文件 | `tinyml_pdti8_v292_day.bin` |
| 大小 | 306,194 B |
| **CRC32** | **C15D47FD** |
| SHA256 | `D7938F05A12F9B986110E731B2E2D03BD7020679014619AB2E5055FF5FA307D9` |
| 模型 | v29 第二轮 `v29_person_96_int8.tflite`（101,088 B，95,922 参数） |

## 关键宏（最终取值）

| 宏 | 值 | 说明 |
|---|---|---|
| `WB_R` / `WB_G` / `WB_B` | **0x158 / 0x118 / 0x1A4** | 白平衡（1.344× / 1.094× / 1.640625×） |
| `AUTOEXP_ON` | **0** | 旧自动曝光关闭 |
| `GAIN_AUTO_ON` | **1** | 新亮度闭环开启 |
| `GA_TARGET` | **100** | 亮度闭环目标（源码实际值；此前口述的 70 与源码不符，以本行为准） |
| `GA_GMAX` | **8176** | 总增益上限（16 × 1.99×） |
| `GA_GMIN` / `GA_BAND` / `GA_NEED` / `GA_HOLD` | 256 / 15% / 2 / 1 | 下限、死区、确认帧数、保持 |
| `IR_SOLO_ON` / `IR_SOLO_N` | 1 / 6 | 红外单模态直通 |
| `REL_QUIET_FRAMES` | **6** | v29.3 安静释放帧数 |
| `INPUT_SUB128` | 1 | 板上输入 u−128 |
| 相机 | VTS=1500、EXP20=47824、GC=129、GF=42 | DAY 预设 |

三处决策改动（相对 v29.2 基线）：
1. `static int quiet_cnt = 0;` + `#define REL_QUIET_FRAMES 6`
2. 候选逻辑：`if (cand) { cand_left = DEC_CAND_FRAMES; quiet_cnt = 0; } else { if (cand_left > 0) cand_left--; if (quiet_cnt < 1000) quiet_cnt++; }`
3. fusion 红外确认：`((ir_cnt10 >= IR_NEED) || (ai_p_now >= AI_P_STRONG && ir_cnt10 >= 1))`；解除：`(ir_cnt15 == 0 || quiet_cnt >= REL_QUIET_FRAMES)`

## 板上位流

| 项 | 值 |
|---|---|
| 文件 | `v7_MERGE17.bit`（仓库 `evidence/v29_rtl_ir_rot/`） |
| 大小 | **2,845,704 B** |
| SHA256 | **3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF** |

## 提交

- 定版提交信息：`v29.2 DAY final + proto7/empty30 evidence`
- 提交号：`git log --oneline --grep="v29.2 DAY final" -1`（本文件与该提交同批推送）

## 验证记录

- `build_v292.py DAY` → FIRMWARE BUILD PASS
- `check_v292.py` → SELFCHECK PASS
- 加载后串口：`MMT_LIVE_BOOT ... AE=0 ...`、`MMT_WB_INIT r=344 g=280 b=420 cal=0`
- 采集证据：`evidence/v29_3/proto7/`（7 阶段带标签）、`evidence/v29_3/empty30/`（30 分钟空场）
