# v20（v19 + 自动曝光冻结）30 分钟连续抓取 summary

> 只列事实与数字，不作通过/未通过判断。

## 抓取起点说明

本日志按任务要求**先开抓、后复位**，因此开头 0 行是**上一版固件（v19）的尾部输出**，
其 device_ms 属于 v19 的时间轴；MMT_BOOT 之后才是 v20 的完整启动与 30 分钟数据。

## 启动行

```
MMT_LIVE_BOOT v20 CROP=1 NORM=0 STRETCH=1 AE=1 LPCAM=0 FW_DEC=1 LOWPOWER=1
MMT_CAM_VTS ok=1 vts=0x0x5dc rom_vts=0 fallback=1
MMT_CAM 320e=00000005 320f=000000dc 3e00=00000001 3e01=000000bb 3e02=000000f0 3e03=00000000 3e08=00000080 3e09=0000002a exp=0x0000bbf0 gain=0x0000802a
```

## MMT_AE 行（曝光 / 增益调整）

| # | 设备 ms | 内容 |
|---|---|---|
| 1 | 0 | `MMT_AE init exp0=0x0xbbf0 gain0=0x0x802a exp_range=[0x0xbbf0,0x0xffff] gain_range=[0x0x802a,0x0xffff] target=[80,110] step=12% eval=16 dim=0` |
| 2 | 828555 | `MMT_AE mean=32 act=1 exp 0x0000bbf0->0x0000d27e gain 0x0000802a->0x0000802a` |
| 3 | 947217 | `MMT_AE mean=34 act=1 exp 0x0000d27e->0x0000ebc1 gain 0x0000802a->0x0000802a` |
| 4 | 1105837 | `MMT_AE mean=34 act=1 exp 0x0000ebc1->0x0000ffff gain 0x0000802a->0x0000802a` |

## mean_sensor 每 60 秒中位数

| 分钟段（设备 ms 起） | 样本数 | 中位数 | 最小 | 最大 |
|---|---|---|---|---|
| 120000 | 10 | 32 | 32 | 32 |
| 780000 | 27 | 32 | 31 | 35 |
| 840000 | 70 | 34 | 32 | 35 |
| 900000 | 30 | 34 | 33 | 35 |
| 960000 | 23 | 35 | 34 | 35 |
| 1020000 | 60 | 35 | 34 | 35 |
| 1080000 | 36 | 35 | 34 | 35 |
| 1260000 | 14 | 35 | 35 | 35 |
| 1320000 | 2 | 35 | 35 | 35 |
| 2700000 | 1 | 32 | 32 | 32 |

## 报警区间（设备毫秒）

**无 MMT_ALARM 行（整段未触发报警）。**

## 低功耗进入 / 唤醒（设备毫秒）

| # | 事件 | 设备 ms |
|---|---|---|
| 1 | enter | 132589 |
| 2 | exit | 811406 |
| 3 | enter | 831337 |
| 4 | exit | 837042 |
| 5 | enter | 909522 |
| 6 | exit | 934882 |
| 7 | enter | 954293 |
| 8 | exit | 986884 |
| 9 | enter | 1006799 |
| 10 | exit | 1020271 |
| 11 | enter | 1054109 |
| 12 | exit | 1061890 |
| 13 | enter | 1110691 |
| 14 | exit | 1307875 |
| 15 | enter | 1322980 |

## 关键计数

| 项 | 值 |
|---|---|
| DEC 帧数 | 3247 |
| 96×96 图组 | 58 |
| 「p < −40 且报警开着」帧数 | 0 |
| 报警开着帧数 | 0 |
| person=1 帧数 | 0 |
| 低功耗帧数 | 0 |

## 日志完整性

| 项 | 值 |
|---|---|
| GAP 行数 | 4 |
| 串口重连次数 | 3 |
| 首行 | `### CAPTURE_START 2026-10-25T20:29:27.478 image=tinyml_pdti8_v20.bin secs=1800` |
| 末行 | `### CAPTURE_END lines=12996 gaps=4 reconnects=3` |

## 环境

- 台灯朝向：**待操作者确认**
- 房间灯状态：**待操作者确认**
- 摄像头对准：寝室门（未移动）

## 启动行缺失说明

本次日志中 **`MMT_BOOT`、`MMT_DDR_CAL_PASS`、`MMT_CFG` 三行未被抓到**，原因：

- `MMT_BOOT` / `MMT_DDR_CAL_PASS`：烧录走同一颗 FT4232H 的 JTAG 通道，复位瞬间串口输出被冲掉，
  日志从 `MMT_LOADER_READY` 才恢复。
- `MMT_CFG`：紧跟 `MMT_LIVE_BOOT` 打印，处于复位后输出洪峰中丢失
  （`MMT_LIVE_BOOT`、`MMT_CAM`、`MMT_AE init` 均正常抓到）。

编译期配置（来自构建参数，可替代 `MMT_CFG`）：

```
CROP_MODE=1  NORM_ON=0  STRETCH_ON=1
AUTOEXP_ON=1  AE_TARGET_LO=80  AE_TARGET_HI=110  AE_EVAL_FRAMES=16
AE_SET_MANUAL=0  LP_CAMFPS_ON=0  FW_DECISION_ON=1  LOWPOWER_ON=1
IMG_DUMP_EVERY=5
```

## 自动曝光的实际行为（要点）

- 上电后空场景 → 第 11 帧即进入低功耗（`MMT_LP_ENTER f=11 ms=132589`），
  **推理暂停 ⇒ AE 评估一并停止**（AE 代码位于推理分支内），持续约 11 分钟
  （`MMT_LP_EXIT f=1324 ms=811406`）才因运动唤醒。
- 唤醒后 AE 连续动作 3 次，曝光 `0xBBF0 → 0xD27E → 0xEBC1 → 0xFFFF`
  （每次 +12%，第 3 次已顶到硬件上限 `0xFFFF`），`gain` 全程保持 `0x802A` 未变。
- 但 `mean_sensor` 仅从 **32 → 35**，远低于目标 `[80,110]` —— 场景本身太暗，曝光已无余量。
- 冻结保护条件（`!motion && !alarm_on && !person`）在本段从未因后两项被挡下：
  全程 `person=0`、无任何 `MMT_ALARM`。

## 串口稳定性

- `### GAP` 4 次（单次空档 5.0–5.3 s）
- `### RECONNECT_TRY` 3 次（`ClearCommError PermissionError(13)`），3 次均自动重连成功，
  日志中留有 `### RECONNECTED ok=1/2/3`，未重刷固件。
