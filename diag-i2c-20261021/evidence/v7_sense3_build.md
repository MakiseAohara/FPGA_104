# v7_SENSE3 构建记录 —— 2026-10-21 17:32–17:44

> **✅ 构建成功：5 步全部通过（exit 0 / PASS），最终时序 18 条 setup + 18 条 hold 关系全部为正、0 条负 slack，位流已生成。**
> **本轮未烧录**（板上仍是 v7_SENSE2）。
> 目的：只调白平衡（VIO 初始增益 Q8）——R 保持 `'h158`，G `'h118→'h110`，B `'h170→'h188`。

---

## 0. 任务与边界

- 任务：以厂商 v7 底座 + SENSE2 为源，构建 **v7_SENSE3**（只改白平衡），只编译不烧录。
- 授权边界：不改 RTL（指定的 2 个常数除外）、不改约束、不烧录、不 push、不删文件、不做 git commit。
- 构建路径全部 ASCII：`D:\v7work\v7_SENSE3`（规避 `$readmemh` 中文路径问题）。

---

## 1. 源与复制（新目录，未复用任何旧变体）

| 项 | 值 |
|---|---|
| 源 | `D:\FPGA\易灵思\工作区\07_官方demo工程\v7_SENSE2` |
| 目标 | `D:\v7work\v7_SENSE3`（构建前 `Test-Path` = **False** ⇒ 全新目录） |
| 复制方式 | `robocopy /E`，排除 `out\`、`work_syn\`、`work_pnr\`、`outflow\`；**robocopy exit=1**（正常，有文件复制） |
| 编辑前逐文件 sha256 | 源 **164** 文件 / 目标 **164** 文件；仅源有 **0**、仅目标有 **0**、内容不同 **0** |
| 清单落盘 | `D:\FPGA\mmt\out\evidence\v7_abc2\SENSE3\src_manifest.csv`、`dst_manifest_before_edit.csv` |

---

## 2. 改动 diff（唯一改动：`debug_top.v` L102–104）

```diff
@@ D:\v7work\v7_SENSE3\debug_top.v (L102-104) vs 源 SENSE2 @@
         .PROBE_OUT0_INIT_VAL    ( 'h158 ),      // R：保持不动
-        .PROBE_OUT1_INIT_VAL    ( 'h118 ),      // G
+        .PROBE_OUT1_INIT_VAL    ( 'h110 ),
-        .PROBE_OUT2_INIT_VAL    ( 'h170 ),      // B
+        .PROBE_OUT2_INIT_VAL    ( 'h188 ),
```

- 改动位置：`D:\v7work\v7_SENSE3\debug_top.v:102-104`（VIO `PROBE_OUT*_INIT_VAL`）。
- `debug_top.v` 大小 425,644 B（不变）；sha256：源 `9B590A2FF69C73436E9185E63F7847AC46270E72B75779EC37FA1824F8875BFB` → SENSE3 `04BA516729384A13261F302382CF6CF11DA1F35AD6139C586502EBB533E114DB`。
- **编辑后全树复核**：164 文件逐文件 sha256，与源不同 = **1**（只有 `debug_top.v`）。
- **构建后全树复核**：164 文件与"编辑后清单"不同 = **0**（构建过程未回写任何源码）。
- 清单：`dst_manifest_after_edit.csv`。

---

## 3. 禁令项（未改文件）逐项 sha256 证明

以下文件与源 SENSE2 **逐字节一致**（sha256 相等）：

| 文件 | sha256（SENSE3 内实测） | 与源一致 |
|---|---|---|
| `rtl\debayer\debayer_top_2to1.v` | `00971C09DBDD5565610E36FBD2E8499878BE2D067891695E78282D2DA6002163` | ✅ |
| `rtl\debayer\raw_to_rgb.v` | `AAC0BC773D4C829BD3F1580A350B1957441BB1FC9588FE8D9E69CF36106F5516` | ✅ |
| `rtl\debayer\rgb_gain_v1.v` | `020CFBFAA5D38A9B1D1C26AA804AFF3B55EC1790220D4651D9213D2177789161` | ✅ |
| `rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v` | `DB13D1EED22A9478FD0AFFB9AC86B8265302A474886D7FFF688447AF2470FFE3` | ✅ |
| `ti60f225_oob.sdc` | `7DEA948873E6BBAA2FDA92E4E26C67F5CF0FD435A26D3B53BFAA46659B3325FF` | ✅ |
| `ti60f225_oob.peri.xml` | `67FA38F1DA5D4493410F3C831A67C4EBDA4892AA5D4EC887E8085AE8EBA851C3` | ✅ |

- 传感器寄存器 `0x3221=0x66` 原文未动：`rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v:246`
  `ROM[8'ha3] = {16'h3221,8'h66,1'b0};`
- 四处颜色修复（`debayer_top_2to1.v` / `raw_to_rgb.v` / `rgb_gain_v1.v`）sha256 与源完全相同（见上表）。

---

## 4. 构建命令与 5 步结果

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\v7_flow.ps1 `
  -Work D:\v7work\v7_SENSE3 -Tag SENSE3
```

| 步 | 结果 | 证据 |
|---|---|---|
| [1] `efx_map` | **exit 0** | `out\build.log`；`map.log` 中 `ERROR` 行 = 0 |
| [2] `efx_pnr#1`（无 sync_file） | **exit 0** | `out\build.log`；`pnr1.log` `ERROR` 行 = 0 |
| [3] `efx_run -f interface` | **interface : PASS** | `out\build.log` L8 |
| [4] `filter_interface` | **wrote 481 lines**（与 SENSE2 相同） | `out\build.log` L12 |
| [5] `efx_pnr#2 --sync_file` + bitgen | **exit 0** | `out\build.log` |
| 脚本整体 | **FLOW_EXIT=0** | `flow_stdout.log` |

- 端到端耗时：**17:32:47 → 17:44:52 = 12 分 05 秒**（本次本机偏慢；SENSE2 记录约 5～8 分钟）。阶段落盘时间：`map.log` 17:36:38、`pnr1.log` 17:39:58、`interface.csv` 17:40:53、`pnr2.log` 17:44:49、`.bit` 17:44:51。

---

## 5. 验收判据（逐项对照任务书）

| 判据 | 要求 | 实测 | 判定 |
|---|---|---|---|
| 5 步退出 | 全 exit 0 | [1][2][5]=0；[3]=PASS；[4] wrote 481 lines | ✅ |
| `No valid pin(s) found for clock` | **0** | **0**（`pnr2.log` 全文计数） | ✅ |
| `No clocks matched` | **87**（基线不变） | **87** | ✅ |
| 最终 setup 负 slack | 0 | **0**（18 条关系全正） | ✅ |
| 最终 hold 负 slack | 0 | **0**（18 条关系全正） | ✅ |
| 最差 slack | > 0 | **+0.026 ns** | ✅ |
| `ERROR` 行 | — | map=0 / pnr1=0 / pnr2=0 | ✅ |

---

## 6. 最终时序（hold fixing 之后的 `final timing analysis`）

- 数据来源：`D:\v7work\v7_SENSE3\out\pnr2.log` —— final timing analysis 段 `L1251–1657`，最终 Setup 表标题 `L1608`、数据行 `L1610–1627`；最终 Hold 表标题 `L1629`、数据行 `L1631–1648`（快照见 `pnr2_final_timing_tables.txt`）。
- SENSE2 对照值由同一解析脚本读取 `D:\v7work\v7_SENSE2\out\pnr2.log` 最终表；逐行对照落盘为 `timing_final_SENSE2_vs_SENSE3.csv`。

### 6.1 Setup (Max) —— 18 条关系全部为正

| # | Launch → Capture | SENSE2 (ns) | **SENSE3 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.358 | **+0.433** | +0.075 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +1.253 | **+1.133** | −0.120 |
| 3 | tx_cal_clk_90edge → core_clk | +1.743 | **+1.672** | −0.071 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.813 | **+1.087** | +0.274 |
| 5 | sdram_clk → sdram_clk | +0.272 | **+0.460** | +0.188 |
| 6 | rx_cal_clk → rx_cal_clk | +0.593 | **+0.558** | −0.035 |
| 7 | tx_cal_clk → tx_cal_clk | +0.205 | **+0.368** | +0.163 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +7.264 | **+7.364** | +0.100 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +1.940 | **+2.049** | +0.109 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.320** | **+0.164** | **−0.156** |
| 11 | core_clk → tx_cal_clk_90edge | +1.056 | **+1.046** | −0.010 |
| 12 | core_clk → core_clk | +4.879 | **+4.273** | −0.606 |
| 13 | core_clk → i_cam_ck_CLKOUT | +8.666 | **+8.637** | −0.029 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +14.172 | **+14.049** | −0.123 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +7.874 | **+8.489** | +0.615 |
| 16 | CLK_5M → CLK_5M | +196.836 | **+196.874** | +0.038 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +8.056 | **+8.604** | +0.548 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +4.696 | **+4.947** | +0.251 |
| — | **最小 setup** | **+0.205** | **+0.164** | −0.041 |

### 6.2 Hold (Min) —— 18 条关系全部为正

| # | Launch → Capture | SENSE2 (ns) | **SENSE3 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.072 | **+0.091** | +0.019 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +0.507 | **+0.574** | +0.067 |
| 3 | tx_cal_clk_90edge → core_clk | +0.176 | **+0.164** | −0.012 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.535 | **+0.386** | −0.149 |
| 5 | sdram_clk → sdram_clk | +0.074 | **+0.094** | +0.020 |
| 6 | rx_cal_clk → rx_cal_clk | +0.026 | **+0.026** | 0 |
| 7 | tx_cal_clk → tx_cal_clk | +0.079 | **+0.094** | +0.015 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +0.046 | **+0.049** | +0.003 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +0.128 | **+0.123** | −0.005 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.027** | **+0.026** | **−0.001** |
| 11 | core_clk → tx_cal_clk_90edge | +0.123 | **+0.124** | +0.001 |
| 12 | core_clk → core_clk | +0.030 | **+0.029** | −0.001 |
| 13 | core_clk → i_cam_ck_CLKOUT | +0.116 | **+0.221** | +0.105 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +0.028 | **+0.026** | −0.002 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +0.120 | **+0.133** | +0.013 |
| 16 | CLK_5M → CLK_5M | +0.042 | **+0.045** | +0.003 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +0.067 | **+0.070** | +0.003 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +0.026 | **+0.028** | +0.002 |
| — | **最小 hold** | **+0.026** | **+0.026** | 0 |

### 6.3 `hdmi_tx_slow_clk` 专项（任务书指定参考点）

| 指标 | SENSE2 | SENSE3 | 变化 |
|---|---|---|---|
| hdmi 内 setup | **+0.320 ns** | **+0.164 ns** | −0.156 ns（仍为正） |
| hdmi 内 hold | **+0.027 ns** | **+0.026 ns** | −0.001 ns（仍为正） |
| 全设计最差 slack | +0.026 ns | **+0.026 ns** | 0 |

**⇒ 结论：最终时序所有时钟域 setup/hold 全正，0 条负 slack，满足任务书验收。**

---

## 7. ⚠️ 必须如实报告的 1 个 delta（未自行改动，请指挥官裁定）

- **route 阶段（hold 修复前）**的 `pnr2.log` 出现 **6 条** `may not meet ... hold (min)` 告警（`L939–944`），而 SENSE2 同位置为 **5 条**且不含 hdmi。本次新增的一条是：
  ```
  pnr2.log L943: WARNING: Clock domain between hdmi_tx_slow_clk (rising) and hdmi_tx_slow_clk (rising)
                 may not meet (slack: -0.324 ns) the hold (min) timing requirement
  ```
  （另外 5 条为同族既有：tx_cal_clk_90edge −0.470 / sdram_clk −0.325 / rx_cal_clk −0.780 / tx_cal_clk −0.524 / core_clk −0.727 ns，`L939–944`）
- **该段落是路由阶段分析、不是最终签核**：两版 hold fixing 报告一致为 `Pins requiring hold fix: 0.00%`（SENSE2 `pnr2.log` / SENSE3 `pnr2.log`），最终 `final timing analysis` 表中 hdmi hold = **+0.026 ns**（与 SENSE2 +0.027 基本一致）。
- 同时 **hdmi setup 余量由 +0.320 收窄到 +0.164 ns**（−0.156 ns）。
- **判定口径**：按任务书"最终时序全正"验收 ⇒ **本版通过、无负时序**；上述为余量收窄的风险提示，不构成负 slack。**本轮未改任何 RTL/约束去修时序**；若指挥官希望 hdmi 域留更大余量，需另行授权修改（例如在 hdmi 域再加一级打拍）。

---

## 8. 资源（`ti60f225_oob.place.rpt`）

| 资源 | SENSE2 | **SENSE3** | 变化 | 证据行 |
|---|---|---|---|---|
| XLRs | 31,306 / 60,800 (51.49%) | **30,812 / 60,800 (50.68%)** | **−494** | SENSE2 `place.rpt:58` / SENSE3 `place.rpt:58` |
| Memory Blocks | 118 / 256 (46.09%) | **118 / 256 (46.09%)** | 0 | `place.rpt:69` |
| DSP Blocks | 15 / 160 (9.38%) | **15 / 160 (9.38%)** | 0 | `place.rpt:70` |

---

## 9. 位流

```
路径  : D:\v7work\v7_SENSE3\out\v7_SENSE3.bit
大小  : 2,616,858 B      （SENSE2 为 2,628,522 B，本次 −11,664 B）
时间  : 2026-10-21 17:44:51
SHA256: 1164906E8DDAC2D1CC6DC7783F3A0D33B31EA2AB1FA6F791D0A6C02C33A224A5
附属  : D:\v7work\v7_SENSE3\out\v7_SENSE3.hex（2,616,918 B，由 efx_pgm 生成）
```

- ⚠️ 位流 sha256 **不可复现**（同源重编可能 sha 不同，见 M0 报告 §4.5）；此 sha 仅作"这一份产物"的指纹，不能当同源证据。
- **未烧录**：板上仍是 v7_SENSE2（sha256 `0F48EED8316972E4E9DF0DB15E4756385C854EF451CECB24072CFF2B8C38AB64`）。
- 位流未复制回 `07_官方demo工程`（该目录没有 v7_SENSE3 变体目录，任务书也未要求建）。

---

## 10. 与 SENSE2 的差异总表

| 维度 | 差异 |
|---|---|
| 源文件 | 仅 `debug_top.v` 2 行（G、B 初值） |
| XLR | 31,306 → 30,812（−494） |
| Memory / DSP | 118 / 15 不变 |
| 位流大小 | 2,628,522 → 2,616,858 B（−11,664 B） |
| 最终 setup | 全部为正；最小 +0.164（SENSE2 +0.205）；hdmi 内 +0.164（SENSE2 +0.320） |
| 最终 hold | 全部为正；最小 +0.026（与 SENSE2 同）；hdmi 内 +0.026（SENSE2 +0.027） |
| 负 slack | 0（两版均为 0） |
| route 阶段 hold 告警 | SENSE2 5 条 → SENSE3 6 条（新增 hdmi −0.324，最终签核 +0.026） |

---

## 11. 证据索引

| 证据 | 路径 |
|---|---|
| 本文件 | `D:\FPGA\mmt\out\evidence\v7_sense3_build.md` |
| 构建日志 | `D:\v7work\v7_SENSE3\out\build.log`（快照 `...\evidence\v7_abc2\SENSE3\build.log.snapshot`） |
| 流程 stdout | `D:\FPGA\mmt\out\evidence\v7_abc2\SENSE3\flow_stdout.log`（含 `FLOW_EXIT=0`） |
| 最终时序原始表 | `D:\v7work\v7_SENSE3\out\pnr2.log` `L1251–1657`；快照 `...\SENSE3\pnr2_final_timing_tables.txt` |
| 时序逐行对照 CSV | `D:\FPGA\mmt\out\evidence\v7_abc2\SENSE3\timing_final_SENSE2_vs_SENSE3.csv` |
| 取证脚本与输出 | `...\SENSE3\collect_evidence.ps1`、`collect_evidence.log` |
| 源/目标文件 sha256 清单 | `...\SENSE3\src_manifest.csv`、`dst_manifest_before_edit.csv`、`dst_manifest_after_edit.csv` |
| 资源报告 | `D:\v7work\v7_SENSE3\out\ti60f225_oob.place.rpt`（L58 / L69 / L70） |
| 位流 | `D:\v7work\v7_SENSE3\out\v7_SENSE3.bit` |
| 构建工具 | `D:\FPGA\mmt\tools\v7_flow.ps1`（未改） |

---

## 12. 边界声明

- **未烧录**：未调用 `flash_vendor.ps1`，板上保持 v7_SENSE2。
- **未 push / 未 commit / 未删文件 / 未改约束 / 未改其他 RTL**；仅新增构建副本 `D:\v7work\v7_SENSE3\` 与证据目录 `D:\FPGA\mmt\out\evidence\v7_abc2\SENSE3\`。
- 唯一源代码改动 = `debug_top.v` L102–104 的 G/B 两个 VIO 初值常数（R 未动）。
- 本次未开始任务 2（归档）与任务 3（M1 架构取证）；等指挥官指令。
