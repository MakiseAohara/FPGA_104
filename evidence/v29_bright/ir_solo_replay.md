# v29 红外单独报警（ir_solo）— 固件改动与离线回放

> 追加在正在进行的 v29（bright）固件里，不单独出版本。只陈述事实与数字。

## 1. 固件改动

源文件：`main_live29_bright.cc` → `main_live29_bright_irsolo.cc`

| 项 | 内容 |
|---|---|
| 新宏 | `IR_SOLO_ON 1`、`IR_SOLO_N 6` |
| 新状态 | `ir_cnt6`（最近 6 次 `ir_hot` 中为 1 的个数） |
| 起报 | `fusion || (IR_SOLO_ON && ir_cnt6 >= IR_SOLO_N)`，任一满足即起报 |
| 原融合起报 | **保留不变**：`cand_left>0 && (ir_cnt10>=IR_NEED || ai_p_now>=AI_P_STRONG)` |
| 解除 | **不变**：`infer_ran && g_person_off && ir_cnt15==0` |
| 低功耗 | **不变**：进入即清空 IR 环形缓冲、强制结束报警、`ai_reset()` |
| 日志 | `MMT_ALARM start … cause=fusion/ir_solo`；`MMT_FUSION` 增印 `IR_SOLO_ON/IR_SOLO_N` |

判定标签规则：两个条件同时成立时记 `cause=fusion`（因为它本来就会触发），
只有融合条件不成立、单靠 6 连 IR 起报时才记 `cause=ir_solo`。

## 2. 固件产物

| 文件 | 大小 | CRC32 | SHA256 |
|---|---|---|---|
| `tinyml_pdti8_v29_bright_irsolo.bin` | 485,850 B | **9E5CC414** | `068AEAFA6D7AB9FB6104AFDF833A7C88366DF6A74FA2A8D11102DFEC844D859D` |

构建：复用 v29 的隔离工程克隆（含替换后的 v29 person 模型），
`sw/tinyml_live/build_tinyml_firmware.py --main-source main_live29_bright_irsolo.cc`。

## 3. 离线回放（v28 ticks.csv，2608 tick）

| 配置 | 起报次数 |
|---|---|
| A：`IR_SOLO_ON=0`（现状） | **4** |
| B：`IR_SOLO_ON=1`（新增） | **4** |

**新路径额外触发：0 次。**

B 的起因分布：仅 fusion 4 次 / 两者同时 0 次 / 仅 ir_solo 0 次。

### 为什么是 0 —— 逐帧证据

v28 数据里 `irhot=1` 只有 **28 个 tick（1.1%）**，共 13 段；长度分布 `1, 2, 7, 8`。
最长的两段正是「连续 6 次」的候选，但它们都被 fusion 抢先：

**段 A：8 连（ms 1844655–1848750）**

| device_ms | ir | ir_cnt6 | motion | area | alarm | p |
|---|---|---|---|---|---|---|
| 1844655 | 1 | 1 | 1 | 5139 | 0 | −76 |
| **1845187** | 1 | **2** | 1 | 6556 | **1** ← 此处起报 | −93 |
| 1845714 | 1 | 3 | 1 | 1916 | 1 | −76 |
| 1846242 | 1 | 4 | 1 | 3300 | 1 | −82 |
| 1847170 | 1 | 5 | 1 | 293 | 1 | −103 |
| 1847697 | 1 | **6** | 1 | 361 | 1 | −98 |
| 1848224 | 1 | 6 | 1 | 621 | 1 | −99 |
| 1848750 | 1 | 6 | 1 | 720 | 1 | −100 |

`ir_cnt6` 到 6 时（1847697）报警**已经开了 3 个 tick** —— fusion 的 `IR_NEED=2`
（最近 10 次里 2 次）远比「连续 6 次」灵敏，所以永远先触发。

**段 B：7 连（ms 406976–410536）** —— 整段 `alarm` 恒为 1，起报发生在段之前。

### 结论

在这份数据上，ir_solo 是**严格被 fusion 支配**的冗余路径：
只要 `motion` 存在且 `area` 在 `[200, 20000]`，fusion 就会在 2 个 IR 样本内起报，
等不到 6 连。**ir_solo 唯一可能起作用的场景是「有 IR 热点但没有运动候选」**——
也就是人站着不动（`motion=0` → `cand_left` 衰减到 0 → fusion 被卡住）。

## 4. 与低功耗的冲突（对下午测试很关键）

| 统计 | 值 |
|---|---|
| `ticks` 总数 | 2608 |
| `lp=1` 的 tick | 510（19.6%） |
| `irhot=1` 且醒着（`lp=0`） | 26 |
| `irhot=1` 且低功耗（`lp=1`） | 2 |
| 醒着状态最长连续 `irhot=1` | **8**（≥6，够触发） |

代码顺序上有两个硬性约束：

1. **低功耗会清空 IR 环形缓冲**（`if (low_pwr_now) { ir_hist 全 0; ir_cnt6=0; }`），
   所以低功耗期间 `ir_cnt6` 永远回不到 6。
2. **低功耗同一 tick 会强制结束报警**（`if (low_pwr_now && alarm_on)` → `end reason=lowpwr`），
   即使当拍刚由 ir_solo 起报，也会在同一拍被关掉。

因此：**人站着不动若触发低功耗，ir_solo 不会持续报警**；
但在日志里仍应能看到 `MMT_ALARM start … cause=ir_solo` 紧跟一条
`MMT_ALARM end … reason=lowpwr`，这可以用来判断「是否由 ir_solo 报的」。

## 5. 下午测试的观察点

人站画面里不动 30 秒时，依次确认：

1. 是否出现 `MMT_ALARM start … cause=ir_solo`（出现即说明 IR 路径独立起作用）。
2. 该条之后是否立刻跟 `end … reason=lowpwr`（说明被低功耗掐掉）。
3. `MMT_LP` 里 `lowpwr/paused` 何时变 1（判断人不动多久触发低功耗）。
4. `MMT_DEC` 的 `irhot` 与 `ir_cnt` 在这 30 秒里的走势。

如果 30 秒内 `lowpwr` 一直为 0 且没有 `cause=ir_solo`，说明 IR 本身没有持续报热，
需要回头看 MLX90640 的阈值（不在本次改动范围内）。
