# 单人验收手册（多目标 A/B + 行为预测）2026-11-04

> 结论先说：**一个人完全够**。这两件事要验证的是"同一套动作下，固件行为是否更稳/是否提前"，
> 属于 within-subject 对比 —— 关键是"两次跑法一模一样"，跟人数无关。
> 两个人只有在"现场演示多目标"时才需要（那时是表演，不是验收）。

---

## A. 多目标：两版对比（约 17 分钟，含两次烧录）

### A.0 为什么对比 e13 而不是最老的基线

- **A 版**：`out_v30_e13\tinyml_pdti8.bin`（CRC32 `76188F5F`，`MOT_V16_GATE=0`）
- **B 版**：`out_v30_e15\tinyml_pdti8.bin`（CRC32 `0987B11B`，`MOT_V16_GATE=1`，当前板上这版）

两版**只差 GATE 这一处**，所以差异只能归因于 GATE —— 这比拿一周前的基线固件对比干净得多。
（想跟最老的 `AA5188F9` 比也可以，但那时还混着别的改动，结论说不清。）

### A.1 跑 A 版

```powershell
# 1) 位流（每次换固件都要先重配位流，板子才会进 loader）
& D:\v30_build\flash_vendor_utf8.ps1 -Bit D:\eth_build\m17_ge\outflow\ti60f225_oob.bit     -Sha256 9A62F22A3A989944622E414C20030D6F8A8F9E47F9A99393F15287E3C7BAB8EF -Force

# 2) 固件 A
py -3 D:30_buildload_v30.py --image D:30_buildout_v30_e13	inyml_pdti8.bin --out D:30_buildout_load_e13
#    等到串口出现  MMT_LOAD_PASS DDR_CRC  再继续

# 3) 采集 A（会响提示音 + 屏幕大字，跟着做就行）
py -3 toolscapture_mot.py --port COM15 --out outmot_A --only B1,B2,B3,E
```

动作顺序（脚本会提示，共 160 s）：
1. **B1 站定 20 s**：站画面中间，别动；
2. **B2 慢走 45 s**：左右来回走 3 趟，每趟约 7 s，走完整条画面；
3. **B3 快走 35 s**：同样路线，速度快一倍；
4. **E 空场 60 s**：完全离开画面。

> 三次走"同一条路线"很重要：脚踩同一条地砖线，转身位置固定。相机、灯、窗帘全程别动。

### A.2 跑 B 版（同样的动作再来一遍）

```powershell
& D:30_buildlash_vendor_utf8.ps1 -Bit D:eth_buildm17_geoutflow	i60f225_oob.bit     -Sha256 9A62F22A3A989944622E414C20030D6F8A8F9E47F9A99393F15287E3C7BAB8EF -Force
py -3 D:30_buildload_v30.py --image D:30_buildout_v30_e15	inyml_pdti8.bin --out D:30_buildout_load_e15
py -3 toolscapture_mot.py --port COM15 --out outmot_B --only B1,B2,B3,E
```

### A.3 出对比表

```powershell
py -3 toolsmot_compare.py outmot_Aserial.log outmot_Bserial.log --name-a "A版(GATE=0)" --name-b "B版(GATE=1)"
```

判定口径（脚本会自己投票，人只需要看两件事）：

| 指标 | 期望方向 | 为什么 |
|---|---|---|
| ID 总数 | 越少越好 | 一个人被反复换号 = 关联失败 |
| ID 存活中位 | 越长约好 | 同上，反指标 |
| nt 抖动(std) | 越小越好 | 在场航迹数忽 0 忽 2 = 抖动 |
| 框面积中位 | 两版应"一致" | 差 >25% 说明两次条件不同，**数据作废重跑** |

三项里两项站在 B 侧 → 写"B 版更好"，否则"无显著差别/基线更好"。

---

## B. 行为预测：验收（约 4 分钟，一版固件即可）

### B.1 要验的四件事

预测不是"算命准不准"，而是这四个可观测行为：

| # | 要验的 | 观测点 | 判据 |
|---|---|---|---|
| 1 | 预警**早于**报警 | `MMT_PREWARN` → `MMT_ALARM start`，中间有 `MMT_PREDLEAD lead_ms=` | `lead_ms > 0` |
| 2 | 提前量够不够 | 同上 `lead_ms` 数值 | 中位 `>= 400 ms`（MOT 2 fps，一帧≈500 ms） |
| 3 | `pre_eta` 真的在变小 | `MMT_MOT ... pre=1 pre_eta=6→5→4` | 每次接近里单调下降 |
| 4 | 不许多报 | 空场/站定时 `pre=1` | 各 **0 次** |

### B.2 跑

```powershell
py -3 -u toolscapture_pred.py --port COM15 --out outpred_A
```

动作（提示音会带你走，别抢拍）：
1. **READY 15 s**：走开，空场；
2. **STAND 20 s**：站画面中间不动；
3. **APP1..APP5 各 12 s**：退出画面 4 s → 朝镜头走过来 → 到约 1.5 m **停下 4 s**；
   > 走的速度要"正常走路"，别冲刺也别挪碎步；每轮都从同一个位置出发。
4. **LEAVE 20 s**：走出画面。

采集结束会自动跑 `pred_accept.py` 并打印判定，结果同时写 `outpred_Aaccept.json`。

### B.3 判定（6 项全 PASS 才算过）

```text
[PASS] 有效接近次数 >= 3      5 轮里至少 3 轮走到触发预警
[PASS] 每次 lead_ms > 0        预警必须先于报警
[PASS] lead_ms 中位 >= 400 ms  提前量至少大半帧
[PASS] 空场无误报              nd=0 的帧里 pre 不能是 1
[PASS] 站定无误报              人不动（面积 3 帧不变）时不能预警
[PASS] pre_eta 下降片段 >= 70% 每个预警片段里 eta 要在减小
```

看到 `总判定: 数据不足` = 一次预警都没出现，不是失败，先查：
- 人是不是走太快、没进画面中间（看 `MMT_MOT nd=` 有没有变成 1）；
- 报警本身有没有触发（`MMT_ALARM start` 要出现，预测挂在报警链路上）；
- 固件版本对不对（`MMT_LOAD_CRC` 应为 `0987B11B`）。

### B.4 常见 FAIL 与对应处理

| 现象 | 原因 | 处理 |
|---|---|---|
| 有 `MMT_PREWARN` 但 `lead_ms ` 很小(<200 ms) | 人走太快，一帧就到跟前 | 放慢一半再跑一次；仍小则把 `MOT_ARATE_MIN` 调小(4→3) |
| `pre_eta` 一直是 -1 | 面积没涨（人横着走而不是朝镜头走） | 动作要"朝镜头"，不是左右平移 |
| 空场出现 pre=1 | 背景大面积变化（窗帘/灯/显示器） | 记下时间点，跑 `MMT_DEC` 看 `motion`；必要时 `MOT_ARRAY_MIN` 调大 |
| 5 轮一次都不预警 | 报警没触发或 GATE 把块挡了 | 看 `MMT_MOT nd/nt` 是否有 1；看 `MMT_DEC alarm_req` |

---

## C. 记录表（复制到 `outpred_Aeport.md` 里填）

```text
日期/时间：
固件 CRC32：            位流 SHA256 前 8 位：
环境（灯/窗帘/距离）：
—— 多目标 A/B ——
A 版：ID 数___ 存活中位___ nt 抖动___  框面积中位___
B 版：ID 数___ 存活中位___ nt 抖动___  框面积中位___
结论：A / B / 无差别        （mot_compare 票数___）
—— 预测 ——
接近轮数___/5   lead_ms 列表________  中位___
pre_eta 下降片段___/___        空场误报___  站定误报___
pred_accept 总判定：______
备注（异常/需复查）：
```
