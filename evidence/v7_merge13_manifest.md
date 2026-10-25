# v7_MERGE13 哈希清单

生成时间：2026-10-25 14:41:28

## 位流（MERGE13）

| 项 | 值 |
|---|---|
| 文件 | `project/v7_camera_ai/bitstream/v7_MERGE13.bit` |
| 大小 | 2824365 B |
| SHA256 | `58C667D248A5E3B5B8E6DD1F9FD7ACD0DEA1E1094890450294E80C9577978F46` |
| 源码包 | `project/v7_camera_ai/bitstream/src/v7_MERGE13_src.zip` |
| 源码包大小 | 5244309 B |
| 源码包 SHA256 | `82273CE5FDB48EE58A8FF3E01C211574E9CD1308AB7E8CDB516E48E729E8F4D1` |

## 固件（v17，未随 MERGE13 改动）

| 项 | 值 |
|---|---|
| 文件 | `sw/tinyml_live/v17/tinyml_pdti8_v17.bin` |
| 大小 | 472,778 B |
| CRC32 | `18739BB6` |
| SHA256 | `F8C8A536DB0E596DA0FD138B6F13B4F9F60FBF2B4C46528505C4DE2ED07C7025` |
| 源码 | `sw/tinyml_live/main_live17.cc` |

## MERGE13 改动摘要

① `HOT_ON` 48→24（仍为参数）；
② 门控 `alarm_raw & motion & (ir_hot | ai_person)`（新模块 `v7_alarm_gate.v`）；
③ OSD `EVT` 显示固件 word14 事件（INTRUDE/TREND/PERSON/LOWPWR/NORMAL），红框/LED/蜂鸣器仍由 RTL `alarm_on` 驱动。

## 证据

| 文件 | 说明 |
|---|---|
| `evidence/v7_merge13_build.md` | 构建报告（五步、资源、时序、改动清单） |
| `sim/logs_merge13/tb_alarm_gate.log` | 新增门控用例（ir_hot=0、ai_person=1、motion=1 → 拉起） |
| `sim/logs_merge13/tb_evt_osd.log` | OSD EVT 五种事件码解码 |
| `sim/logs_merge13/tb_i2c_apb.log` / `tb_apb_regs.log` / `tb_apb_ext.log` | 既有三个测试台回归 |

> 说明：MERGE13 只编译、未烧录；时序最差 setup +0.283 ns、最差 hold +0.011 ns（均工程内可见）。
