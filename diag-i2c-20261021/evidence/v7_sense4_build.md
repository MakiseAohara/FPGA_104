# v7_SENSE4 构建记录 —— 2026-10-21 18:10–18:17

> **✅ 构建成功：5 步全部通过（exit 0 / PASS），最终签核时序 18 条 setup + 18 条 hold 全部为正、0 条负 slack，位流已生成。**
> **本轮未烧录**（板上仍是 v7_SENSE2）。
> 改动来源：指挥官提供 `v7_mmt_core.v`（覆盖）+ `v7_freeze_ctl.v`（新增），sha256 均已核对通过；`ti60f225_oob.xml` 按字节安全方式加 1 行。
> 目的：视觉背景自动重学（解除"永久误判运动"死锁）+ 红外热点门控（报警必须同时看到红外热点）。

---

## 0. 任务与边界

- 任务：以 `D:\v7work\v7_SENSE3` 为源构建 **v7_SENSE4**（只编译，不烧录）。
- 授权边界：不改 RTL/约束（本指令指定的覆盖/新增/加一行除外）；不烧录；不 push；不删文件。
- 构建路径：`D:\v7work\v7_SENSE4`（纯 ASCII）。

---

## 1. 入参文件 sha256 核对（指令步骤 1，硬门槛）✅

来源目录：`D:\FPGA\mmt\sim\v7_sys3\`

| 文件 | 期望 sha256 | 实测 sha256 | 大小 | 判定 |
|---|---|---|---|---|
| `v7_mmt_core.v` | `6bf3fd4ae62afccc57097eee2c79833e2c167b2a725c3a93b17ab563b063e618` | 同左 | 8,819 B | **MATCH** |
| `v7_freeze_ctl.v` | `87b2e2416156adf9933f5304c7d54ee17cd6ae5c0488debcc715413a320e411b` | 同左 | 1,321 B | **MATCH** |

两个文件均**按字节复制**（未改内容），覆盖/新增后再次核对 sha256 一致。

---

## 2. 复制与三处改动（指令步骤 2–5）✅

### 2.1 复制

| 项 | 值 |
|---|---|
| 源 | `D:\v7work\v7_SENSE3` |
| 目标 | `D:\v7work\v7_SENSE4`（构建前 `Test-Path` = **False**，全新目录） |
| 方式 | `robocopy /E`，排除 `out\`、`work_syn\`、`work_pnr\`、`outflow\`、`flow_console.log`、`*.gtkw`；robocopy exit=1（正常） |
| 复制后核对 | 源 164 / 目标 164 文件；仅源有 0、仅目标有 0、内容不同 0 |

### 2.2 全树 diff：**恰好 3 处变化** ✅

| # | 变化类型 | 文件 | SENSE3 | SENSE4 |
|---|---|---|---|---|
| 1 | 内容不同 | `rtl\mmt\v7_mmt_core.v` | sha `94B84886…5877`，7,764 B，123 行 | sha `6BF3FD4A…E618`，8,819 B，132 行（= 指挥官版本） |
| 2 | 新增 | `rtl\mmt\v7_freeze_ctl.v` | 不存在 | sha `87B2E241…411B`，1,321 B |
| 3 | 内容不同 | `ti60f225_oob.xml` | sha `DD827C67…B72F`，15,680 B | sha `D0903DB5…5E1`，15,774 B |

- `debug_top.v` **未变**：sha256 `04BA516729384A13261F302382CF6CF11DA1F35AD6139C586502EBB533E114DB`，L102–104 仍为 `'h158 / 'h110 / 'h188`（G、B 继承 SENSE3）。
- 只读 diff 摘要（`v7_mmt_core.v` SENSE3→新版）：新增参数 `AI_MODE / FREEZE_MAX / HOT_ON / REQUIRE_IR`、新增输入 `ai_person`、实例化 `v7_freeze_ctl u_fz`、`ir_hot` 打拍、`alarm_gate = alarm_raw & fd_motion & (REQUIRE_IR ? ir_hot : 1)`、`vision_prob` 按 `AI_MODE` 选择；原 `bg_freeze <= fd_motion` 由 `v7_freeze_ctl` 输出替代。（只读比对，未改内容）

### 2.3 `ti60f225_oob.xml` 字节级插行（保持编码/换行符）✅

- 原文件：**纯 ASCII、LF 换行**（15,680 B，194 行，0 个 CR）。
- 目标行：原 **L58** `        <efx:design_file name="rtl/mmt/v7_frame_diff.v" version="default" library="default"/>`（起始偏移 5723，行尾 LF 偏移 5816）。
- 做法：`[System.IO.File]::ReadAllBytes` → 在 LF(5816) 之后插入 **94 字节**（93 字节新行 + 1 LF）→ `WriteAllBytes`，全程无文本编码转换。
- 新增行（现 **L59**，缩进 8 空格，与原文一致）：
  `        <efx:design_file name="rtl/mmt/v7_freeze_ctl.v" version="default" library="default"/>`
- **字节回验**：前缀字节一致=True、插入段一致=True、后缀字节一致=True；行数 194→195；逐行对照"不符行数 = **0**"。
- 证据快照：`...\evidence\v7_abc2\SENSE4\xml_patch_verify.txt`。

---

## 3. 构建（指令步骤 6）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\v7_flow.ps1 `
  -Work D:\v7work\v7_SENSE4 -Tag SENSE4
```

| 步 | 结果 |
|---|---|
| [1] `efx_map` | **exit 0** |
| [2] `efx_pnr#1` | **exit 0** |
| [3] `efx_run -f interface` | **interface : PASS** |
| [4] `filter_interface` | **wrote 481 lines**（与 SENSE3 同） |
| [5] `efx_pnr#2 --sync_file` + bitgen | **exit 0**；整体 **FLOW_EXIT=0** |

- 耗时：**18:10:20 → 18:17:22 = 7 分 02 秒**；阶段落盘：`map.log` 18:12:29、`pnr1.log` 18:14:11、`interface.csv` 18:14:40、`pnr2.log` 18:17:19、`.bit` 18:17:21。
- `map.log` / `pnr1.log` / `pnr2.log` 中 `ERROR` 行 = **0**。

---

## 4. 四项验收结果

| # | 验收项 | 要求 | 实测 | 判定 |
|---|---|---|---|---|
| 1 | 5 步退出 | 全 exit 0 | [1][2][5]=0；[3]=PASS；[4] wrote 481 lines；FLOW_EXIT=0 | ✅ |
| 2 | 时钟约束 | `No valid pin(s) found for clock` = 0；`No clocks matched` = 87 | **0 / 87** | ✅ |
| 3 | 时序 | 所有时钟域 setup/hold 全正；记录 hdmi 域 | **18 setup + 18 hold 全正，0 条负 slack**；hdmi 内 setup **+0.411 ns** / hold **+0.029 ns** | ✅ |
| 4 | 资源 | 对照 SENSE3：XLR 30,812 / Memory 118 / DSP 15；BRAM/DSP 不得变 | **XLR 31,624（+812）/ Memory 118（0）/ DSP 15（0）** | ⚠️ BRAM/DSP 未变 ✅；XLR 总量 +812 的归因见 §5（新增逻辑仅 +83） |

---

## 5. 资源归因（XLR +812 从哪来，重要）

> 指令预期"新增逻辑只多几十到一两百"。实测**新增逻辑确实只 +83**；总量 +812 的主要来源是**未改动模块的综合波动**，不是本轮的逻辑增量，也不是意外推断（BRAM/DSP 未变）。

| 对象 | SENSE2 | SENSE3 | **SENSE4** | SENSE3→SENSE4 | 说明 |
|---|---|---|---|---|---|
| 顶层 XLR | 31,306 | 30,812 | **31,624** | **+812** | — |
| `u_v7_mmt`（本轮改动所在子树） | 2,636.5 | 2,598.5 | **2,681.5** | **+83** | 符合"多几十到一两百"预期 |
| 其中新模块 `u_fz`（v7_freeze_ctl） | — | — | **37** | +37 | 新逻辑实测 |
| `inst_gamma_correction`（**本轮未改**） | 11,454 | 10,994 | **11,661** | **+667** | 10,240-bit 异步读 RAM 被映射为逻辑（EFX-0657 警告，三版相同）；三版 XLR 实测 11,454 / 10,994 / 11,661 ⇒ 综合优化波动 |
| 其余全部模块合计 | — | — | — | 约 +62 | 逐模块小差值（`resource_attribution.txt` / `hier_util.rpt`） |
| Memory Blocks | 118 | 118 | **118** | 0 | — |
| DSP Blocks | 15 | 15 | **15** | 0 | — |
| 顶层 FF（xlr_ff） | 7,384 | 7,545 | **7,340** | **−205** | 未增加 |

**关键先例**：SENSE2→SENSE3 只改了两个 VIO 初值常数（无任何逻辑变化），`inst_gamma_correction` 也从 11,454 变成 10,994（−460），顶层 XLR −494 —— 说明该模块（以及全局优化结果）在不同版本间本就有数百 XLR 的波动。本轮 `gamma_correction.v` 与 SENSE3 **逐字节相同**，故 +667 与本轮改动无关。
**⇒ 判定**：无意外 BRAM/DSP 推断（二者完全不变），新增逻辑规模符合预期；XLR 总量偏差属综合波动，不是负时序、不触发指令里的"停下"条件。
**未验证**：上述波动为综合工具行为（同一 RTL 不同全局输入下结果不同），本轮未做逐线机理验证。

---

## 6. 最终时序对照表（SENSE3 vs SENSE4，hold fixing 后的 `final timing analysis`）

- SENSE4 数据来源：`D:\v7work\v7_SENSE4\out\pnr2.log` —— final timing analysis 段 `L1254–1662`；最终 Setup 表标题 `L1611`、行 `L1613–1630`；最终 Hold 表标题 `L1632`、行 `L1634–1651`（快照 `pnr2_final_timing_tables.txt`）。
- SENSE3 数据来源：`v7_SENSE3\out\pnr2.log` 同法解析；逐行对照 CSV：`...\evidence\v7_abc2\SENSE4\timing_final_SENSE3_vs_SENSE4.csv`。

### 6.1 Setup (Max) —— 18/18 全正

| # | Launch → Capture | SENSE3 (ns) | **SENSE4 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.433 | **+0.401** | −0.032 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +1.133 | **+1.170** | +0.037 |
| 3 | tx_cal_clk_90edge → core_clk | +1.672 | **+1.896** | +0.224 |
| 4 | sdram_clk → tx_cal_clk_90edge | +1.087 | **+0.750** | −0.337 |
| 5 | sdram_clk → sdram_clk | +0.460 | **+0.520** | +0.060 |
| 6 | rx_cal_clk → rx_cal_clk | +0.558 | **+0.473** | −0.085 |
| 7 | tx_cal_clk → tx_cal_clk | +0.368 | **+0.294** | −0.074 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +7.364 | **+7.359** | −0.005 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +2.049 | **+1.971** | −0.078 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.164** | **+0.411** | **+0.247** |
| 11 | core_clk → tx_cal_clk_90edge | +1.046 | **+1.091** | +0.045 |
| 12 | core_clk → core_clk | +4.273 | **+4.430** | +0.157 |
| 13 | core_clk → i_cam_ck_CLKOUT | +8.637 | **+8.836** | +0.199 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +14.049 | **+13.971** | −0.078 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +8.489 | **+7.657** | −0.832 |
| 16 | CLK_5M → CLK_5M | +196.874 | **+196.266** | −0.608 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +8.604 | **+8.574** | −0.030 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +4.947 | **+4.941** | −0.006 |
| — | **最小 setup** | +0.164 | **+0.294** | +0.130 |

### 6.2 Hold (Min) —— 18/18 全正

| # | Launch → Capture | SENSE3 (ns) | **SENSE4 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.091 | **+0.049** | −0.042 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +0.574 | **+0.553** | −0.021 |
| 3 | tx_cal_clk_90edge → core_clk | +0.164 | **+0.162** | −0.002 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.386 | **+0.572** | +0.186 |
| 5 | sdram_clk → sdram_clk | +0.094 | **+0.060** | −0.034 |
| 6 | rx_cal_clk → rx_cal_clk | +0.026 | **+0.027** | +0.001 |
| 7 | tx_cal_clk → tx_cal_clk | +0.094 | **+0.097** | +0.003 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +0.049 | **+0.079** | +0.030 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +0.123 | **+0.128** | +0.005 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.026** | **+0.029** | **+0.003** |
| 11 | core_clk → tx_cal_clk_90edge | +0.124 | **+0.198** | +0.074 |
| 12 | core_clk → core_clk | +0.029 | **+0.030** | +0.001 |
| 13 | core_clk → i_cam_ck_CLKOUT | +0.221 | **+0.113** | −0.108 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +0.026 | **+0.026** | 0 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +0.133 | **+0.150** | +0.017 |
| 16 | CLK_5M → CLK_5M | +0.045 | **+0.042** | −0.003 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +0.070 | **+0.072** | +0.002 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +0.028 | **+0.034** | +0.006 |
| — | **最小 hold** | +0.026 | **+0.026** | 0 |

### 6.3 `hdmi_tx_slow_clk` 专项（指令要求记录）

| 指标 | SENSE2 | SENSE3 | **SENSE4** | SENSE3→SENSE4 |
|---|---|---|---|---|
| hdmi 内 setup | +0.320 | +0.164 | **+0.411** | **+0.247（余量变宽）** |
| hdmi 内 hold | +0.027 | +0.026 | **+0.029** | **+0.003（略变好）** |
| 全设计最差 slack | +0.026 | +0.026 | **+0.026**（hold: rx_cal_clk=0.027、i_mipi_rx_pclk=0.026；setup 最小 +0.294） | 0 |

**⇒ 最终时序所有时钟域 setup/hold 全正，0 条负 slack。**

---

## 7. route 阶段（hold 修复前）告警如实记录

- SENSE4 `pnr2.log` `L939–944` 有 **6 条** `may not meet ... hold (min)` 告警（SENSE3 同为 6 条），其中 hdmi 域：
  `L943: hdmi_tx_slow_clk ↔ hdmi_tx_slow_clk  slack −0.703 ns`（SENSE3 同位置为 −0.324 ns）。
- 该段是**路由阶段、hold 修复前**的分析，不是最终签核：SENSE4 `Hold fix wire delay: 102`、`Pins requiring hold fix: 0.00%`（SENSE3 为 3 / 0.00%）；最终 `final timing analysis` 表中 hdmi hold = **+0.029 ns**、全表全正。
- 结论：按任务书/指令"最终时序全正"口径验收通过；此处仅作过程如实记录，不构成负时序。

---

## 8. 位流

```
路径  : D:\v7work\v7_SENSE4\out\v7_SENSE4.bit
大小  : 2,634,708 B      （SENSE3 为 2,616,858 B，本次 +17,850 B）
时间  : 2026-10-21 18:17:21
SHA256: 74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01
附属  : D:\v7work\v7_SENSE4\out\v7_SENSE4.hex（由 efx_pgm 生成）
```

- ⚠️ 位流 sha256 不可复现，仅作"这一份产物"指纹。
- **未烧录**：板上仍是 v7_SENSE2（sha256 `0F48EED8316972E4E9DF0DB15E4756385C854EF451CECB24072CFF2B8C38AB64`）。

---

## 9. 其它如实记录

| 项 | 记录 |
|---|---|
| 新增良性警告 | `map.log`：`rtl\ti60f225_oob_top.v(1039): port 'ai_person' remains unconnected for this instance [VERI-1927]`。原因：顶层实例未接该新端口，本轮指令禁止改 `ti60f225_oob_top.v`；因 `AI_MODE` 参数默认 0，`vision_prob` 的三元表达式在综合中常量折叠，不影响本轮功能（`hier_util.rpt` 显示 `u_fz` 已正常综合进去，XLR=37）。**未验证**：若以后把 `AI_MODE` 设为 1，需先连接 `ai_person`。 |
| 逻辑映射警告 | `Mapping into logic memory block` 2 条（ddr3 fifo 256 bits / gamma `r_gamma_2P` 10240 bits），与 SENSE3 完全相同 |
| 构建后源树完整性 | 165 文件（164+新增 1）与构建前清单 **0 差异**；`out\` 外无源码被回写 |
| 未验证项 | 新逻辑的功能行为（背景自动重学、红外热点门控、蜂鸣器不再常响）**只能上板观察**，本轮不烧录，故一律**未验证**；仿真结论属指挥官线（本文件不引用为事实） |

---

## 10. 证据索引

| 证据 | 路径 |
|---|---|
| 本文件 | `D:\FPGA\mmt\out\evidence\v7_sense4_build.md` |
| 构建日志 | `D:\v7work\v7_SENSE4\out\build.log`（快照 `...\evidence\v7_abc2\SENSE4\build.log.snapshot`） |
| 流程 stdout | `D:\FPGA\mmt\out\evidence\v7_abc2\SENSE4\flow_stdout.log`（含 `FLOW_EXIT=0`） |
| 最终时序原始表 | `D:\v7work\v7_SENSE4\out\pnr2.log` `L1254–1662`；快照 `...\SENSE4\pnr2_final_timing_tables.txt` |
| 时序逐行对照 CSV | `...\evidence\v7_abc2\SENSE4\timing_final_SENSE3_vs_SENSE4.csv` |
| 资源 | `D:\v7work\v7_SENSE4\out\ti60f225_oob.place.rpt`（L58/L69/L70）；归因 `resource_place_rpt.txt`、`resource_attribution.txt`、`ti60f225_oob.hier_util.rpt` |
| XML 补丁证据 | `...\SENSE4\xml_patch_verify.txt` |
| 全树 diff 证据 | `...\SENSE4\tree_diff.txt`、`sense3_manifest.csv`、`sense4_manifest_before_build.csv`、`sense4_manifest_after_build.csv` |
| 取证脚本/输出 | `...\SENSE4\collect_evidence.ps1`、`collect_evidence.log` |
| 位流 | `D:\v7work\v7_SENSE4\out\v7_SENSE4.bit` |
| 构建工具 | `D:\FPGA\mmt\tools\v7_flow.ps1`（未改） |

---

## 11. 边界声明

- **未烧录**；未 push；未 commit；未删文件。
- 只做了指令指定的三处改动：覆盖 `rtl\mmt\v7_mmt_core.v`、新增 `rtl\mmt\v7_freeze_ctl.v`、`ti60f225_oob.xml` 加一行；其余 162 个源文件与 SENSE3 逐字节相同。
- 未改 `debug_top.v`（G='h110 / B='h188 继承 SENSE3）、未改任何 SDC/约束/peri.xml、未改顶层 `ti60f225_oob_top.v`。
- 仅新增：`D:\v7work\v7_SENSE4\`（构建副本）、`D:\FPGA\mmt\out\evidence\v7_abc2\SENSE4\`（取证文件）、本文件。
