# v29.3-lpfix 低功耗噪声修复（只改低功耗的运动判断）

> 固件：`tinyml_pdti8_v292_day_lpfix.bin`，**300,938 B / CRC32 `BC37FEAB`**（v29.2 定版 `C15D47FD` 未覆盖）
> 位流：`v7_MERGE17.bit`，SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`
> 时间：2026-11-01 21:5x（本机）

## 改了什么（3 处）

1. 新增宏 `LP_MOTION_AREA_MIN 200`；
2. 低功耗块内新增 `const int motion_lp = motion && (area >= LP_MOTION_AREA_MIN);`；
3. `if (motion || last_person)` 与 `if (motion) fw_lp = 0；` 两处改用 `motion_lp`。

`dec_update` / `dec_log` / `ga_update` 里的 `motion` 一律未改；WB 仍 0x158/0x118/0x1A4；OSD 的 MOTION 字样仍是 RTL 原始值。

> 注：`..\..\..\lpfix\` 与“易灵思”目录下均未找到 `lpfix.patch` / `main_live292_lpfix.cc`（全盘搜索过），
> 以上 3 处是按任务描述手工改的，源码见 `evidence/v29_fw/main_live292_lpfix.cc`。

## 上板结果

| 项 | 结果 |
|---|---|
| 烧录 | MERGE17：`Device ID PASS` / `finished with JTAG programming` |
| 固件装载 | `MMT_LOAD_PASS DDR_CRC` |
| 白平衡 | `MMT_WB_INIT r=344 g=280 b=420 cal=0` ✓ |
| 相机预设 | `MMT_CAM_PRESET name=DAY` ✓ |
| 进入低功耗 | 开机后约 **20 秒**（45 帧）出现 `MMT_LP_ENTER`，`rtl_lp=1`、`paused=1`、`MMT_LPCAM enter 0x5dc→0x1194` |
| 稳定驻留 | 150 秒空闲窗口内 `(lowpwr,fw_lp,paused)` 全部为 `(1,1,1)`，238/238 行 —— **固件侧 `fw_lp=1` 说明 lpfix 生效** |
| 该窗口报警 | 0 次 |
| 恢复测试（人进入 3 次） | **未测**：两个窗口（150 s + 140 s）内无人进入画面，`MMT_ALARM start` = 0、`MMT_LP_EXIT` = 0、`(lowpwr,fw_lp,paused)` 恒为 (1,1,1) |

## 文件

| 文件 | 说明 |
|---|---|
| `boot_and_lp.log` | 装载 + 开机行 + 首次 `MMT_LP_ENTER` 原始日志 |
| `idle150s.log` | 150 秒空闲窗口（`fw_lp=1` 稳定驻留） |
| `idle140s_run2.log` | 第二段 140 秒空闲窗口（同样 `fw_lp=1` 稳定驻留，无人进入） |
