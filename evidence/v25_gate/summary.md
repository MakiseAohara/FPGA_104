# v25 自由进出串口记录

只记录采集事实与数字；动作有效性与报警判定由 Claude / 操作者事后分析。

## 记录范围

- 原始日志：`log_v25_gate.log`，12231 行。
- MMT_DEC：876 行，设备时钟分段：1 段。
- 分段 1：device_ms 121019–720014；墙钟 2026-10-26T17:42:10.984+08:00–2026-10-26T17:52:09.974+08:00。
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
| 模式 | `free_movement_after_authorized_flash` |
| 本次加载阶段开始 | `2026-10-26T17:39:51.843+08:00` |
| 正式记录窗口开始 | `2026-10-26T17:42:10.297+08:00` |
| 正式记录窗口结束 | `2026-10-26T17:52:10.299+08:00` |
| 采集结束 | `2026-10-26T17:52:10.486+08:00` |
| 修改固件 | `否` |
| 修改曝光 | `否` |
| 发送相机命令 | `否` |
| 上传后复位 | `否` |
| 动作提示 | `否` |
| ENTER/LEAVE 标记 | `否` |

## 操作尝试记录

| 轮次 | 开始墙钟 | 结束墙钟 | 固件上传完成 | 异常记录 |
|---:|---|---|---|---|
| 1 | 2026-10-26T17:39:52.611+08:00 | 2026-10-26T17:42:10.297+08:00 | 是 |  |

## 动作流程记录

用户安排自由进出约六次，本次脚本不发动作提示、不写 ENTER/LEAVE 标记；不能从提示或运动帧数推断实际进出次数。
用户要求：开头空场至少 30 s，每次在画面内 10–20 s，进出之间空场至少 15 s，最后空场至少 60 s。各段动作未作独立标注。
MMT_ALARM 与低功耗事件按原始设备 ms 列出；不据此自动判断通过、失败或动作有效性。

## 开机与相机原始行

```text
session=0 wall=2026-10-26T17:40:09.938+08:00 MMT_BOOT ONCHIP_UART DDR3_WAIT
session=1 wall=2026-10-26T17:42:10.296+08:00 MMT_LIVE_BOOT v19 CROP=1 NORM=0 STRETCH=1 AE=0 LPCAM=0 FW_DEC=1 LOWPOWER=1
session=1 wall=2026-10-26T17:42:10.312+08:00 MMT_CFG v19 CROP_MODE=1 NORM_ON=0 STRETCH_ON=1 AUTOEXP_ON=0 LP_CAMFPS_ON=0 LP_VTS_MULT=3 FW_DECISION_ON=1 LOWPOWER_ON=1 INPUT_SUB128=0 AI_P_TH=0 AI_VOTE=2/3 AREA=[200,4000] DEC_CAND=6
session=1 wall=2026-10-26T17:42:10.472+08:00 MMT_CAM_VTS ok=1 vts=0x0x5dc rom_vts=0 fallback=1
```

- MMT_LIVE_BOOT 前缀行数：1。
- MMT_CAM 前缀行数：1。
- MMT_CAM 原始行没有输出 exp/gain 读回字段；本次没有这些读回值。

## MMT_ALARM 区间（设备 ms）

| 分段 | start_ms | end_ms | duration_ms | 记录 |
|---|---:|---:|---:|---|
| 1 | 166627 | 169794 | 3167 |  |
| 1 | 173082 | 174670 | 1588 |  |
| 1 | 179012 | 187046 | 8034 |  |
| 1 | 199945 | 204169 | 4224 |  |
| 1 | 209042 | 217079 | 8037 |  |
| 1 | 229456 | 237496 | 8040 |  |
| 1 | 239082 | 245013 | 5931 |  |
| 1 | 250413 | 253056 | 2643 |  |
| 1 | 263325 | 329295 | 65970 |  |
| 1 | 341142 | 346544 | 5402 |  |
| 1 | 349184 | 356167 | 6983 |  |
| 1 | 381966 | 383553 | 1587 |  |
| 1 | 390532 | 396988 | 6456 |  |
| 1 | 405548 | 413060 | 7512 |  |
| 1 | 437807 | 445317 | 7510 |  |
| 1 | 503544 | 513693 | 10149 |  |
| 1 | 522258 | 531476 | 9218 |  |
| 1 | 538986 | 547554 | 8568 |  |
| 1 | 573890 | 576535 | 2645 |  |
| 1 | 581938 | 631864 | 49926 |  |

全部 MMT_ALARM 原始事件：

```text
session=1 wall=2026-10-26T17:42:56.579+08:00 MMT_ALARM start ms=166627 f=64 person=1 motion=1 area=5986
session=1 wall=2026-10-26T17:42:59.732+08:00 MMT_ALARM end ms=169794 f=70 dur_ms=3167
session=1 wall=2026-10-26T17:43:03.027+08:00 MMT_ALARM start ms=173082 f=73 person=1 motion=1 area=12056
session=1 wall=2026-10-26T17:43:04.610+08:00 MMT_ALARM end ms=174670 f=76 dur_ms=1588
session=1 wall=2026-10-26T17:43:08.963+08:00 MMT_ALARM start ms=179012 f=81 person=1 motion=1 area=6969
session=1 wall=2026-10-26T17:43:16.994+08:00 MMT_ALARM end ms=187046 f=93 dur_ms=8034
session=1 wall=2026-10-26T17:43:29.889+08:00 MMT_ALARM start ms=199945 f=111 person=1 motion=1 area=8508
session=1 wall=2026-10-26T17:43:34.113+08:00 MMT_ALARM end ms=204169 f=119 dur_ms=4224
session=1 wall=2026-10-26T17:43:38.992+08:00 MMT_ALARM start ms=209042 f=125 person=1 motion=1 area=3298
session=1 wall=2026-10-26T17:43:47.024+08:00 MMT_ALARM end ms=217079 f=137 dur_ms=8037
session=1 wall=2026-10-26T17:43:59.407+08:00 MMT_ALARM start ms=229456 f=154 person=1 motion=1 area=6094
session=1 wall=2026-10-26T17:44:07.438+08:00 MMT_ALARM end ms=237496 f=166 dur_ms=8040
session=1 wall=2026-10-26T17:44:09.021+08:00 MMT_ALARM start ms=239082 f=169 person=1 motion=1 area=2059
session=1 wall=2026-10-26T17:44:14.957+08:00 MMT_ALARM end ms=245013 f=177 dur_ms=5931
session=1 wall=2026-10-26T17:44:20.366+08:00 MMT_ALARM start ms=250413 f=184 person=1 motion=1 area=1689
session=1 wall=2026-10-26T17:44:23.004+08:00 MMT_ALARM end ms=253056 f=189 dur_ms=2643
session=1 wall=2026-10-26T17:44:33.275+08:00 MMT_ALARM start ms=263325 f=202 person=1 motion=1 area=6447
session=1 wall=2026-10-26T17:45:39.239+08:00 MMT_ALARM end ms=329295 f=298 dur_ms=65970
session=1 wall=2026-10-26T17:45:51.094+08:00 MMT_ALARM start ms=341142 f=314 person=1 motion=1 area=8668
session=1 wall=2026-10-26T17:45:56.487+08:00 MMT_ALARM end ms=346544 f=321 dur_ms=5402
session=1 wall=2026-10-26T17:45:59.124+08:00 MMT_ALARM start ms=349184 f=326 person=1 motion=1 area=8502
session=1 wall=2026-10-26T17:46:06.115+08:00 MMT_ALARM end ms=356167 f=336 dur_ms=6983
session=1 wall=2026-10-26T17:46:31.906+08:00 MMT_ALARM start ms=381966 f=372 person=1 motion=1 area=3336
session=1 wall=2026-10-26T17:46:33.490+08:00 MMT_ALARM end ms=383553 f=375 dur_ms=1587
session=1 wall=2026-10-26T17:46:40.480+08:00 MMT_ALARM start ms=390532 f=385 person=1 motion=1 area=6643
session=1 wall=2026-10-26T17:46:46.929+08:00 MMT_ALARM end ms=396988 f=394 dur_ms=6456
session=1 wall=2026-10-26T17:46:55.488+08:00 MMT_ALARM start ms=405548 f=407 person=1 motion=1 area=3734
session=1 wall=2026-10-26T17:47:03.008+08:00 MMT_ALARM end ms=413060 f=418 dur_ms=7512
session=1 wall=2026-10-26T17:47:27.740+08:00 MMT_ALARM start ms=437807 f=452 person=1 motion=1 area=6532
session=1 wall=2026-10-26T17:47:35.261+08:00 MMT_ALARM end ms=445317 f=463 dur_ms=7510
session=1 wall=2026-10-26T17:48:33.480+08:00 MMT_ALARM start ms=503544 f=551 person=1 motion=1 area=6177
session=1 wall=2026-10-26T17:48:43.639+08:00 MMT_ALARM end ms=513693 f=567 dur_ms=10149
session=1 wall=2026-10-26T17:48:52.198+08:00 MMT_ALARM start ms=522258 f=580 person=1 motion=1 area=3743
session=1 wall=2026-10-26T17:49:01.414+08:00 MMT_ALARM end ms=531476 f=591 dur_ms=9218
session=1 wall=2026-10-26T17:49:08.933+08:00 MMT_ALARM start ms=538986 f=602 person=1 motion=1 area=7510
session=1 wall=2026-10-26T17:49:17.492+08:00 MMT_ALARM end ms=547554 f=615 dur_ms=8568
session=1 wall=2026-10-26T17:49:43.826+08:00 MMT_ALARM start ms=573890 f=652 person=1 motion=1 area=6898
session=1 wall=2026-10-26T17:49:46.466+08:00 MMT_ALARM end ms=576535 f=657 dur_ms=2645
session=1 wall=2026-10-26T17:49:51.873+08:00 MMT_ALARM start ms=581938 f=664 person=1 motion=1 area=1506
session=1 wall=2026-10-26T17:50:41.805+08:00 MMT_ALARM end ms=631864 f=736 dur_ms=49926
```

## 低功耗进入 / 唤醒（设备 ms）

| 分段 | 事件 | device_ms | 墙钟 |
|---|---|---:|---|
| 1 | enter | 489856 | 2026-10-26T17:48:19.800+08:00 |
| 1 | exit | 496077 | 2026-10-26T17:48:26.008+08:00 |
| 1 | enter | 652839 | 2026-10-26T17:51:02.780+08:00 |
| 1 | exit | 675603 | 2026-10-26T17:51:25.529+08:00 |
| 1 | enter | 710494 | 2026-10-26T17:52:00.439+08:00 |
| 1 | exit | 714647 | 2026-10-26T17:52:04.582+08:00 |

## mean_sensor 每 60 秒中位数

按分段及设备时钟区间 [start_ms, end_ms) 统计；MMT_PP 通过同帧 f 对齐 MMT_DEC，不沿用上一帧时间。无样本区间留空。

| 分段 | start_ms | end_ms | 样本数 | mean_sensor 中位数 |
|---|---:|---:|---:|---:|
| 1 | 120000 | 180000 | 83 | 36 |
| 1 | 180000 | 240000 | 88 | 59 |
| 1 | 240000 | 300000 | 85 | 59 |
| 1 | 300000 | 360000 | 85 | 59 |
| 1 | 360000 | 420000 | 87 | 61 |
| 1 | 420000 | 480000 | 85 | 49 |
| 1 | 480000 | 540000 | 79 | 53 |
| 1 | 540000 | 600000 | 87 | 83 |
| 1 | 600000 | 660000 | 76 | 64 |
| 1 | 660000 | 720000 | 56 | 46 |
| 1 | 720000 | 780000 | 1 | 46 |

## 每 60 秒运动与 AI 采样事实

AI 采样数取原始 MMT_AI 行数，按同帧 DEC 的设备 ms 分箱；ticks.p 还可来自同帧 MMT_OSD，不将其非空数量代替 AI 采样数。

| 分段 | start_ms | end_ms | DEC | motion=1 | 最大 area | MMT_AI | AI p 中位数 | AI p 最大值 | person=1 | alarm_req=1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 120000 | 180000 | 83 | 66 | 13872 | 83 | -76 | 112 | 7 | 11 |
| 1 | 180000 | 240000 | 88 | 88 | 10894 | 88 | -28 | 115 | 34 | 44 |
| 1 | 240000 | 300000 | 85 | 85 | 8364 | 85 | -28 | 117 | 31 | 65 |
| 1 | 300000 | 360000 | 85 | 85 | 9884 | 85 | -47 | 111 | 23 | 59 |
| 1 | 360000 | 420000 | 87 | 86 | 9871 | 87 | -54 | 104 | 10 | 23 |
| 1 | 420000 | 480000 | 85 | 70 | 12750 | 85 | -95 | 113 | 8 | 11 |
| 1 | 480000 | 540000 | 91 | 63 | 9078 | 79 | -87 | 104 | 17 | 29 |
| 1 | 540000 | 600000 | 87 | 87 | 8696 | 87 | -53 | 101 | 24 | 43 |
| 1 | 600000 | 660000 | 90 | 47 | 11110 | 76 | -84.5 | 97 | 13 | 45 |
| 1 | 660000 | 720000 | 94 | 26 | 591 | 56 | -109 | -98 | 0 | 0 |
| 1 | 720000 | 780000 | 1 | 1 | 98 | 1 | -107 | -107 | 0 | 0 |

- 原始 MMT_AI 行数：812；缺少同帧 DEC 的 AI 行数：0。
- motion=1 的 DEC 帧数：704。
- 独立转储图在 frames/，设备 ms、帧号与 p 的对应关系见 frames.csv；不生成缺行图像。

## 正式窗口之前的被动接入记录

- 2026-10-26T17:29:32.061+08:00–2026-10-26T17:37:07.115+08:00：接收 0 字节，0 串口行，GAP 86，自动/被动重连 2。
- 用户随后报告屏幕无显示，并指示尝试重烧；因此本次改为加载原位流和原 v19 dump，完成后立即抓取，没有上传后复位。
- 此前的主机空闲/断连记录仍在同一份日志内；下列 GAP/重连计数覆盖整份日志，不只覆盖正式窗口。
- 第一次主机采集进程因持续零字节而被重启；执行版本和阶段元数据保存在 history/。

## 正式记录窗口内的主机计数

- 窗口持续时间：600.002 秒。
- GAP：0。
- 重连成功：0。
- 此处仅统计正式十分钟窗口；下表为整份日志计数。

## 采集计数与字段来源

| 项 | 数量 |
|---|---:|
| GAP 行 | 89 |
| 串口重连成功（### RECONNECTED） | 2 |
| 串口断开/重连发起标记（含 ### RECONNECT_TRY） | 1 |
| 完整 96×96 图组 | 81 |
| 未完成图组（有 IMGSTAT） | 0 |
| contact sheet 页数 | 3 |
| ENTER / LEAVE 事件 | 0 |
| 无同帧 DEC 的 MMT_PP | 0 |
| alarm_req=1 的 DEC | 330 |
| person=1 的 DEC | 167 |

- ticks.csv 的 alarm 来自 MMT_DEC.alarm_req；不是从 RTL 报警位推断。
- p 来自同分段同帧 MMT_OSD.p / MMT_AI.p；lp 表示固件休眠状态，优先来自同帧 MMT_LP.fw_lp，缺失时使用同帧 lowpwr 或已记录状态，缺失值留空。
- 本次没有动作标记，不生成 script_events.csv。
- contact sheet 每页最多 40 张，只使用收齐 96 行的原始图像，并以同帧 DEC 标注 device_ms。
- 灯光只以本记录的 mean_sensor 中位数表呈现。
