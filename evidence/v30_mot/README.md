# v30 —— 多目标跟踪（IOU Tracker）+ 行为预测

> 任务书第三部分「系统优化与智能拓展」七选二中的 **③ 多目标跟踪** 与 **④ 行为预测**。
> 基线：v29.2 DAY 定版固件（evidence/v29_fw/main_live292.cc，CRC32 C15D47FD）+ MERGE17 位流。
> 实现位置：**RISC-V 固件**（挂在 ② RISC-V 决策控制这条扩展项上），**不改 RTL、不改 APB 寄存器布局**。

---

## 0. 一句话

每帧把 96×96 的 AI 输入图跑一遍「背景差分 → 连通域 → IOU 关联 → 速度估计」，得到**多条稳定 ID 的运动目标轨迹**；
再用速度向量做 **2 帧前视位置预测**、方向分类、进 ROI 剩余帧数；预测「即将进入」时**提前**打预警并跳出低功耗、提前恢复全速推理。

---

## 1. 对应任务原文

| 原文 | 本实现 |
|---|---|
| 多目标跟踪：实现简单的多目标跟踪算法（如 IOU Tracker），同时跟踪场景中多个体的运动轨迹 | mot_core.h：检测（背景差分 + 膨胀 + 4 邻域连通域）→ **两级关联**（预测框 IOU → 质心距离门限）→ 航迹生命周期（新建/命中/丢失/删除）→ 每目标 12 点轨迹缓冲 |
| 行为预测：基于运动轨迹和速度向量，预测人体下一步位置，提前做出响应 | Q4 定点速度 EMA → pred=(cx+vx·2, cy+vy·2)（2 帧 ≈ 1 s @2fps）× 方向 dir × ROI 到达帧数 eta → MMT_PREWARN + 提前退出低功耗 + 真报警时输出 MMT_PREDLEAD（提前量 ms） |

---

## 2. 算法

```
每帧 u[96×96]（AI 输入原图，字节原样）
  ├─ 背景模型 bg += (u - bg) >> 5，整幅均值补偿（AGC/增益跳变不误检整幅）
  ├─ 前景 mask = |u - bg| >= 14，3×3 膨胀（把人体合成整块）
  ├─ 鬼影剔除：连通域内「帧间差分」像素 < 面积/8 ⇒ 背景残留（人走了），丢弃
  ├─ 连通域：4 邻域栈式 flood fill；面积 ∈ [60, 6000]；按面积降序取前 6
  ├─ 关联：一级 = 与「按速度外推 1 帧」的框算 IOU（阈值 0.20），贪心；
  │        二级 = IOU 全丢时按「预测质心距离」≤ 16 px 续轨（人走太快也不丢 ID）
  ├─ 更新：v = (3v + Δc·16)/4（Q4 定点，16 = 1 px/帧）；命中 +1、丢失清零
  └─ 输出：最多 4 条航迹（每目标 12 点轨迹）/ 预测位置 / 方向 / eta
```

**为什么加二级关联**：板上推理约 2 fps，人正常走路在 96×96 网格里每帧位移可达 10–30 px，单靠 IOU 会「每帧一个新 ID」；
用速度外推 + 距离门限后，真实数据回放的 ID 连续性中位从 4 帧提升到 12 帧。

---

## 3. 串口协议（新增，向后兼容）

```
MMT_MOT_CFG ver=v30 on=1 pre=1 diff=14 min_area=60 max_area=6000 iou_pm=200 horizon=2 max_trk=4 roi=[16,16,80,80]
MMT_TRK f=271 id=21 c=36,71 b=0,35,88,95 v16=52,-60 dir=5 hit=2 miss=0 conf=1 pred=55,49 eta=-1
MMT_MOT f=271 nd=1 nt=1 conf=1 area=4616 pre=0 pre_eta=-1
MMT_PREWARN f=.. id=.. eta=.. ms=.. fw_lp=0
MMT_PREDLEAD f=.. lead_ms=.. id=.. eta=..
```

| 字段 | 含义 |
|---|---|
| c=cx,cy | 质心（96×96 网格像素） |
| b=x0,y0,x1,y1 | 包围盒（闭区间） |
| v16=vx,vy | 速度 Q4（右移 4 位 = px/帧） |
| dir | 0 静止 / 1 左 / 2 右 / 3 上 / 4 下 / 5 斜移 |
| hit/miss/conf | 命中数 / 连续丢失数 / 是否确认（≥2 次命中） |
| pred=px,py | 2 帧后预测质心 |
| eta | 预计还有几帧进入 ROI（画面中间 2/3）；-1 = 已在 ROI 内或不会进入 |

---

## 4. 验证（三层）

### 4.1 主机侧单元测试（合成场景）

```
S0 static: no det              PASS
S1 two targets: count          PASS trk=2 idA=1 idB=2 vA16=29 vB16=45
S1 two targets: id stable      PASS
S1 vel A ~2px/f                PASS
S1 vel B ~3px/f                PASS
S2 vertical: dir=down          PASS
S2 pred 2-frame ahead          PASS
S3 track exists                PASS
S3 no ghost detection          PASS
S3 deleted after MAX_MISS      PASS
S4 crossing survives           PASS
S5 global change rejected      PASS
MOT_TESTS PASS (fails=0)
```

### 4.2 真实数据离线回放（330 帧，evidence/v29_scene/log_v29_scene.log）

| 指标 | 数值 |
|---|---|
| 回放帧数 | 330 |
| 确认航迹数 | 19 |
| 确认航迹长度 中位 / 最长 | 12 / 19 帧 |
| 预测误差 中位 / p90 | **1.5 / 7 px** |
| 方向分布（帧） | 静止 80、上 13、下 22、斜移 90 |
| 速度中位 | 0.56 px/帧 |

> 该日志帧间隔约 1.5 s，而板上每帧都跑 MOT（约 0.5 s/帧），真实连续性应优于上表；上表是保守下限。

### 4.3 上板（MERGE17 + v30）

- 位流 v7_MERGE17.bit（2,845,704 B，SHA256 3A69AAFB…087CF），JTAG 易失加载，Device ID 0x10660A79 校验 PASS；
- UART loader：MMT_LOAD_PASS DDR_CRC → MMT_LIVE_BOOT v29.2 → **MMT_MOT_CFG ver=v30 on=1 pre=1**；
- 空场基线（walk1，150 s / 347 帧）：AI 分数最大 +30、中位 +2（确认无人）；MOT 只有单帧噪点航迹，无确认航迹、无预警、无报警；
- 暗场噪点抑制：MOT_MIN_AREA 40→60 + 鬼影判定要求 ≥12.5% 像素在动（同类场景噪点航迹 12 → 6）。

---

## 5. 文件

```
evidence/v30_mot/
├── mot_core.h              算法本体（纯 C，固件与主机共用）
├── main_live30.cc          v30 固件（= main_live292.cc + MOT 接线；MOT_ON=0 可整段关闭）
├── test_mot.c              主机侧单元测试（合成场景）
├── replay_mot.c            帧序列回放到 mot_core，输出同格式日志
├── export_frames.py        从串口日志导出 96×96 帧（frames.bin + frames.json）
├── analyse_mot.py          统计：航迹数/ID 连续性/速度/方向/预测误差/预警提前量
├── build_v30.py            一键重建（--project / --out / [--night]）
├── check_v30.py            自检：模型字节、MOT 字符串、版本标记
├── load_v30.py             UART 载入 + 抓取（块级重试，仅易失加载）
├── selfcheck_v30.json      自检结果
├── firmware_identity_v30.json  产物身份（字节数/CRC32/SHA256）
└── replay/                 离线回放证据（replay.log + 统计 json）
```

重建：

```powershell
py -3 evidence\v30_mot\build_v30.py --project D:\v30_build\project --out D:\v30_build\out_v30c
py -3 evidence\v30_mot\check_v30.py
```

---

## 6. 已知限制 / 下一步

1. **真人走动验收未完成**：本轮两次上板窗口里镜头前没有人（AI 分数 ≤ +30），MOT 只采到噪点与空场基线；
   需要一次「左进→停 3 s→右出」+「右进→倒退出」的实拍，才能给出 ID 连续性与提前量的板上数字。
2. **轨迹不上屏**：只走串口（改 OSD 需动 RTL，本轮刻意不动）。
3. 静止目标依赖 AI；背景模型会把静止 10 s 以上的人吸收掉（运动目标靠 MOT）。
4. 画面暗（mean_sensor 25–95）时噪点多，MOT_MIN_AREA 已按暗场调到 60；亮场可回调 40–50。
