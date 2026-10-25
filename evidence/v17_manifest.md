# v17 / MERGE12 产物哈希清单

生成时间：2026-10-25 14:25:47

## 位流（MERGE12）

| 项 | 值 |
|---|---|
| 文件 | project/v7_camera_ai/bitstream/v7_MERGE12.bit |
| 大小 | 2826123 B |
| SHA256 | $bitSha |
| 源码包 | project/v7_camera_ai/bitstream/src/v7_MERGE12_src.zip |
| 源码包大小 | 5082557 B |
| 源码包 SHA256 | $zipSha |

## 固件（v17，main_live17.cc）

| 项 | 值 |
|---|---|
| 文件 | sw/tinyml_live/v17/tinyml_pdti8_v17.bin |
| 大小 | 472778 B |
| CRC32 | $crc |
| SHA256 | $binSha |
| 源码 | sw/tinyml_live/main_live17.cc |
| 宏配置 | CROP_MODE=1, STRETCH_ON=1, NORM_ON=0, AUTOEXP_ON=0, LP_CAMFPS_ON=0, AI_P_TH=-86, AI_VOTE=3/4, DEC_TH_OFF=110 |

## 配套文档/证据

| 文件 | 说明 |
|---|---|
| evidence/conf_diag.md | crop1_stretch 三段日志的 conf/EVT/红外温差诊断与改法 |
| evidence/v7_merge12_build.md | MERGE12 五步构建、资源、时序、MERGE9 合并清单 |
| docs/②⑤设计说明.md、docs/固件v16设计说明.md | 既有设计说明（未改动） |

> 说明：crop1_stretch 原始日志来自 evidence/ab_v16/（队友 2026-10-25 采集）；MERGE12 位流与 v17 固件均未上板。
