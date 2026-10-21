# v7_SENSE5 构建记录 —— 2026-10-21 21:18–21:24

> **✅ 构建成功：5 步全部通过（exit 0 / PASS），最终签核时序 18 条 setup + 18 条 hold 全部为正、0 条负 slack，位流已生成。**
> **本轮未烧录**（板上当前 = v7_SENSE4，2026-10-21 21:22 烧入）。
> 改动来源：指挥官提供 `v7_mmt_core.v`、`v7_txt_fmt.v`（覆盖）+ `v7_pwr_ctl.v`（新增），sha256 均已核对通过；`ti60f225_oob.xml` 按字节安全方式加 1 行。
> 内容：低功耗场景管理最小实现（无人 900 帧≈15 s → 低功耗，视觉处理每 4 帧取 1 帧；检出运动/红外热点立即恢复；OSD 第三行 EVT 增加 `SLEEP`）。温湿度与红外监测频率不变。
> **本文件所有数字均取自 SENSE5 本次构建的日志/报告文件，逐项注明路径（详见 §3、§9、§10）。**

---

## 0. 任务与边界

- 任务：以 `D:\v7work\v7_SENSE4` 为源构建 **v7_SENSE5**（只编译，不烧录）。
- 授权边界：不改 RTL/约束（指令指定的覆盖/新增/加一行除外）；不烧录；不 push；不删文件。
- 构建路径：`D:\v7work\v7_SENSE5`（纯 ASCII；构建前 `Test-Path` = False，全新目录）。

---

## 1. 入参 sha256 核对（硬门槛）✅

来源目录：`D:\FPGA\mmt\sim\v7_sys5\`

| 文件 | 期望 sha256（= 实测） | 大小 | 判定 |
|---|---|---|---|
| `v7_mmt_core.v` | `8e35786dbc39c760eaaaae3c4b01b0985173264d1ecbcce23227ce470c3071e3` | 9,465 B | **MATCH** |
| `v7_txt_fmt.v` | `ac7c711cbc898b95155a044d735f106db234a186072301ae9dd5d0a9501a0d54` | 5,829 B | **MATCH** |
| `v7_pwr_ctl.v` | `7624d821dd9e3f4086ce12f19e66513b4469f10c5ae25e007a995da33f1cb3ea` | 1,723 B | **MATCH** |

三个文件均**按字节复制**；覆盖/新增后再次核对 sha256 一致。证据：`...\evidence\v7_abc2\SENSE5\prep_sense5.log`。

---

## 2. 复制与全树 diff（对 SENSE4）✅

### 2.1 复制

| 项 | 值 |
|---|---|
| 源 | `D:\v7work\v7_SENSE4` |
| 目标 | `D:\v7work\v7_SENSE5`（全新目录） |
| 方式 | `robocopy /E`，排除 `out\`、`work_syn\`、`work_pnr\`、`outflow\`、`flow_console.log`、`*.gtkw`；robocopy exit=1（正常） |
| 复制后核对 | 165 / 165 文件；仅源有 0、仅目标有 0、内容不同 0 |

### 2.2 全树 diff 结果：**恰好 4 处变化** ✅

证据：`...\SENSE5\tree_diff.txt`（本次重新逐文件 sha256 复核）；清单 `sense4_manifest.csv`、`sense5_manifest_before_build.csv`。

| # | 类型 | 文件 | SENSE4 | SENSE5 |
|---|---|---|---|---|
| 1 | 改动 | `rtl\mmt\v7_mmt_core.v` | 8,819 B, sha `6BF3FD4A…E618` | **9,465 B, sha `8E35786D…71E3`**（= 指挥官版本） |
| 2 | 改动 | `rtl\mmt\v7_txt_fmt.v` | 5,588 B, sha `CA99E6E2…12FE` | **5,829 B, sha `AC7C711C…0D54`**（= 指挥官版本） |
| 3 | **新增** | `rtl\mmt\v7_pwr_ctl.v` | 不存在 | **1,723 B, sha `7624D821…B3EA`** |
| 4 | 改动 | `ti60f225_oob.xml` | 15,774 B, sha `D0903DB5…35E1` | **15,865 B, sha `584CE354…0638`**（多一行） |

- 全树其余 162 个文件与 SENSE4 **逐字节相同**；仅 SENSE4 有 = 0。
- `debug_top.v` **未变**：sha256 `04BA516729384A13261F302382CF6CF11DA1F35AD6139C586502EBB533E114DB`（与 SENSE4 相同=True）；L102–104 仍为 `'h158 / 'h110 / 'h188`（G、B 继承 SENSE4）。
- `v7_freeze_ctl.v` 未动：sha256 `87B2E2416156ADF9933F5304C7D54EE17CD6AE5C0488DEBCC715413A320E411B`（与 SENSE4 相同）。

### 2.3 `ti60f225_oob.xml` 字节级补丁 ✅

- 原文件纯 ASCII、LF 换行（15,774 B）；在 `rtl/mmt/v7_freeze_ctl.v` 行尾 LF（字节偏移 5910）之后插入 **91 字节**（90 字节新行 + 1 LF）。
- 新增行（现 L60）：`        <efx:design_file name="rtl/mmt/v7_pwr_ctl.v" version="default" library="default"/>`
- **回验**：前缀/插入段/后缀字节全一致=True；行数 195→196；行级逐行不符 = **0**。
- 证据：`...\SENSE5\xml_patch_verify.txt`、`verify_sense5.log`。

---

## 3. 改动内容摘要（只读 diff，未改内容）

| 文件 | 改动要点（相对 SENSE4，行级 diff 原文见 `verify_sense5.log`） |
|---|---|
| `v7_mmt_core.v`（132→137 行） | 新增参数 `PWR_IDLE_FRAMES=900`、`PWR_DIV=4`；新增 `fd_vs / low_pwr` 连线；帧差 `pix_vs` 改由 `v7_pwr_ctl.proc_vs` 提供；实例化 `v7_pwr_ctl u_pwr(.clk,.rst_n,.vs_rise,.human(fd_motion\|ir_hot),.low_pwr,.proc_vs(fd_vs))`；新增 30-bit `slow_c` 慢闪计数，`assign led = {led4[1], low_pwr ? slow_c[29] : led4[0]}`；`v7_txt_fmt` 增加 `.low_pwr(low_pwr)` 连接 |
| `v7_txt_fmt.v`（144→145 行） | 新增输入 `low_pwr`；EVT 词由两态改为三态：`INTRUDE`（报警）/ `SLEEP`（低功耗）/ `NORMAL`（正常），7 个字符位 `ev0..ev6` 相应改为三目选择 |
| `v7_pwr_ctl.v`（新增 30 行） | `vs_rise` 帧脉冲下：`human=0` 连续 `IDLE_FRAMES` 帧 → `low_pwr=1`；低功耗时 `proc_vs = vs_rise & (ph==0)`（每 `DIV` 帧放行 1 帧）；`human=1` 立即 `idle=0, low_pwr=0` 恢复 |

---

## 4. 构建（5 步）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\v7_flow.ps1 `
  -Work D:\v7work\v7_SENSE5 -Tag SENSE5
```

证据：`D:\v7work\v7_SENSE5\out\build.log`（全文）、`...\SENSE5\flow_stdout.log`。

| 步 | 结果（build.log 原文行） |
|---|---|
| [1] `efx_map` | **退出码=0** |
| [2] `efx_pnr#1` | **退出码=0** |
| [3] `efx_run -f interface` | **`interface : PASS`** |
| [4] `filter_interface` | **`wrote 481 lines`**（与 SENSE4 相同） |
| [5] `efx_pnr#2 --sync_file` + bitgen | **退出码=0** |

- 耗时：**21:18:11 → 21:23:57 = 5 分 46 秒**。
- 阶段落盘时间（`D:\v7work\v7_SENSE5\out\`）：`map.log` 21:19:57、`pnr1.log` 21:21:20、`ti60f225_oob.interface.csv` 21:21:45、`pnr2.log` 21:23:54、`v7_SENSE5.bit` 21:23:56、`build.log` 21:23:57。

---

## 5. 四项验收结果

| # | 验收项 | 要求 | 实测（来源） | 判定 |
|---|---|---|---|---|
| 1 | 5 步退出码 | 全 exit 0 | [1][2][5]=0；[3]=PASS；[4] wrote 481 lines（`out\build.log`） | ✅ |
| 2 | `No valid pin(s) found for clock` | **0** | **0**（`out\pnr2.log` 全文计数 = 0） | ✅ |
| 3 | `No clocks matched` | **87**（与基线对比） | **87**（`out\pnr2.log` 计数 = 87，与厂商 v7 基线 87 一致） | ✅ |
| 4 | 全部时钟域 setup/hold | 全正 | 最终签核表 **18 setup + 18 hold 全正，负 slack = 0**（`out\pnr2.log` final timing analysis；见 §6） | ✅ |

补充：`map.log` / `pnr1.log` / `pnr2.log` 中 `ERROR` 行均为 **0**（本次计数）。

---

## 6. 最终时序表（SENSE5 vs SENSE4，hold fixing 后的 `final timing analysis`）

- 数据来源：`D:\v7work\v7_SENSE5\out\pnr2.log` —— final timing analysis 段起始 **L1247**；最终 Setup 表标题 **L1604**、数据行 **L1606–1623**；最终 Hold 表标题 **L1625**、数据行 **L1627–1644**（快照 `...\SENSE5\pnr2_final_timing_tables.txt`）。
- SENSE4 对照值同法解析自 `D:\v7work\v7_SENSE4\out\pnr2.log`（final 段 L1254、Setup 表 L1611、Hold 表 L1632）；逐行对照落盘 `...\SENSE5\timing_final_SENSE4_vs_SENSE5.csv`。

### 6.1 Setup (Max) —— 18/18 全正

| # | Launch → Capture | SENSE4 (ns) | **SENSE5 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.401 | **+0.384** | −0.017 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +1.170 | **+0.885** | −0.285 |
| 3 | tx_cal_clk_90edge → core_clk | +1.896 | **+1.689** | −0.207 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.750 | **+1.119** | +0.369 |
| 5 | sdram_clk → sdram_clk | +0.520 | **+0.351** | −0.169 |
| 6 | rx_cal_clk → rx_cal_clk | +0.473 | **+0.523** | +0.050 |
| 7 | tx_cal_clk → tx_cal_clk | +0.294 | **+0.460** | +0.166 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +7.359 | **+7.328** | −0.031 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +1.971 | **+1.891** | −0.080 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.411** | **+0.323** | **−0.088** |
| 11 | core_clk → tx_cal_clk_90edge | +1.091 | **+1.137** | +0.046 |
| 12 | core_clk → core_clk | +4.430 | **+4.394** | −0.036 |
| 13 | core_clk → i_cam_ck_CLKOUT | +8.836 | **+8.925** | +0.089 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +13.971 | **+13.603** | −0.368 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +7.657 | **+7.686** | +0.029 |
| 16 | CLK_5M → CLK_5M | +196.266 | **+196.825** | +0.559 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +8.574 | **+8.407** | −0.167 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +4.941 | **+5.042** | +0.101 |
| — | **最小 setup** | +0.294 | **+0.323** | +0.029 |

### 6.2 Hold (Min) —— 18/18 全正

| # | Launch → Capture | SENSE4 (ns) | **SENSE5 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.049 | **+0.072** | +0.023 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +0.553 | **+0.717** | +0.164 |
| 3 | tx_cal_clk_90edge → core_clk | +0.162 | **+0.135** | −0.027 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.572 | **+0.438** | −0.134 |
| 5 | sdram_clk → sdram_clk | +0.060 | **+0.097** | +0.037 |
| 6 | rx_cal_clk → rx_cal_clk | +0.027 | **+0.027** | 0 |
| 7 | tx_cal_clk → tx_cal_clk | +0.097 | **+0.097** | 0 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +0.079 | **+0.046** | −0.033 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +0.128 | **+0.125** | −0.003 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.029** | **+0.027** | **−0.002** |
| 11 | core_clk → tx_cal_clk_90edge | +0.198 | **+0.118** | −0.080 |
| 12 | core_clk → core_clk | +0.030 | **+0.035** | +0.005 |
| 13 | core_clk → i_cam_ck_CLKOUT | +0.113 | **+0.111** | −0.002 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +0.026 | **+0.026** | 0 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +0.150 | **+0.116** | −0.034 |
| 16 | CLK_5M → CLK_5M | +0.042 | **+0.080** | +0.038 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +0.072 | **+0.071** | −0.001 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +0.034 | **+0.031** | −0.003 |
| — | **最小 hold** | +0.026 | **+0.026** | 0 |

### 6.3 `hdmi_tx_slow_clk` 专项（单独列出）

| 指标 | SENSE4 | **SENSE5** | 变化 |
|---|---|---|---|
| hdmi 内 setup | +0.411 | **+0.323** | −0.088 |
| hdmi 内 hold | +0.029 | **+0.027** | −0.002 |
| 全设计最差 slack | +0.026 | **+0.026**（setup 最小 +0.323；hold 最小 +0.026 出现在 `rx_cal_clk`/`i_mipi_rx_pclk`） | 0 |

**⇒ 最终时序所有时钟域 setup/hold 全正，0 条负 slack。**

---

## 7. route 阶段（hold 修复前）告警如实记录

- SENSE5 `pnr2.log` `L938–942` 有 **5 条** `may not meet ... hold (min)` 告警（SENSE4 为 6 条，含 hdmi −0.703；**SENSE5 本次无 hdmi 域告警**）：
  tx_cal_clk_90edge −0.360 / sdram_clk −0.432 / rx_cal_clk −0.636 / tx_cal_clk −0.241 / core_clk −0.513 ns。
- 该段为路由阶段、hold 修复**前**分析，不是最终签核：SENSE5 `Hold fix wire delay: 68`、`Pins requiring hold fix: 0.00%`；最终 `final timing analysis` 表中 18+18 全正（见 §6）。
- 结论：按"最终时序全正"口径验收通过；此处仅过程如实记录，**不构成负时序**。

---

## 8. 资源对照与归因

### 8.1 总量对照（`ti60f225_oob.place.rpt`）

| 资源 | SENSE4 | **SENSE5** | 变化 | 证据行 |
|---|---|---|---|---|
| XLRs | 31,624 / 60,800 (52.01%) | **31,407 / 60,800 (51.66%)** | **−217** | 两版 `place.rpt:58` |
| Memory Blocks | 118 / 256 (46.09%) | **118 / 256 (46.09%)** | **0** | 两版 `place.rpt:69` |
| DSP Blocks | 15 / 160 (9.38%) | **15 / 160 (9.38%)** | **0** | 两版 `place.rpt:70` |

> 指令要求：**Memory 和 DSP 应不变，变了就停下报告** ⇒ 实测 **完全不变**，未触发停止条件。

### 8.2 XLR 归因（与 `u_v7_mmt` 子树增量分开）

数据来源：两版 `out\ti60f225_oob.hier_util.rpt`（快照 `...\SENSE5\resource_attribution.txt`）。

| 对象 | SENSE4 | **SENSE5** | 变化 | 归因说明 |
|---|---|---|---|---|
| 顶层 XLR | 31,624 | **31,407** | **−217** | 总量 |
| **`u_v7_mmt` 子树**（本轮改动所在） | 2,681.5 | **2,718.5** | **+37** | **本轮新增逻辑增量**：`v7_pwr_ctl` + 帧差抽稀 + EVT 三态 + LED 慢闪；符合"新增逻辑很小"的预期 |
| 其中 `u_fz`（v7_freeze_ctl，沿用 SENSE4） | 37 | 37 | 0 | 未动 |
| `inst_gamma_correction`（**本轮未改 RTL**） | 11,661 | **11,445** | **−216** | 10,240-bit 异步读 RAM 被映射为逻辑（EFX-0657 警告）；该模块四版 XLR 实测 11,454 (SENSE2) / 10,994 (SENSE3) / 11,661 (SENSE4) / 11,445 (SENSE5) ⇒ 综合优化波动，与本轮改动无关 |
| 其余模块合计（推算） | — | — | **−38** | 顶层 −217 − mmt +37 − gamma −216 = −38（分散在多个未改模块的小差值） |

**一致性佐证（FF）**：顶层 `xlr_ff` 7,340 → **7,784（+444）**，其中 `inst_gamma_correction` 的 FF 3,383 → **3,824（+441）**，其余模块约 +3 ⇒ 本轮新增逻辑的真实 FF 增量很小（约 +50：`idle[15:0]`、`ph[2:0]`、`low_pwr`、`slow_c[29:0]` 等），FF 的大头同样来自 gamma 模块综合波动。**⇒ 无意外 BRAM/DSP 推断。**

---

## 9. 位流

```
路径  : D:\v7work\v7_SENSE5\out\v7_SENSE5.bit
大小  : 2,629,923 B      （SENSE4 为 2,634,708 B，本次 −4,785 B）
时间  : 2026-10-21 21:23:56
SHA256: DEA095C2EB225C3C6D2D7861BEA502BB728B7310493C0D9901103DC74481B6E6
附属  : D:\v7work\v7_SENSE5\out\v7_SENSE5.hex（由 efx_pgm 生成）
```

- 证据：`out\build.log` 末行、`out\v7_SENSE5.bit` 实际计算（`flow_stdout.log` 同）。
- ⚠️ 位流 sha256 不可复现，仅作"这一份产物"的指纹。
- **未烧录**：板上当前 = v7_SENSE4（sha256 `74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01`，2026-10-21 21:22 烧入）。

---

## 10. 其它如实记录

| 项 | 记录 |
|---|---|
| 构建后源树完整性 | 166 文件（165 + 新增 1）与构建前清单 **0 差异**（`sense5_manifest_after_build.csv`）；构建未回写源码 |
| 日志 ERROR | `map.log`=0、`pnr1.log`=0、`pnr2.log`=0 |
| 逻辑映射警告 | 与 SENSE4 同族工况（gamma `r_gamma_2P` 10240 bits 等，`map.log` 中 EFX-0657） |
| 未验证项 | 低功耗/自动唤醒/OSD `SLEEP` 的**实际板级行为未验证**（本轮不烧录）；只能等上板观察。仿真结论属指挥官线，本文件不引用为事实。 |

---

## 11. 证据索引

| 证据 | 路径 |
|---|---|
| 本文件 | `D:\FPGA\mmt\out\evidence\v7_sense5_build.md` |
| 构建日志 | `D:\v7work\v7_SENSE5\out\build.log`（快照 `...\SENSE5\build.log.snapshot`） |
| 流程 stdout | `...\evidence\v7_abc2\SENSE5\flow_stdout.log` |
| 最终时序原始表 | `D:\v7work\v7_SENSE5\out\pnr2.log` `L1247` 起；快照 `...\SENSE5\pnr2_final_timing_tables.txt` |
| 时序逐行对照 CSV | `...\SENSE5\timing_final_SENSE4_vs_SENSE5.csv` |
| 资源 | `D:\v7work\v7_SENSE5\out\ti60f225_oob.place.rpt`（L58/L69/L70）；归因 `resource_place_rpt.txt`、`resource_attribution.txt`、`ti60f225_oob.hier_util.rpt` |
| 入参核对 / 复制 / 全树 diff | `...\SENSE5\prep_sense5.log`、`verify_sense5.log`、`tree_diff.txt` |
| 清单 | `...\SENSE5\sense4_manifest.csv`、`sense5_manifest_before_build.csv`、`sense5_manifest_after_build.csv` |
| XML 补丁证据 | `...\SENSE5\xml_patch_verify.txt` |
| 取证脚本/输出 | `...\SENSE5\collect_evidence.ps1`、`collect_evidence.log` |
| 位流 | `D:\v7work\v7_SENSE5\out\v7_SENSE5.bit` |
| 构建工具 | `D:\FPGA\mmt\tools\v7_flow.ps1`（未改） |

---

## 12. 边界声明

- **未烧录**（板上仍是 21:22 烧入的 v7_SENSE4）；不 push；不删文件；未改任何 SDC/约束/peri.xml/顶层。
- 只做了指令指定的四处改动：覆盖 `v7_mmt_core.v`、覆盖 `v7_txt_fmt.v`、新增 `v7_pwr_ctl.v`、`ti60f225_oob.xml` 加一行；其余 162 个源文件与 SENSE4 逐字节相同。
- 仅新增：`D:\v7work\v7_SENSE5\`（构建副本）、`D:\FPGA\mmt\out\evidence\v7_abc2\SENSE5\`（取证文件）、本文件。
