# session_20261101 / lpfix — 低功耗运动噪声修复（v29.3-lpfix）

## 改了什么

场景里 OSD 常亮 `MOTION=1`、`AREA≈100~140`（板子固定，是图像噪声）。固件低功耗块原本用未过滤面积的 `motion`，噪声每次都清零计时，导致 60 s 内进不了低功耗。

补丁 `lpfix.patch` 只有 3 处：

1. 新增宏 `LP_MOTION_AREA_MIN=200`（与报警判决的 `AI_AREA_MIN` 一致）；
2. 新增 `motion_lp = motion && area >= LP_MOTION_AREA_MIN`（仅低功耗用）；
3. 低功耗块 `if (motion || last_person)` / `if (motion) fw_lp = 0` 改为 `motion_lp`。

`dec_update`、`dec_log`、`ga_update` 的 `motion` **未改**；WB 仍为 `0x158/0x118/0x1A4`；OSD 的 `MOTION` 字样仍显示 RTL 原始值。

## 验证

- 补丁应用：`git apply` 干净应用（"Applied patch ... cleanly"），应用结果与 `main_live292_lpfix.cc` 行级 0 差异。
- 固件构建：`build_v292.py DAY` → FIRMWARE BUILD PASS。
  - **新固件**：`tinyml_pdti8_v292_day_lpfix.bin`，**306,242 B / CRC32 `20375051`**，SHA256 `F638ECDFB5CE69116FEAE6D355E0695A132F60024E560DC3E1AC70CC84908A18`
  - 模型 SHA256 `A78BB07CC09D5279CC88281EAAC5328746E98EDFD2CA471BDF28DDD4EF8941C5`（与定版一致）
  - 原固件 `tinyml_pdti8_v292_day.bin`（**306,194 B / CRC32 `C15D47FD`**）**未覆盖**
- 位流：MERGE17，SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`

## 上板结果

**未上板**：本机当前没有板载 FTDI 串口（`VID_0403` 设备 0 个），无法烧录与采集。

待上板时按以下步骤验收（位流 MERGE17 + 本固件）：
1. 开机串口出现 `MMT_WB_INIT r=344 g=280 b=420 cal=0` 与 `preset=DAY`；
2. 桌面静止场景（OSD 常亮 MOTION=1）**不动板子**，记录 `MMT_LP_ENTER` 出现的秒数、`fw_lp=1`、`paused=1`，看 OSD 第三行是否 `EVT=LOWPWR`；
3. 人走进画面 3 次，记录 `fw_lp`/`paused` 回 0、红框出现、恢复耗时。

## 文件

| 文件 | 说明 |
|---|---|
| `lpfix.patch` | 补丁原文 |
| `main_live292_lpfix.cc` | 应用后源码（与仓库 `submission/firmware/v29_2/main_live292.cc` 一致） |
| `tinyml_pdti8_v292_day_lpfix.bin` | 新固件（306,242 B / CRC32 20375051） |
| `day_build.log` | 构建日志 |
