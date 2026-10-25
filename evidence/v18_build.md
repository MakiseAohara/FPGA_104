# 固件 v18 构建与决策说明（运动触发 + AI 确认；⑤ 参数来自回放）

> 基线：`main_live17.cc`（v17）。新文件：`main_live18.cc`；宏默认值见下。
> 性质：**只编译、未上板**；位流配套 MERGE14。

## 1. 参数（A 回放结论）

| 宏 | 值 | 依据 |
|---|---|---|
| `AI_P_TH` | **−40** | 回放：−86 可 walk 5/5 但 quiet 必误报 1 次；−40 时 quiet 0 误报、walk 4/5 |
| `AI_VOTE_N` / `AI_VOTE_K` | 4 / **1** | 4 帧中 1 真；2/4 只触发 2/5 |
| `AI_AREA_MIN` / `AI_AREA_MAX` | 200 / **4000** | 抑制 quiet 段 9.3–13.7 s 的全局亮变类大 motion（area 5.5k–14.2k） |
| `DEC_CAND_FRAMES` | 8 | 运动触发后的候选窗口（×0.53 s ≈ 4.2 s） |
| `DEC_RELEASE_FRAMES` | 3 | 连续无 motion 且无 AI → 解除（实测 1.66–1.67 s） |
| `LP_ENTER_MS` | **10000** | quiet 最后一次 motion 在 13.7 s，10 s 后进入（约 23.7 s），留 3.7 s 余量 |
| 唤醒 | **motion** | AI 需推理才有结果，不能作唯一唤醒源；RTL `low_pwr` 保留为附加进入条件 |

**回放结果（`log_merge12_v17.log`，458 帧）**：R3 规则 quiet **0/201 帧误报**、walk **4/5**、解除 **1.67 s**、延迟 2.9–6.3 s。**"quiet 0 + walk 5/5 + 延迟 ≤1 s"三者不可同时满足**（WALK 2/5 首个合格 AI 样本在 2.9/4.1 s 后，WALK 3 在 6.3 s 后；−86 可 5/5 但 quiet 必误报）。详见 `evidence/v18_decision_replay.md`。

## 2. 决策逻辑（不再用融合 score）

```
每帧读 word11: motion/area/ir_hot、word12 环境、word13 low_pwr
motion && 200<=area<=4000 → cand_left = 8（运动触发候选）
每帧 AI 推理 → p；vote = 最近 4 帧中 p>=AI_P_TH 的帧数 >= 1
if (!alarm && cand_left>0 && vote) → 报警锁定，MMT_ALARM start（ms/f/person/motion/area）
if (alarm && !motion && !vote) → rel_cnt++；>=3 → MMT_ALARM end（ms/f/dur_ms）
low_pwr → 强制解除并记 reason=lowpwr
evt: 1=INTRUDE(报警) 2=TREND(不再使用) 3=PERSON 4=LOWPWR 0=NORMAL
word14 = alarm | conf<<8 | evt<<16；word15 使能固件门控（warmup 后）
```

## 3. ⑤ 低功耗（v18 独立计时）

- 连续 **10 s** 无 motion 且无 AI person → `fw_lp=1`：暂停推理、每 500 ms 轮询 word11/12/13；motion 到来立即 `fw_lp=0` 并恢复推理；RTL `low_pwr`（若置位）也作为进入条件。
- 日志：`MMT_LP_ENTER f=… cnt=… ms=… fw_lp=… rtl_lp=…`；`MMT_LP` 行含 `lowpwr/fw_lp/paused/camfps/inf_hz/...`；`MMT_LP_EXIT ... ms=...`。
- 回放推算：quiet 120 s 内进入前约 45 次推理、之后暂停 → 约 **0.37 次/s**，激活态约 **1.9 次/s**（≈20%）；上板时用 `MMT_LP inf_hz` 核对。

## 4. 构建结果

| 项 | 值 |
|---|---|
| 源文件 | `sw/tinyml_live/main_live18.cc` |
| 镜像 | `sw/tinyml_live/v18/tinyml_pdti8_v18.bin` |
| 大小 | **469,506 B** |
| CRC32 | **`0162C4D2`** |
| SHA256 | **`DED655387670B7CE00144314969616712A4D0F9E6D24031FD08840425075C143`** |
| 日志标记 | `MMT_LIVE_BOOT v18`、`MMT_CFG v18`、`MMT_ALARM start/end`、`MMT_LP_ENTER`、`MMT_LP ... fw_lp=` |
| 编译 | `FIRMWARE BUILD PASS`（112 源文件） |
| 电脑端测试 | `test_preprocess` 9/9、`test_autoexp` 5/5、`test_camctrl` 11/11，**ALL HOST TESTS PASS** |

## 5. 未验证项

- 所有板上行为（quiet 零报警、walk 触发率、延迟、LP 进入时刻、推理率）**未上板**；v18 未烧录。
- 回放规则基于单次 MERGE12+v17 会话（且当时 irhot 恒真、白平衡已改），样本量小；换场景/光照需重采复核。
- 固件决策需位流合并（MERGE14 门控默认 AI only）才完整生效；单独灌 v18 到 MERGE13 位流仍会受 `ir_hot|ai_person` 门控影响。
