# OSD 三行调研（只读，未改代码）

## 1 生成位置

**RTL 侧生成，不在固件**：

- 字符格式化：`rtl/v7/mmt/v7_txt_fmt.v`（MERGE17 工程对应 `PROJECT:\v7work\v7_MERGE17\rtl\v7\mmt\v7_txt_fmt.v`，244 行）。
- 叠加：`rtl/v7/osd/v7_osd_overlay.v`（读 `txt_rd_data`，L170 `txt_rd_addr`、L307 打两拍后叠加）。
- 固件只写 APB 原始值（`main_live292.cc`）：`temp_x100`、`rh_x100`、`ir_x10`、`area`、`conf_x100`、`ai_score`、`evt_code`（APB word14）、`night`、`sns_ok`、`low_pwr` 等。

关键源码（`v7_txt_fmt.v`）：

```
L6:  input wire [15:0] temp_x100, rh_x100, ir_x10, area, conf_x100,
L9:  input wire motion, alarm_on, night, sns_ok, low_pwr,
L10: input wire [7:0] evt_code,      // MERGE13: 固件事件类型
L57: case (evt_code)
L58:  8'd1: INTRUDE   L59: 8'd2: TREND   L60: 8'd3: PERSON   L61: 8'd4: LOWPWR   default: NORMAL
```

## 2 三行字段

| 行 | 内容（idx 段） | 字段 | 字符数 |
|---|---|---|---|
| 第 1 行 | idx 0–27 | `T=XX.XC`、`RH=XX.X`、`HR=23`（night）/`HR=12`（day）、`NIGHT`/`DAY` | 28 |
| 第 2 行 | idx 64–90 | `IR=XX.X`、`MOTION=1/0`、`AREA=XXXX` | 27 |
| 第 3 行 | idx 128–139 | `EVT=XXXXXXX`（INTRUDE / TREND / PERSON / LOWPWR / NORMAL） | 12 |

## 3 是否已有低功耗 / 推理暂停 / MOT 字段

| 字段 | 是否有 | 说明 |
|---|---|---|
| 低功耗状态（`low_pwr`） | **部分有** | RTL 端口有 `low_pwr` 输入（L9），但三行里没有独立的 `LP=0/1`；只能通过 `evt_code=4` 让第 3 行显示 `LOWPWR`（7 字符整词替换） |
| 推理暂停（`paused`） | **无** | 端口无此输入，OSD 不显示 |
| MOT 状态（航迹数/ID） | **无** | 端口无此输入，OSD 不显示 |

## 4 只改固件、不改 RTL 的最小改法（≤48 字符/行）

前提：三行字符位由 RTL 的 `idx` 表固定，固件只能改**数值**（温度/湿度/红外/面积/置信度）与 `evt_code`（第 3 行整词）。

**可行方案（只改固件）**：复用 `evt_code` 的 7 字符整词槽位，把低功耗与推理暂停编码成短词：

```
evt_code=4 → "LOWPWR "   （RTL 已支持）
evt_code=5 → "LPPAUSE"   （需 RTL 加一个 case 分支——不属于"只改固件"）
```

因此**严格只改固件**时，能做的只有：

1. 低功耗进入时把 `evt_code` 写 4（第 3 行显示 `LOWPWR`），退出时写回 0（`NORMAL`）——这已能表达"LP=1"。
2. 推理暂停与低功耗通常同时发生，因此不必单独字段。
3. 若必须显示 `LP=0/1` 字样：把 `evt_code` 的 7 字符槽在 RTL 里新增一个分支（`8'd6 → "LP=1   "`），这是**改 RTL**，不满足"只改固件"。

**结论**：在不改 RTL 的前提下，低功耗只能以第 3 行 `EVT=LOWPWR` 表达；要独立 `LP=0/1`、`PAUSE=1` 或 MOT 状态，必须改 `v7_txt_fmt.v` 的 `idx` 表与端口（属 RTL 改动，本轮按约束未做）。

## 5 建议（供后续决策）

- 第 1 行 28 字符、第 2 行 27 字符、第 3 行 12 字符，距 48 字符上限仍有空间；
- 若要加 `LP=0/1`，最小 RTL 改动 = `v7_txt_fmt.v` 第 3 行 idx 139 之后追加 `  LP=0`（4 字符），并把 `low_pwr` 接到该位；
- 若要加 MOT 航迹数，需新增 APB 字并在 RTL 增加 2 位数字段。
