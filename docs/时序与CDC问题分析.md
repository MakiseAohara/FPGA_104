# 时序与 CDC 问题分析（WNS -3.589 ns：hdmi_tx_slow_clk ↔ core_clk）

- 分析日期：2026-10-11
- 分析对象：`D:\FPGA\mmt`（Efinix Efinity 2026.1.132，Ti60F225I3，顶层 `mmt_top`）
- 输入（只读）：`out\mmt.timing.rpt`、`out\mmt.cdc.rpt`、`out\efx_pnr.log`、`out\mmt.map.rpt`、`out\mmt.hier_util.rpt`、`constr\ti60f225_oob.sdc`、`rtl\mmt\**`
- 本次**没有**重跑任何 Efinity 流程；所有结论都来自已有报告 + RTL 源码，行号可核对。
- 输出改动：`constr\ti60f225_oob.sdc` 新增 1 条时钟组声明（第 29–37 行）。**未改任何 RTL。**

---

## 0. 结论（先看这一节）

| 项目 | 结论 |
|---|---|
| 性质判定 | **约束缺失（SDC 问题），不是"捕获侧缺两级同步器"的 RTL bug。** 捕获侧确实有完整的 2 级同步器，两条失败方向共 20 条路径的终点**全部**是同步器的**第一级** `s1`，不是普通功能触发器。 |
| 最差 slack | **-3.589 ns**（`hdmi_tx_slow_clk → core_clk`，`out\mmt.timing.rpt:114`） |
| 失败路径统计 | Setup(max) 失败关系**只有 2 对**：`hdmi_tx_slow_clk→core_clk` 10 条（最差 -3.589）、`core_clk→hdmi_tx_slow_clk` 10 条（最差 -1.225）。Hold(min) **全部为正**（最小 +0.008 ns）。报告每对只列前 10 条，所以"10 条"是**报告上限**，真实条数 ≥10/方向。 |
| 第一优先修复 | 改 `constr\ti60f225_oob.sdc`：加一条 `set_clock_groups -asynchronous -group {core_clk} -group {hdmi_tx_slow_clk}`（**已改**，第 37 行）。预期重跑后 WNS 由 -3.589 变为 +3.430 ns（下一个最差关系 `core_clk→core_clk`）。**必须重跑 `efx_map`+`efx_pnr` 才能确认。** |
| 附带发现（不影响上面的判定） | ① `alg_alarm_s` 从系统域**反灌**视频域且没有同步器（`mmt_top.v:1376` → `mmt_osd_overlay.v:160`）；② 多比特总线按位同步的相干性局限（作者已在 `mmt_sync2.v:6-14`、`mmt_top.v:1286-1292` 自述）。两者都要改 RTL，但都**不是** -3.589 的成因。 |

---

## 1. 时钟域与时钟来源（谁跟谁是一对）

`out\mmt.timing.rpt:29-39`（用户约束时钟表）：

| 时钟 | 周期 (ns) | 频率 (MHz) | SDC 声明 | 来源 |
|---|---|---|---|---|
| `core_clk` | 10.000 | 100.000 | `constr\ti60f225_oob.sdc:6` | **MIPI_TX_PLL** 输出 0（`mmt.peri.xml:354`） |
| `hdmi_tx_slow_clk` | 7.143 | 139.997 | `constr\ti60f225_oob.sdc:22` | **USER_PLL** 输出 1（`mmt.peri.xml:341`） |
| `vid_clk_dvi2` | 14.286 | 69.999 | `constr\ti60f225_oob.sdc:17` | **USER_PLL** 输出 0（`mmt.peri.xml:340`） |
| `i_mipi_rx_pclk` | 20.000 | 50.000 | `sdc:21` | USER_PLL 输出 2（`mmt.peri.xml:342`） |
| `sdram_clk` / `rx_cal_clk` / `tx_cal_clk` / `tx_cal_clk_90edge` | 2.500 | 400 | `sdc:8-11` | DDR3 用 PLL（`mmt.peri.xml:325-328`） |
| `CLK_5M` | 200.000 | 5.000 | `sdc:18` | `pll_inst4` 输出 1（`mmt.peri.xml:369`） |

关键事实（`mmt.peri.xml`）：

- `hdmi_tx_slow_clk` 与 `vid_clk_dvi2` 是**同一个 PLL（USER_PLL）的两个输出**（`:340`、`:341`），是同源、成确定比例的一对 → 它们之间做同步时序分析是**合理**的。
- `core_clk` 是**另一个 PLL（MIPI_TX_PLL）**的输出（`:354`）。两个 PLL 虽然都 `ref_clock_name="CLK_25M"`（`:332`、`:346`），但是**两个独立的 PLL 实例**，输出相位关系不可分析 → 必须声明为异步。
- 所有时钟都在两个不同的全局时钟网络上：`out\mmt.route.rpt:20-30` 里 `core_clk` 在 GBUFCE(112,322)、`hdmi_tx_slow_clk` 在 GBUFCE(106,322)。

RTL 侧时钟域划分（`rtl\mmt\mmt_top.v`）：

- 视频域 = `hdmi_tx_slow_clk`：`u_downscale`(`:1308`)、`u_osd`(`:1358`)、`u_algo`(`:1665`)、`dvi_encoder_m0.pixelclk`(`:1247`)、两个双口 BRAM 的 B 口(`:1338`、`:1349`)、若干 `always @(posedge hdmi_tx_slow_clk)`(`:1063`、`:1650`、`:1735`)。
- 系统域 = `core_clk`：SoC(`:929-930`)、传感器(`:1580`)、TinyML(`:875`、`:889`)、报警(`:1752`)、BRAM 的 A 口(`:1334`、`:1345`)。

> ⚠️ 文档不一致（不影响时序结论，但要修）：`mmt_top.v:1281` 和 `协作日志.md:1146` 都写 `hdmi_tx_slow_clk (148.5MHz)`，而工程实际约束是 **139.997 MHz / 7.143 ns**（`sdc:22`、`timing.rpt:39`、`mmt.peri.xml:341` 的 divider）。注释里的 148.5MHz 是旧值（1080p60 时代的），请以 140MHz 为准。

---

## 2. 失败路径统计（按"发射域 → 捕获域"分组）

统计方法：解析 `out\mmt.timing.rpt` 全部 282 个 `++++ Path N` 块，取每个块的 `Path Detail Report (发射域 vs 捕获域)`、`Slack`、`Path Begin/End`。

### 2.1 按关系汇总（Setup / Max）

| 发射域 → 捕获域 | 报告条数 | 最差 slack | 约束 | 判定 |
|---|---|---|---|---|
| **hdmi_tx_slow_clk → core_clk** | 10（=报告上限） | **-3.589** | 0.001 | ❌ 全部失败 |
| **core_clk → hdmi_tx_slow_clk** | 10（=报告上限） | **-1.225** | 0.001 | ❌ 全部失败 |
| core_clk → core_clk | 10 | +3.430 | 10.000 | ✅ |
| core_clk → tx_cal_clk_90edge | 10 | +0.897 | 2.500 | ✅ |
| tx_cal_clk_90edge → core_clk | 5 | +1.699 | 2.500 | ✅ |
| tx_cal_clk_90edge → tx_cal_clk_90edge | 10 | +0.260 | 2.500 | ✅ |
| tx_cal_clk_90edge → tx_cal_clk | 1 | +1.281 | 2.500 | ✅ |
| sdram_clk → tx_cal_clk_90edge | 5 | +0.657 | 2.500 | ✅ |
| sdram_clk → sdram_clk | 10 | +0.106 | 2.500 | ✅ |
| rx_cal_clk → rx_cal_clk | 10 | +0.437 | 2.500 | ✅ |
| tx_cal_clk → tx_cal_clk | 10 | +0.147 | 2.500 | ✅ |
| vid_clk_dvi2 → vid_clk_dvi2 | 10 | +9.485 | 14.286 | ✅ |
| vid_clk_dvi2 → hdmi_tx_slow_clk | 10 | +3.741 | 7.143 | ✅（同源 PLL，是同步路径） |
| CLK_5M → CLK_5M | 10 | +196.468 | 200.000 | ✅ |
| i_mipi_rx_pclk → i_mipi_rx_pclk | 10 | +14.732 | 20.000 | ✅ |
| hdmi_tx_slow_clk → hdmi_tx_slow_clk | 10 | +1.465 | 7.143 | ✅ |

**结论：失败的只有 2 对关系，全部是 `core_clk` ↔ `hdmi_tx_slow_clk`。** 交叉验证 `out\efx_pnr.log:4580-4581`——PnR 自己最后只打印了这 2 条 domain 级告警，没有第 3 条：

```
4580: WARNING : Clock domain between core_clk (rising) and hdmi_tx_slow_clk (rising) may not meet (slack: -1.225 ns) the setup (max) timing requirement
4581: WARNING : Clock domain between hdmi_tx_slow_clk (rising) and core_clk (rising) may not meet (slack: -3.589 ns) the setup (max) timing requirement
```

### 2.2 Hold（Min）：全部通过

`timing.rpt:78-95`，16 对关系的最小 slack 是 `core_clk→hdmi_tx_slow_clk` 的 **+0.008 ns**（`:82`），`hdmi_tx_slow_clk→core_clk` 为 +0.017 ns（`:94`）。**没有 hold 违规。**（PnR 早期版本有过 hold 违规，`efx_pnr.log:2997-3003`，已被工具自动修复；`out\mmt.hold_fixing.rpt` 最终为空表。）

### 2.3 关于"条数"的重要说明

`mmt.timing.rpt` 的第 3/4 节是"**Critical Paths**"（关键路径），**每个时钟对只列最多 10 条**：例如 `core_clk vs core_clk` 这种同域关系只列 10 条，但显然逻辑上远超 10 条；而 `tx_cal_clk_90edge vs tx_cal_clk` 只列了 1 条（说明该对确实只有 1 条）。因此对本工程：

- 可见失败条数 = **20**（2 对 × 10）；
- 真实失败条数**无法从报告直接得到**，只能给 RTL 上限：跨域进入同步器第一级的 D 引脚共 **≤110 条**（系统域→视频域，15 个 `mmt_sync2` 的位宽之和 = 8+16+8+5+5+5+8+1+16+1+16+1+16+3+1）与 **≤134 条**（视频域→系统域，9 个 `mmt_sync2` = 32+32+32+8+8+8+9+4+1）。
- 由于这 2 对关系的约束是 0.001 ns（见第 4.2 节），**只要落在该关系里的路径几乎必然全灭**，所以 WNS/TNS 的量级远大于报告展示的 20 条。

### 2.4 20 条失败路径明细（附录式）

`hdmi_tx_slow_clk → core_clk`（10 条，全部起于 `sy_body_max_t[2]~FF|CLK`）：

| # | 报告行 | Slack | Data Delay | Logic Level | 终点 |
|---|---|---|---|---|---|
| P1 | 108 | -3.589 | 3.310 | 6 | `u_sy_ct/s1[3]~FF\|D` |
| P2 | 189 | -3.589 | 3.310 | 6 | `u_sy_ct/s1[6]~FF\|D` |
| P3 | 270 | -3.589 | 3.310 | 6 | `u_sy_ct/s1[7]~FF\|D` |
| P4 | 351 | -3.589 | 3.310 | 6 | `u_sy_ct/s1[5]~FF\|D` |
| P5 | 432 | -3.587 | 4.320 | 15 | `u_sy_sc/s1[8]~FF\|D` |
| P6 | 558 | -3.587 | 4.320 | 15 | `u_sy_sc/s1[8]~FF\|D` |
| P7 | 684 | -3.587 | 4.320 | 15 | `u_sy_sc/s1[8]~FF\|D` |
| P8 | 810 | -3.587 | 4.320 | 15 | `u_sy_sc/s1[8]~FF\|D` |
| P9 | 936 | -3.586 | 3.307 | 7 | `u_sy_ct/s1[7]~FF\|D` |
| P10 | 1022 | -3.586 | 3.307 | 7 | `u_sy_ct/s1[5]~FF\|D` |

`core_clk → hdmi_tx_slow_clk`（10 条，**全部 Logic Level = 0，即源触发器 Q 到同步器 D 之间是一根纯线**）：

| # | 报告行 | Slack | Data Delay | Logic Level | 起点 → 终点 |
|---|---|---|---|---|---|
| P1 | 2593 | -1.225 | 1.823 | **0** | `cfg_diff_thr[4]~FF\|CLK` → `u_sy_dthr/s1[4]~FF\|D` |
| P2 | 2646 | -1.220 | 1.818 | 0 | `cfg_body_max_t[8]~FF\|CLK` → `u_sy_body/s1[8]~FF\|D` |
| P3 | 2699 | -1.207 | 1.805 | 0 | `cfg_vision_prob[5]~FF\|CLK` → `u_sy_vprob/s1[5]~FF\|D` |
| P4 | 2752 | -1.181 | 1.779 | 0 | `cfg_body_max_t[0]~FF\|CLK` → `u_sy_body/s1[0]~FF\|D` |
| P5 | 2805 | -1.156 | 1.754 | 0 | `cfg_body_max_t[3]~FF\|CLK` → `u_sy_body/s1[3]~FF\|D` |
| P6 | 2858 | -1.125 | 1.229 | 0 | `cfg_body_max_t[14]~FF\|CLK` → `u_sy_body/s1[14]~FF\|D` |
| P7 | 2911 | -1.120 | 1.224 | 0 | `cfg_ambient_t[12]~FF\|CLK` → `u_sy_amb/s1[12]~FF\|D` |
| P8 | 2964 | -1.119 | 1.591 | 0 | `cfg_rh_x100[11]~FF\|CLK` → `u_sy_rh/s1[11]~FF\|D` |
| P9 | 3017 | -1.114 | 1.218 | 0 | `cfg_vision_prob[7]~FF\|CLK` → `u_sy_vprob/s1[7]~FF\|D` |
| P10 | 3070 | -1.114 | 1.218 | 0 | `cfg_env_valid~FF\|CLK` → `u_sy_envv/s1[0]~FF\|D` |

`core_clk → hdmi_tx_slow_clk` 的 P1 数据通路原文（`timing.rpt:2627-2634`）只有 3 行，是决定性证据：

```
cfg_diff_thr[4]~FF|Q    EFX_FF   0.130   (68,299)
cfg_diff_thr[4]         net      1.823   (68,299)
u_sy_dthr/s1[4]~FF|D    EFX_FF   0.003   (64,286)
```

---

## 3. RTL 里这两个信号是什么、捕获侧有没有同步器

### 3.1 起点：`sy_body_max_t`（视频域寄存器）

- `mmt_top.v:1615` 声明；`mmt_top.v:1630` 由 `mmt_sync2 u_sy_body` 从系统域同步到 **`hdmi_tx_slow_clk`（视频域）**，输出就是 `sy_body_max_t`。
- `mmt_top.v:1686` 把它送进 `u_algo`（`.body_max_c_x10`），`u_algo` 的 `clk` = `hdmi_tx_slow_clk`（`mmt_top.v:1665`）。
- 所以 `sy_body_max_t[2]~FF` 是**视频域**寄存器，合理。

### 3.2 终点：`u_sy_ct/s1[3]`（系统域**第一级同步触发器**）

- `mmt_top.v:1717`：`mmt_sync2 #(.WIDTH(8)) u_sy_ct (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_conf_t), .q_b(alg_conf_t_s));`
- `mmt_sync2` 的实现（`rtl\mmt\common\mmt_sync2.v:30-40`）：

```verilog
30:    reg [WIDTH-1:0] s1;
32:    always @(posedge clk_b or negedge rst_n_b) begin
34:        if (!rst_n_b) begin s1 <= RESET_VAL[...]; q_b <= RESET_VAL[...]; end
37:        else begin s1 <= d_a;  q_b <= s1;  end      // s1 = 第 1 级（吃异步输入）, q_b = 第 2 级
```

**`s1` 就是两级同步器的第一级**，它的 D 引脚直接接异步输入 `d_a`，这正是 CDC 路径**应当**出现的位置。报告里的 `Path End` 全部落在 `*/s1[..]~FF|D`，说明工具看到的就是"异步源 → 同步器第一级"。

### 3.3 完整的数据通路（为什么 `u_sy_ct` 的路径起点在视频域）

`timing.rpt:142-177` 的 Data Path：

```
sy_body_max_t[2]~FF|Q  →  LUT__130682 → LUT__130683 → LUT__130684 → LUT__138221
  → u_algo/u_fusion/t_dev[11] → u_algo/u_fusion/mult_13|A[11] (EFX_DSP48, 1.312ns)
  → u_algo/u_fusion/mult_13|O[7] → u_algo/u_fusion/t_mul[7] → LUT__130715
  → alg_conf_t[3] → u_sy_ct/s1[3]~FF|D
```

即：视频域里 `u_algo/u_fusion`（`mmt_top.v:1659-1703`，`clk=hdmi_tx_slow_clk`）组合计算出 `alg_conf_t`（`mmt_top.v:1698`），然后直接进 `core_clk` 域的同步器第一级。**两级同步器在，缺的只是"这对时钟是异步的"这个声明。**

---

## 4. 判定：为什么是"约束缺失"，不是"真 CDC bug"

### 4.1 证据一：20 条失败路径的终点 100% 是同步器第一级

见 2.4 节两张表——终点清一色 `u_sy_*/s1[*]~FF|D`，**没有一条**落在普通功能触发器上。如果捕获侧真的缺同步器，报告里必然出现"终点是功能 FF"的路径。

### 4.2 证据二：`Constraint = 0.001` 是"工具算出来的假约束"

`timing.rpt:59-76` 的 Setup Clock Relationship 共 16 行，逐行核对可知：**其它 15 行的约束都等于两个时钟周期的较小值**（10.000 / 2.500 / 7.143 / 14.286 / 20.000 / 200.000），**唯独**这两行是 `0.001`：

```
L63: core_clk          hdmi_tx_slow_clk   0.001   -1.225
L75: hdmi_tx_slow_clk  core_clk           0.001   -3.589
```

算术对得上（周期取自报告自身 `L31/L39`：`core_clk = 10.000 ns`、`hdmi_tx_slow_clk = 7.143 ns`）：

```
7 × 7.143 = 50.001 ns      （7 个 140MHz 周期）
5 × 10.000 = 50.000 ns     （5 个 100MHz 周期）
两者在公共周期末端几乎重合，最小正边沿间距 = 50.001 − 50.000 = 0.001 ns  ← 报告里的 Constraint
```

**推断（说明白：这是对工具算法的推断，不是报告直接写出来的）**：因为 SDC 没把这两个时钟声明成异步/互斥，Efinity 的 STA 把它们当成"有确定相位关系的同步时钟"，在 50 ns 公共周期上做展开波形分析，取到了那对几乎重叠的边沿，于是要求所有跨域路径在 **0.001 ns** 内到达——这是一个物理上不可能满足的约束，-3.589 ns 就是这么来的。

另一个同样成立的读法：`0.001` 是工具对"未声明关系的时钟对"给出的近零缺省值。**两种读法的修法完全一样**（声明异步），且都不改变"这不是缺同步器"的判定。

反证：如果真是 RTL 缺同步器，那么第三方工具、以及 PnR 自己都不会只在这 2 对关系上报违规——而 `out\mmt.cdc.rpt` 明确说 **"No Synchronizer warnings to report."**（`mmt.cdc.rpt:5`），该报告的检查对象正是"驱动同步器输入的数据通路之间的 skew"（`mmt.cdc.rpt:2-3`），说明工具**识别出了这些同步器结构**且没有发现结构性问题。

### 4.3 证据三：综合没有把同步器优化掉（两级都在）

用 `out\mmt.map.rpt` 与 `out\mmt.hier_util.rpt` 的资源数独立核对（`mmt_sync2` 是 2 级 × WIDTH 个 FF，所以"2×WIDTH"才是完整的两级）：

| 实例 | RTL 位宽 | map.rpt / hier_util 资源 | 是否 = 2×WIDTH |
|---|---|---|---|
| `u_sy_dthr` | 8（`mmt_top.v:1622`） | 16 (`mmt.map.rpt:4973`) | ✅ |
| `u_sy_vprob` | 8（`:1628`） | 16（`map.rpt:4974`） | ✅ |
| `u_sy_vvald` | 1（`:1629`） | 2（`:4975`） | ✅ |
| `u_sy_body` | 16（`:1630`） | 32（`:4976`） | ✅ |
| `u_sy_irv` | 1（`:1631`） | 2（`:4977`） | ✅ |
| `u_sy_amb` | 16（`:1632`） | 32（`:4978`） | ✅ |
| `u_sy_envv` | 1（`:1633`） | 2（`:4979`） | ✅ |
| `u_sy_rh` | 16（`:1634`） | 32（`:4980`） | ✅ |
| `u_sy_ct` | 8（`:1717`） | 16（`:4991`） | ✅ |
| `u_sy_sc` | 9（`:1719`） | 18（`:4993`） | ✅ |
| `u_sy_area` / `u_sy_sumx` / `u_sy_sumy` | 32（`:1713-1715`） | 64 / 64 / 64（`:4987-4989`） | ✅ |
| `u_sy_ftgl` | 1（`:1739`） | 2（`:4994`） | ✅ |
| `u_sy_bgclr` | 1（`:1648`） | 2（`:4981`） | ✅ |

也就是说：**只要该位被真正使用，两级触发器都活着**（16 = 2×8、32 = 2×16、64 = 2×32、18 = 2×9、2 = 2×1）。没有出现"位宽 N 只剩 N 个 FF"（那是第一级被吞掉的典型症状）。

另外，`out\mmt.map.rpt` 的"被优化掉的寄存器"清单共有 2123 条 optimized to 0 / 309 条 merged to equivalence / 214 条 unreachable，其中**只有一处**牵涉我们的同步器：

```
'u_sy_ce/s1[0]' (rtl\mmt\common\mmt_sync2.v:30) (merged to equivalence)
'u_sy_ce/s1[1]' ... 'u_sy_ce/s1[2]' ... 'u_sy_ce/s1[5]' ... 'u_sy_ce/s1[6]' ... 'u_sy_ce/s1[4]'   （共 6 位）
```

`u_sy_ce`（`:1718`，WIDTH=8）最终只剩 4 个资源（`map.rpt:4992`）= **2 位 × 2 级**，说明它的第 0/1/2/4/5/6 位在上游是等价的（被合并），留下 3、7 两位仍是完整两级。**没有任何同步器的第二级 `q_b` 被删除**（清单里没有任何 `/q_b` 条目）。结论：本次综合**没有**破坏同步器结构。

> 防御性建议（非必需）：给 `mmt_sync2` 的两个寄存器加 `(* async_reg = "true" *)`（或 Efinity 的等价属性）可以彻底消除"未来被综合工具合并/重定时"的风险。就用当前这次 run 的实证看，**不加也没有出问题**，所以它不是本次时序失败的原因。

### 4.4 声明异步是否安全？——逐信号检查

`set_clock_groups -asynchronous` 会把这两个域之间的**所有**路径从不分析（相当于 false path）。所以必须确认：两域之间**没有**"本该被检查却没同步器"的数据通路。逐信号核对结果（`mmt_top.v`）：

**系统域 → 视频域**（15 个同步器，全部 `clk_b = hdmi_tx_slow_clk`）：
`u_sy_dthr`(1622)、`u_sy_marea`(1623)、`u_sy_sthr`(1624)、`u_sy_ast`(1625)、`u_sy_aen`(1626)、`u_sy_hour`(1627)、`u_sy_vprob`(1628)、`u_sy_vvald`(1629)、`u_sy_body`(1630)、`u_sy_irv`(1631)、`u_sy_amb`(1632)、`u_sy_envv`(1633)、`u_sy_rh`(1634)、`u_sy_ctrl`(1635)、`u_sy_bgclr`(1648)。
所有 `cfg_*` 信号（`mmt_top.v:1382-1394`）除上述同步器外，只被系统域模块使用；对 `cfg_*` 的全文件检索没有发现第二种跨域用法。

**视频域 → 系统域**（9 个同步器，全部 `clk_b = core_clk`）：
`u_sy_area`(1713)、`u_sy_sumx`(1714)、`u_sy_sumy`(1715)、`u_sy_cv`(1716)、`u_sy_ct`(1717)、`u_sy_ce`(1718)、`u_sy_sc`(1719)、`u_sy_fl`(1720)、`u_sy_ftgl`(1739)。
`u_algo` 的全部输出（`alg_sum_area/sum_x/sum_y/conf_v/conf_t/conf_e/score/alarm/in_auth/motion_done/motion_flag/frame_tgl`）在顶层**只**作为这些同步器的 `d_a` 使用（1721、1740 行），没有第二条直连路径。

**BRAM 跨域**：`u_osd_txt_ram`(`:1333`)、`u_osd_th_ram`(`:1344`) 用 `mmt_dpram_2clk`，A 口（写）= `core_clk`、B 口（读）= `hdmi_tx_slow_clk`，两侧的地址/数据都由各自域的模块产生（`osd_txt_we/addr/data` 来自系统域 SoC 子系统；`osd_txt_rd_addr` 来自视频域 `u_osd`），跨域由 BRAM 原语内部完成 —— 不构成 FF→FF 数据通路。

**"假 CDC"的规模校验**：这 20 条失败路径的数据延迟分别是 1.2～4.32 ns，都**小于源时钟周期**（系统域 10 ns / 视频域 7.143 ns）。也就是说源寄存器每周期只更新一次，组合逻辑在一个源周期内就能送到同步器输入端 —— 这正是"源域普通路径 + 同步器输入"的正常形态，不是"一条超长组合路径恰好跨了域"。

**并且**：声明异步**不会**取消同步器内部的 `s1 → q_b` 检查（那是捕获域内的同域路径），这些同域路径现在也都是正 slack（`core_clk→core_clk` +3.430、`hdmi_tx_slow_clk→hdmi_tx_slow_clk` +1.465）。

**唯一一条被"顺带屏蔽"的真实缺陷**（必须知道）：`alg_alarm_s`（系统域）在 `mmt_top.v:1376` 被送进视频域的 `u_osd`（`.alarm`），而 `mmt_osd_overlay.v:160` 直接组合使用它：`wire show_border = alarm & in_border;` —— 这条通路上**没有**同步器，是"视频→系统→视频"的往返跨越。它本身也是这次 0.001 ns 约束下的违规路径之一（在 `core_clk→hdmi_tx_slow_clk` 关系里，只是没排进前 10）。修法见第 5 节 P1（一行 RTL，改成用视频域原信号），**建议与 SDC 修改一起做**。

---

## 5. 修复清单（按优先级）

### P0 — 约束补丁（**已应用**）

- 文件：`D:\FPGA\mmt\constr\ti60f225_oob.sdc`，新增第 29–37 行，生效语句在第 **37** 行：

```tcl
set_clock_groups -asynchronous -group {core_clk} -group {hdmi_tx_slow_clk}
```

- 为什么用 `-asynchronous` 而不是 `-exclusive`：`mmt.peri.xml:354` / `:341` 证明两者是**两个不同 PLL 实例**的输出，物理上就是异步关系（`-exclusive` 语义是"互斥、不同时存在"，对两个同时在跑的时钟是措辞不当）。Efinity 自身也使用该写法：`D:\Efinity\2026.1\...\ti375n1156_ea_oob.pt.sdc:26` 就是非注释的 `set_clock_groups -asynchronous ...`；本 SDC 第 84 行的注释模板同样给出该语法。若重跑报语法错误，退路是同等效果的 `set_clock_groups -exclusive -group {core_clk} -group {hdmi_tx_slow_clk}`（与本文件第 26 行风格一致，且第 26 行已被证实在本工程生效——因为 `core_clk`×`vid_clk_dvi2` 之间报告里一条路径都没有）。
- 为什么不采用"把 `hdmi_tx_slow_clk` 塞进第 26 行的大 exclusive 组"：那会**同时**把 `vid_clk_dvi2` 与 `hdmi_tx_slow_clk` 声明成互斥，而这两个是**同一个 USER_PLL** 的输出（`:340`/`:341`）、存在真实的 2:1 同步路径（`timing.rpt:7523` 起的 `vid_clk_dvi2 vs hdmi_tx_slow_clk`，+3.741 ns），那是**必须保留**的检查。只针对这一对时钟写一条，是最小改动。
- 预期效果：`timing.rpt` 里 `hdmi_tx_slow_clk vs core_clk` / `core_clk vs hdmi_tx_slow_clk` 两节消失，`Setup (Max) Clock Relationship` 里两行 0.001 消失；WNS 变为 **+3.430 ns**（`core_clk→core_clk`，`timing.rpt:61`），hold 最小 +0.008 ns。`efx_pnr.log:4580-4581` 两条 WARNING 应消失。
- **是否需要重跑**：**必须**。约束变更只有重跑 `efx_map` + `efx_pnr` 才能验证。

### P1 — RTL 一行：去掉 `alg_alarm_s` 的视频域反灌

- 文件/行：`rtl\mmt\mmt_top.v:1376`
- 现状：`.alarm (alg_alarm_s)`（`alg_alarm_s` 是系统域同步后的信号，定义在 `:1726`）
- 改成：`.alarm (alg_alarm)` —— `alg_alarm` 是 `u_algo` 的视频域原始输出（`mmt_top.v:1702`），`u_osd` 本身就跑在视频域（`:1358`），这样这条路径**根本不跨域**，比"再加一级同步器"更省资源也更不容易出错。
- 依据：`mmt_osd_overlay.v:92` 端口声明、`:160` `wire show_border = alarm & in_border;`（组合使用，无同步）。
- 预期效果：消除 1 条不同步的 core→视频 通路；功能无变化（报警红框显示）。
- 是否需要重跑：需要（RTL 变更）。
- 为何只降级为 P1：它不是 -3.589 的成因，而且声明异步后它就会被"顺带屏蔽"；但从 CDC 正确性角度必须修，否则是隐患。

### P2 — 多比特总线按位同步的相干性（作者已自述，本次不新增判定）

- 位置：`rtl\mmt\common\mmt_sync2.v:6-14` 的告警注释 + `mmt_top.v:1286-1292` 的"已知 bring-up 级局限"。
- 现状：`alg_sum_area/sum_x/sum_y`(32b)、`alg_score`(9b) 等**多比特数值**按位打两拍，理论上可能采到"从未存在过的中间值"。
- 现有的缓解：`alg_frame_tgl` 单比特翻转标志（`mmt_top.v:1733-1740`）+ 软核"只在标志变化时才读数据"（注释 `:1728-1732`）。这个方案只有在"数据在帧结束时一次性更新"的前提下才成立。
- 建议（正式版）：帧结束时把整组读数锁存进快照寄存器，用单比特 req/ack 握手把快照搬过去；或对总线用格雷码/异步 FIFO。
- 本次**不判定**其实际危害（需要仿真或上板才能定量），列为已知局限。是否重跑：改 RTL 才需要。

### P3 — 一致性：`tx_cal_clk_90edge` 也没被 cut（可选，不改）

- `tx_cal_clk_90edge` 与 `sdram_clk`/`rx_cal_clk`/`tx_cal_clk` 来自同一个 DDR3 PLL（`mmt.peri.xml:325-328`），后三者都在第 26 行被声明互斥，唯独 `tx_cal_clk_90edge` 不在（同样地，厂商官方 demo `工作区\07_官方demo工程\_ddr_demo_ti60\sdc\ddr3.sdc:10-13` 里 `core_clk` 是被单独 `set_clock_groups -group {core_clk}` 屏蔽掉与全体的关系的）。
- 相关路径现状：`core_clk vs tx_cal_clk_90edge` 最差 **+0.897 ns**（`timing.rpt:62`，起点 `u_ddr3_top/u_phy_top/dqs_invert~FF|CLK`，终点 `ddr_dq_out_*~FF|D`）；反向 `+1.699 ns`（`timing.rpt:64`，起点是 `efx_fifo_ctl` 里的格雷码读地址计数器）。**当前都通过，所以本次不动**——保持"多检查比少检查安全"。如果后续有人为了对齐厂商风格要 cut 它，必须先确认那些 DDR PHY 内部路径确实有同步/FIFO 保护。

### P4 — 文档/注释一致性（零风险，建议顺手改）

- `rtl\mmt\mmt_top.v:1281`、`mmt_top.v:1287`（"core 周期 10ns > video 周期 6.7ns"）、`协作日志.md:1146` 里写的 **148.5MHz** 与实际约束的 **139.997MHz（7.143 ns）** 不一致。请统一为 140MHz / 7.143 ns，其中 `6.7ns` 应改成 `7.14ns`（这个数字还被用来论证 `bg_clear` 会丢脉冲的逻辑，值错了论证也跟着错）。
- 需要重跑：不需要（纯注释）。

---

## 6. 重跑后的验收标准（给 Lead）

重跑 `efx_map` + `efx_pnr` 后，按顺序核对：

1. `out\mmt.timing.rpt`：
   - 搜索 `Slack` 后不应再出现负值（`Select-String -Path out\mmt.timing.rpt -Pattern '^Slack\s*:\s*-'` 应为空）；
   - `Setup (Max) Clock Relationship` 表里不应再有 `0.001` 约束、不应再有 `hdmi_tx_slow_clk` 与 `core_clk` 的组合行；
   - 最差 slack 应为 `core_clk → core_clk` 的约 +3.4 ns。
2. `out\efx_pnr.log`：不应再出现 `may not meet ... setup (max)` 的 `Clock domain between ... hdmi_tx_slow_clk` 告警（原为 4580/4581 行）。
3. `out\mmt.cdc.rpt`：应仍为 "No Synchronizer warnings to report."（如果突然出现同步器告警，说明改动引入了新问题，要停下来看）。
4. `out\mmt.hold_fixing.rpt`：应仍为空表（无 hold 修复需求）。
5. 资源占用允许有少量变化（PnR 少了 20+ 条不可能满足的路径后布局会变），但 XLR 不应显著上涨（原 45475/60800）。

> ⚠️ 注意：`constr\ti60f225_oob.sdc` 是 **Interface Designer 生成**的文件（其内容与 `mmt.peri.xml` 对应）。如果以后重新生成接口/`peri.xml`，**这条新增声明会被覆盖丢失**，需要重新加上。是否能把用户约束放到独立的第二个 `.sdc`，本次未验证（`mmt.xml:127` 当前只有一个 `<efx:sdc_file name="constr/ti60f225_oob.sdc"/>`）；`efx_pnr.log:338-349` 的 SDC warning 也证实本次流程只读了这一个文件。

---

## 7. 不确定项 / 无法确认

1. **"Constraint = 0.001" 的确切来源**：4.2 节的算式（7×7.143−5×10 = 0.001）与报告数值精确吻合，但工具内部算法无法从报告直接证实；"这是未声明关系时的近零缺省值"这一读法同样无法证实。**两种读法的修法一致**，不影响 P0。
2. **真实失败路径条数**：报告每对只列 10 条，无法从报告得到精确值；只能给 RTL 上限（≤110 / ≤134 条）。若需精确数字，可在 Efinity STA 里把每个关系的报告条数上限调大后重跑，或从 PnR 的 TNS 字段读取（当前报告未输出 TNS）。
3. **`u_sy_ce` 有 6 位被 "merged to equivalence" 后只剩 2 位（`map.rpt:4992`）**：结果是"2 位 × 2 级 = 4 个资源"，结构完好；但这 6 位为什么与其它逻辑等价（上游 `alg_conf_e` 某些位是否恒定/冗余）**未查清**，不影响本次判定。
4. **是否存在报告前 10 之外的、终点不是同步器的 core↔hdmi 路径**：RTL 层面我把 `cfg_*`、`alg_*`、BRAM 两侧端口全部走了一遍，只找到 `alg_alarm_s` 一条（第 4.4 节末）。但我**无法**从报告证明没有第 11 条——这是"RTL 静态排查"的固有局限，建议 P1 修完后重跑，看新报告里两域是否彻底干净。
5. **`vid_clk_dvi2 → hdmi_tx_slow_clk` 的像素通路**（`rgb_datax2` 在 `mmt_top.v:1067-1069` 被 `hdmi_tx_slow_clk` 采样）是厂商 demo 的同源 PLL 同步设计，当前 slack +3.741 ns 通过。我**没有**深入验证它在 2:1 关系下的相位是否真的安全（属于厂商 IP 范畴），仅记录为观察项。
6. **`mmt.peri.xml` 里 PLL 的 `multiplier/post_divider` 与 SDC 周期数值不能直接对应**（例如 `MIPI_TX_PLL` multiplier=4/pre_div=1/post_div=2、`out_divider=20` 无法直接算出 100MHz）。我因此**没有**从 divider 反推频率，而是直接采用 SDC/报告里的 10.000 ns 与 7.143 ns。频率的最终依据仍是 SDC，若有人要改时钟，请连同 `mmt.peri.xml` 一起核对。

---

## 附录 A — 关键证据索引（可逐条核对）

| # | 结论 | 证据位置 |
|---|---|---|
| 1 | 唯一失败关系是 core_clk ↔ hdmi_tx_slow_clk | `out\mmt.timing.rpt:59-76`；`out\efx_pnr.log:4580-4581` |
| 2 | 最差 slack -3.589，约束 0.001 | `out\mmt.timing.rpt:114`、`:126` |
| 3 | 终点是同步器第一级 `s1` | `rtl\mmt\common\mmt_sync2.v:30,37`；`out\mmt.timing.rpt:111` 等 20 处 |
| 4 | 起点在视频域、数据经 `u_fusion` 组合逻辑 | `out\mmt.timing.rpt:145-177`；`rtl\mmt\mmt_top.v:1665,1698,1717` |
| 5 | `core_clk→hdmi` 路径是纯线（Logic Level 0） | `out\mmt.timing.rpt:2600-2634` |
| 6 | 两级同步器都活着（2×WIDTH 资源） | `out\mmt.map.rpt:4973-4994`；`out\mmt.hier_util.rpt:459-471` |
| 7 | 没有 q_b 被删除；只有 u_sy_ce 6 位等价合并 | `out\mmt.map.rpt` 的优化清单（309 行 merged to equivalence） |
| 8 | 工具认为同步器结构无问题 | `out\mmt.cdc.rpt:2-5` |
| 9 | 两个时钟来自两个不同 PLL | `mmt.peri.xml:341`（USER_PLL）、`:354`（MIPI_TX_PLL） |
| 10 | SDC 第 26 行的互斥组漏了 hdmi_tx_slow_clk，且该组确实生效 | `constr\ti60f225_oob.sdc:25-27`；报告里没有 `core_clk vs vid_clk_dvi2` 一节 |
| 11 | 只读了一个 SDC 文件 | `mmt.xml:127`；`out\efx_pnr.log:338-349` |
| 12 | hold 全部为正 | `out\mmt.timing.rpt:78-95`；`out\mmt.hold_fixing.rpt`（空） |
| 13 | `alg_alarm_s` 反灌视频域且无同步器 | `rtl\mmt\mmt_top.v:1376`（`.alarm(alg_alarm_s)`）、`:1726`；`rtl\mmt\osd\mmt_osd_overlay.v:92,160`（`wire show_border = alarm & in_border;`） |
