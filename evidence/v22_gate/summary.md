# v22 入侵→报警关口实测记录

只记录采集事实与数字；硬件和检测效果的评估由操作者进行。

## 记录范围

- 原始日志：`log_v22_gate.log`，392 行。
- MMT_DEC：51 行，设备时钟分段：1 段。
- 分段 1：device_ms 120999–149889；墙钟 2026-10-26T07:39:30.626+08:00–2026-10-26T07:39:59.519+08:00。
- 无时区墙钟按 Asia/Shanghai（UTC+08:00）解释。

## 固件与本次采集

| 项 | 记录 |
|---|---|
| 固件 | `tinyml_pdti8_v19_dump.bin` |
| 固件字节数 | `477722` |
| 固件 CRC32 | `9410DBEF` |
| 固件 SHA256 | `8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3` |
| 位流 | `v7_MERGE14.bit` |
| 位流 SHA256 | `E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8` |
| 串口 | `COM15` |
| 波特率 | `115200` |
| 模式 | `boot_only` |
| 采集开始 | `2026-10-26T07:37:16.925+08:00` |
| 观察开始 | `2026-10-26T07:39:29.938+08:00` |
| 观察结束 | `2026-10-26T07:39:59.943+08:00` |
| 采集结束 | `2026-10-26T07:40:00.130+08:00` |
| 修改固件 | `否` |
| 修改曝光 | `否` |
| 发送相机命令 | `否` |
| 上传后复位 | `否` |

采集过程异常记录：`RuntimeError('No MMT_CAM boot lines captured')`。

该异常由采集器的前导 CR 匹配问题触发；离线保留原始 LF/CR 重新解析后，日志内已找到下列 MMT_CAM 原始行。

## 操作尝试记录

| 轮次 | 开始墙钟 | 结束墙钟 | 固件上传完成 | 异常记录 |
|---:|---|---|---|---|
| 1 | 2026-10-26T07:33:32.295+08:00 | 2026-10-26T07:33:33.481+08:00 | 未记录完成 | RuntimeError('JTAG script exit=1; see flash_attempt_1.log') |
| 2 | 2026-10-26T07:33:35.482+08:00 | 2026-10-26T07:33:36.608+08:00 | 未记录完成 | RuntimeError('JTAG script exit=1; see flash_attempt_2.log') |
| 3 | 2026-10-26T07:33:38.610+08:00 | 2026-10-26T07:33:39.746+08:00 | 未记录完成 | RuntimeError('JTAG script exit=1; see flash_attempt_3.log') |
| 4 | 2026-10-26T07:37:17.325+08:00 | 2026-10-26T07:39:29.938+08:00 | 是 |  |

## 动作流程记录

用户暂缓六轮真人实测；本次仅采集上板启动后的观察数据，未执行 ENTER/LEAVE 动作流程。
`script_events.csv` 仅有表头，对应本次未执行的动作事件。

## 开机与相机原始行

```text
session=0 wall=2026-10-26T07:37:29.613+08:00 MMT_BOOT ONCHIP_UART DDR3_WAIT
session=1 wall=2026-10-26T07:39:29.937+08:00 MMT_LIVE_BOOT v19 CROP=1 NORM=0 STRETCH=1 AE=0 LPCAM=0 FW_DEC=1 LOWPOWER=1
session=1 wall=2026-10-26T07:39:29.954+08:00 MMT_CFG v19 CROP_MODE=1 NORM_ON=0 STRETCH_ON=1 AUTOEXP_ON=0 LP_CAMFPS_ON=0 LP_VTS_MULT=3 FW_DECISION_ON=1 LOWPOWER_ON=1 INPUT_SUB128=0 AI_P_TH=0 AI_VOTE=2/3 AREA=[200,4000] DEC_CAND=6
session=1 wall=2026-10-26T07:39:30.114+08:00 MMT_CAM_VTS ok=1 vts=0x0x5dc rom_vts=0 fallback=1
```

- MMT_LIVE_BOOT 前缀行数：1。
- MMT_CAM 前缀行数：1。
- MMT_CAM 原始行没有输出 exp/gain 读回字段；本次没有这些读回值。

## MMT_ALARM 区间（设备 ms）

日志中无 MMT_ALARM 行。

## 低功耗进入 / 唤醒（设备 ms）

| 分段 | 事件 | device_ms | 墙钟 |
|---|---|---:|---|
| 1 | enter | 130759 | 2026-10-26T07:39:40.385+08:00 |

## mean_sensor 每 60 秒中位数

按分段及设备时钟区间 [start_ms, end_ms) 统计；MMT_PP 通过同帧 f 对齐 MMT_DEC，不沿用上一帧时间。无样本区间留空。

| 分段 | start_ms | end_ms | 样本数 | mean_sensor 中位数 |
|---|---:|---:|---:|---:|
| 1 | 120000 | 180000 | 13 | 41 |

## 采集计数与字段来源

| 项 | 数量 |
|---|---:|
| GAP 行 | 3 |
| 串口重连成功（### RECONNECTED） | 0 |
| 串口断开/重连发起标记（含 ### RECONNECT_TRY） | 0 |
| 完整 96×96 图组 | 2 |
| 未完成图组（有 IMGSTAT） | 0 |
| contact sheet 页数 | 1 |
| ENTER / LEAVE 事件 | 0 |
| 无同帧 DEC 的 MMT_PP | 0 |
| alarm_req=1 的 DEC | 0 |
| person=1 的 DEC | 0 |

- ticks.csv 的 alarm 来自 MMT_DEC.alarm_req；不是从 RTL 报警位推断。
- p 来自同分段同帧 MMT_OSD.p / MMT_AI.p；lp 表示固件休眠状态，优先来自同帧 MMT_LP.fw_lp，缺失时使用同帧 lowpwr 或已记录状态，缺失值留空。
- script_events.csv 在全部带墙钟的 MMT_DEC 中选绝对时间差最小的一条，允许位于动作前或后；delta_ms = DEC墙钟 − 动作墙钟。
- contact sheet 每页最多 40 张，只使用收齐 96 行的原始图像，并以同帧 DEC 标注 device_ms。
- 灯光只以本记录的 mean_sensor 中位数表呈现。
