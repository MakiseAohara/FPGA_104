# NUMBERS_SOURCE — 技术文档关键数字出处

> 每个数字给出仓库内相对路径 + 行号或字段。找不到出处的列入文末「待核对」，不猜测。

## 1 定版固件

| 数字 | 出处 | 位置/字段 |
|---|---|---|
| CRC32 `C15D47FD` | `submission/firmware/v29_2/FINAL.md` | 「固件」表中 CRC32 行 |
| 306,194 B | 同上 | 同上「大小」行 |
| SHA256 `D7938F05A12F9B986110E731B2E2D03BD7020679014619AB2E5055FF5FA307D9` | 同上 | 「SHA256」行 |
| `AUTOEXP_ON=0` / `GAIN_AUTO_ON=1` | `submission/firmware/v29_2/main_live292.cc` | L68 / L637 |
| `GA_TARGET=100` / `GA_GMAX=8176` | 同上 | L639 / L644 |
| WB `0x158/0x118/0x1A4` | 同上 | L911 / L914 / L917 |
| `LP_CAMFPS_ON=1`、`LP_VTS_MULT=3`、`LP_ENTER_MS=10000` | 同上 | L71 / L91 / L117 |

## 2 定版位流（MERGE17）

| 数字 | 出处 | 位置/字段 |
|---|---|---|
| SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF` | `submission/rtl/merge17/README.md` | 「位流」行；亦见 `submission/firmware/v29_2/FINAL.md`「板上位流」表 |
| 2,845,704 B | 同上 | 同上 |
| XLR 42,857 / 60,800（70.49%） | `submission/rtl/merge17/place.rpt` | `XLRs: 42857 / 60800 (70.49%)` |
| BRAM 189 / 256（73.83%） | 同上 | `Memory Blocks: 189 / 256 (73.83%)` |
| DSP 67 / 160（41.88%） | 同上 | `DSP Blocks: 67 / 160 (41.88%)` |
| 最差 setup −0.984 ns | `submission/rtl/merge17/timing_final.rpt` | L79 `hdmi_tx_slow_clk core_clk … -0.984`；L128 `Slack : -0.984` |
| hold 违例 7 条 | 同上 | `may not meet (slack: -… ns) the hold (min) timing requirement` 共 7 条 |
| MERGE16 setup −1.020 ns | `submission/rtl/merge16/timing_final.rpt` | 同格式 |

## 3 模型

| 数字 | 出处 | 位置/字段 |
|---|---|---|
| 95,922 参数 | `submission/model/v29_model/README.md` | L1、L4 |
| 101,088 B（tflite） | 同上 | L42 |
| 单次推理 226 ms | `evidence/v29_gate/README.md` | L22（Invoke 前后 CLINT 差值，n=600/522） |
| 场景 F 段 98.1%（n=54） | `submission/model/v29_model/README.md` | L29 表行 |
| 白天段 94.6%（n=56） | 同上 | L30 表行 |
| COCO 70.0%（n=3000） | 同上 | L31 表行 |
| AUC 0.986 / 0.997 / 0.775 | 同上 | L29/L30/L31 同表 AUC 列 |

## 4 采集与判决

| 数字 | 出处 | 位置/字段 |
|---|---|---|
| proto7 空场景约 152 秒 0 次报警 | `submission/data/proto7/report.md` | 阶段 0/1/6 统计（alarm start 合计） |
| proto7 站定 4 次 / 慢走 1 次触发 | 同上 | 阶段 4 / 阶段 5 的 `ALARM start` 列 |
| 离开后 4–7 s 解除 | 同上 | 阶段 5→6 边界与 `MMT_ALARM end` |
| 触发延迟中位 1.99 s / 1.48 s | `submission/data/proto7/report.md` + `submission/data/mot_offline`（`align_eval.py` 输出） | 由 `MMT_ALARM start` 与运动首次出现之差复算 |
| empty30 触发 21 次（9/11/1） | `submission/data/empty30/README.md`、`serial.log` | `MMT_ALARM start` 计数 + 人工归类 |
| lp7 低功耗 17.0 s 进入 | `submission/data/lp7/report.md` | 「低功耗时序」表 A 列 `fw_lp=1` |
| lp7 `MMT_LPCAM enter` @24.6 s（VTS 0x5dc→0x1194） | 同上 | 同上 + 事件列表 |
| long30 低功耗 21 次进入/恢复 | `submission/data/long30/README.md`、`serial.log` | `MMT_LP_ENTER` 21 条 |
| long30 30 对区间 / 707 s / 中位 15.4 s / 最长 97.8 s / 冻结 61.4% | **仓库外** `log_lp2.txt`（本机 `D:\FPGA\mmt\log_lp2.txt`） | 全文 5 行汇总；**仓库内无对应文件** |
| 亮度 mean 69–97（中位 75） | `submission/data/lp7/report.md`、`submission/data/empty30/serial.log` | `mean_sensor` 统计 |

## 5 MOT（v30）

| 数字 | 出处 | 位置/字段 |
|---|---|---|
| 下一帧误差 3.87 / 23.41 px（n=534） | `submission/data/mot_offline/pred_eval_A-E.txt` | 第 2 行 |
| 2 帧误差 7.28 / 27.46 px（n=485） | 同上 | 第 3 行 |
| ROI 47 进 6 中、提前量 250 ms、误预警 2 | 同上 | 第 4–6 行 |
| `fw_v30_final.bin` 318,322 B / `E6535D37` | `submission/firmware/v30_mot/fw_v30_final.bin` | 实测（本轮计算） |

---

## 待核对（仓库内找不到出处，需补或改口径）

| # | 数字/说法 | 情况 |
|---|---|---|
| 1 | long30 的「30 对区间 / 累计 707 s / 中位 15.4 s / 最长 97.8 s / 推理冻结 61.4%」 | 只有仓库外 `log_lp2.txt` 汇总，仓库内无原始复算脚本与文件 |
| 2 | 「低功耗 17 s 进入」是否可复现为定版固件口径 | 来自 `lp7/report.md`（定版固件 A 段），需确认 `fw_lp` 与 `MMT_LPCAM enter` 的口径差异（17.0 s vs 24.6 s） |
| 3 | empty30 的「9 真人 / 11 红外强确认 / 1 未归类」 | 人工归类结论，仓库内无逐条标注明细 |
| 4 | 模型自身 SHA256（用于核验定版固件所装模型） | `v29_model/README.md` 只给大小与参数量，无模型哈希 |
| 5 | 226 ms/invoke 的样本数与日期 | `evidence/v29_gate/README.md` L22 有值，样本来源日志名称需再核 |
