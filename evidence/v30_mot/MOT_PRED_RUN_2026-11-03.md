# 上板验证记录 2026-11-03 晚（网口事件 / MOT v17 / 预测）

## 一、网口事件上报：已打通

位流 `9A62F22A…8EF`（只改 `ge_raw_tx.v` 预取时序）+ 固件 `98AE9A19`：

| 检查项 | 结果 |
|---|---|
| 心跳 type=2 | ✅ 每 2 s 一条，负载 0 B，eid=0/total=1 |
| 报警事件 type=1 | ✅ 15:33:29 收到 `INTRUDE x=28 y=47 conf=100 obs=2`（eid=5），写入 events.jsonl |
| 帧率 / 低功耗 | ✅ 有人时 `camfps=59`；空场自动进 LP（`lowpwr=1`），页面同步 |
| 空场误报 | ✅ 15:40–15:43 空场 110 s，只进低功耗，无 INTRUDE |
| 缩略图 type=3 | ⚠️ 板端已接上 `ge_thumb_pump()`（本轮修的"只 prepare 不 pump"），PC 端用 `fake_board.py` 走同一套 10×1000 B 分片验证过重组；**板端真报警的缩略图要等现场有人** |

抓包原文：

```text
from 169.254.47.62 len=18 magic=b'MT' ver=1 type=2 eid=0 seq=0/1 ts=199018
from 169.254.47.62 len=21 magic=b'MT' ver=1 type=1 eid=4 seq=0/1 ts=205474 body=0030300000
```

## 二、Web 监控（页面）

`tools/web_monitor.py` + `tools/page.html`（页面唯一来源）：
链路状态/帧率/推理频率/温度/低功耗胶囊、实时灰度帧、事件时间线（含缩略图链接）、
96×96 缩略图墙（点击放大）、nt/obs 走势图。截图见 `out/live3/shot_real.png`
（真实板子数据：帧号 236、心跳 54、低功耗=是）。

## 三、MOT v17 / 预测

改动（`evidence/v30_mot/mot_core.h`）：

1. `arate`：面积增长率 EMA（%/帧）；
2. `mot_eta_frames()` 两路取最小：面积增长 → 到 55% 画面还需几帧；质心速度 → 几帧进 ROI(24..72)；
   于是"人往镜头走"时 `pre_eta` 不再是 -1，既有 `MOT_PRE_ON` 预警链路（MMT_PREWARN / 低功耗提前退出）才可能触发；
3. `mot_predict_box()` 用 1/2 阻尼速度（离线实测优于全速 30%）；
4. `MOT_GATE_SIZE_DIV`（默认 0=关）：门限随框宽放大，等有操作者的两次对比再开。

**空场验证**：`nt=0 nd=0 pre=0`，未出现虚假航迹/虚假预警；`camfps`、低功耗、报警起停均正常。

### 待补：两版同条件对比（需要人在镜头前）

数据已备好，只差操作者。流程：

```powershell
# A 版（基线）：烧 v30 固件 out_v30_e7（AA5188F9）
py -3 tools\capture_mot.py --port COM15 --out out\mot_A
# B 版（v17）：当前 out_v30_e9（98AE9A19）
py -3 tools\capture_mot.py --port COM15 --out out\mot_B
# 对比表
py -3 tools\mot_analyze.py out\mot_A\serial.log out\mot_B\serial.log --md out\mot_cmp.md
```

### 已做的离线对比（真实日志，无需人）

- 预测器：见 `MOT_PRED_2026-11-03.md` 第 2 节，阻尼 1/2 最优（5.00 px vs 静止 6.00 / 全速 7.07）；
- 关联层回放（`tools/mot_replay.py`，把逐帧检测框灌进关联/生命周期逻辑）：

| 日志 | 配置 | 帧数 | 检测数中位 | ID 总数 | 中位存活 | 最长存活 | nt 中位/最大 |
|---|---|---|---|---|---|---|---|
| ev1 | 基线 | 6 | 1 | 3 | 7 | 10 | 1/2 |
| ev1 | v17 | 6 | 1 | 3 | 7 | 10 | 1/2 |
| ev1 | v17+v16 GATE+KEEP | 6 | 1 | 3 | 7 | 10 | 1/2 |
| ev2 | 基线 | 5 | 1 | 2 | 16 | 16 | 1/2 |
| ev2 | v17 | 5 | 1 | 2 | 16 | 16 | 1/2 |
| ev2 | v17+v16 GATE+KEEP | 5 | 1 | 2 | 16 | 16 | 1/2 |
| ev3 | 基线 | 14 | 3 | 4 | 7 | 25 | 1/2 |
| ev3 | v17 | 14 | 3 | 4 | 7 | 25 | 1/2 |
| ev3 | v17+v16 GATE+KEEP | 14 | 3 | 4 | 7 | 25 | 1/2 |

**结论（老实说）**：现有日志里带检测框的帧太少（6/5/14 帧），三种配置结果完全一致，
不足以判定 v16 的好坏 → 保持默认关闭，等操作者两次上板。

## 四、本轮修掉的两个真 bug

1. `ge_raw_tx.v` `S_PRE` 每拍重写 `cur/rdaddr` → 首字被跳过、整帧前移 4 字节（网卡全判坏帧）；
2. 固件 `ge_thumb_pump()` 写了却没在主循环调用 → 缩略图一片都没发出去。
