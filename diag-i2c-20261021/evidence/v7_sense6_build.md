# v7_SENSE6 构建 + 烧录记录（I2C 诊断版）—— 2026-10-21 22:10–22:17

> **✅ 构建成功：5 步全部通过（exit 0 / PASS），最终签核时序 18 setup + 18 hold 全部为正、0 条负 slack。**
> **✅ 验收通过后已灼录一次（JTAG 临时加载，未写 SPI）：两个成功判据同时出现，脚本 exit 0。板上现在 = v7_SENSE6。**
> 内容：SENSE5 + 只读 I2C 诊断逻辑（OSD 显示 SCL/SDA 电平、从机拉低 SDA、总线错误标志、主机 SCL 次数 O=、从机拉低次数 N=；**不改任何决策逻辑**）。
> 授权：Kevin 在聊天中明确授权"SENSE6 时序全正后烧录一次"；本次仅一次 JTAG 临时加载。

---

## 0. 任务与边界

- 源：`D:\v7work\v7_SENSE5` → 新目录 `D:\v7work\v7_SENSE6`（纯 ASCII；构建前 `Test-Path`=False）。
- 改动：只覆盖 `rtl\mmt\v7_mmt_core.v`、`rtl\mmt\v7_txt_fmt.v`（指挥官提供，sha256 核对通过）；**xml 未改（无新增文件）**。
- 边界：不 push；不删文件；未改任何 RTL/约束；除本次 SENSE6 烧录外未烧录任何东西。

---

## 1. 入参 sha256 核对（硬门槛）✅

来源：`D:\FPGA\mmt\sim\v7_sys7\`

| 文件 | 期望 sha256（= 实测） | 大小 | 判定 |
|---|---|---|---|
| `v7_mmt_core.v` | `f656bae1600193ea5c6547b22c64fe8465853bdca549c260fa92d7367a20c061` | 11,231 B | **MATCH** |
| `v7_txt_fmt.v` | `2fbb11acc7b6d52e548530a66e2fda07070607ca0da4bc9ec1f7eafee5be01b4` | 8,062 B | **MATCH** |

按字节复制；覆盖后再次核对 sha256 一致。证据：`...\evidence\v7_abc2\SENSE6\prep_sense6.log`。

---

## 2. 复制与全树 diff（对 SENSE5）✅

| 项 | 值 |
|---|---|
| 复制 | robocopy `/E`，排除 `out\`、`work_syn\`、`work_pnr\`、`outflow\`、`flow_console.log`、`*.gtkw`；robocopy exit=1（正常） |
| 复制后核对 | 166 / 166 文件；仅源有 0、仅目标有 0、内容不同 0 |
| **全树 diff** | **只有 2 个文件不同**（无新增、无删除）：`rtl\mmt\v7_mmt_core.v`、`rtl\mmt\v7_txt_fmt.v` |

| 文件 | SENSE5 | **SENSE6** |
|---|---|---|
| `rtl\mmt\v7_mmt_core.v` | 9,465 B, sha `8E35786D…71E3` | **11,231 B, sha `F656BAE1…C061`** |
| `rtl\mmt\v7_txt_fmt.v` | 5,829 B, sha `AC7C711C…0D54` | **8,062 B, sha `2FBB11AC…01B4`** |

- `debug_top.v` **未变**：sha256 `04BA516729384A13261F302382CF6CF11DA1F35AD6139C586502EBB533E114DB`（与 SENSE5 相同）。
- `ti60f225_oob.xml` **未变**：sha256 `584CE354E32689CD42AC424DBD5A7DA6BC6322DB6FD8776C76851C862A630638`（与 SENSE5 相同）。
- `v7_freeze_ctl.v`、`v7_pwr_ctl.v` 均与 SENSE5 逐字节相同（sha `87B2E241…` / `7624D821…`）。
- 证据：`prep_sense6.log`、`sense5_manifest.csv`、`sense6_manifest_before_build.csv`。

### 2.1 改动内容摘要（只读 diff）

| 文件 | 改动要点 |
|---|---|
| `v7_mmt_core.v`（137→162 行） | 新增**只读** I2C 诊断采样：`scl_i/sda_i` 两级同步（`dg_scl_s/dg_sda_s`）；主机释放线后的稳定计数 `dg_rel_sda/dg_rel_scl`（9 位，≈1.7 µs）；`dg_slv`（主机释放 SDA 却被从机拉低）、`dg_stuck`（SCL 被外部拉住）、`dg_oe_cnt`（主机 SCL 输出使能上升沿计数）、`dg_slv_cnt`（从机拉低 SDA 次数）、`dg_crc/dg_irseen`（SHT CRC 错 / 红外帧见）等；全部为诊断观测，**未改动任何决策/报警逻辑** |
| `v7_txt_fmt.v`（145→204 行） | OSD 空闲列扩展：`hx()`/`bt()` 辅助函数 + 字符码表增加 `A=`（从机拉低 SDA）、`E=`（SHT 错）、`IE=`（红外错）、`SV=`（SHT 已见）、`IV=`（红外帧已见）、`C=`（CRC 错）、`K`（stuck 标志）、`O=`（SCL 次数十六进制）、`N=`（从机拉低次数）等 |

---

## 3. 构建（5 步）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\v7_flow.ps1 `
  -Work D:\v7work\v7_SENSE6 -Tag SENSE6
```

| 步 | 结果（`out\build.log` 原文） |
|---|---|
| [1] `efx_map` | **退出码=0** |
| [2] `efx_pnr#1` | **退出码=0** |
| [3] `efx_run -f interface` | **`interface : PASS`** |
| [4] `filter_interface` | **`wrote 481 lines`**（与 SENSE5 相同） |
| [5] `efx_pnr#2 --sync_file` + bitgen | **退出码=0** |

- 耗时：**22:10:35 → 22:16:09 = 5 分 34 秒**。
- 阶段落盘：`map.log` 22:12:22、`pnr1.log` 22:13:49、`pnr2.log` 22:16:06、`v7_SENSE6.bit` 22:16:08、`build.log` 22:16:09。
- `map.log`/`pnr1.log`/`pnr2.log` 中 `ERROR` 行 = **0 / 0 / 0**。

---

## 4. 验收结果（全部达到，方进入烧录）

| # | 验收项 | 要求 | 实测（来源） | 判定 |
|---|---|---|---|---|
| 1 | 5 步退出 | 全 exit 0 | [1][2][5]=0；[3]=PASS；[4] wrote 481 lines（`out\build.log`） | ✅ |
| 2 | `No valid pin(s) found for clock` | 0 | **0**（`out\pnr2.log` 全文计数） | ✅ |
| 3 | `No clocks matched` | 87 | **87**（`out\pnr2.log` 计数；SDC 与 SENSE5 相同） | ✅ |
| 4 | 全部时钟域 setup/hold | 全正 | 最终签核 **18 setup + 18 hold 全正、0 条负 slack**（`out\pnr2.log` final timing；见 §5） | ✅ |
| 5 | hdmi_tx_slow_clk 内 | 记录 | setup **+0.308 ns** / hold **+0.029 ns**（SENSE5 参考 +0.323/+0.027，均正） | ✅ |
| 6 | 资源 | 对照 SENSE5（XLR 31,407 / Memory 118 / DSP 15）；Memory/DSP 不得变 | XLR **31,668（+261）**、Memory **118（0）**、DSP **15（0）**；XLR 归因见 §6（新增逻辑 `u_v7_mmt` **+169**，在"几十到两百"内；另 +111 为未改动 gamma 模块的综合波动，其余 −19） | ✅（硬性停止条件未触发） |

---

## 5. 最终时序表（hold fixing 后的 `final timing analysis`）

- 数据来源：`D:\v7work\v7_SENSE6\out\pnr2.log` —— final timing analysis 段起始 **L1250**；最终 Setup 表 **L1607**（数据 L1609–1626）；最终 Hold 表 **L1628**（数据 L1630–1647）。快照 `...\SENSE6\pnr2_final_timing_tables.txt`；逐行对照 `timing_final_SENSE5_vs_SENSE6.csv`。

### 5.1 Setup (Max) —— 18/18 全正

| # | Launch → Capture | SENSE5 (ns) | **SENSE6 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.384 | **+0.306** | −0.078 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +0.885 | **+1.383** | +0.498 |
| 3 | tx_cal_clk_90edge → core_clk | +1.689 | **+1.735** | +0.046 |
| 4 | sdram_clk → tx_cal_clk_90edge | +1.119 | **+0.617** | −0.502 |
| 5 | sdram_clk → sdram_clk | +0.351 | **+0.213** | −0.138 |
| 6 | rx_cal_clk → rx_cal_clk | +0.523 | **+0.430** | −0.093 |
| 7 | tx_cal_clk → tx_cal_clk | +0.460 | **+0.449** | −0.011 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +7.328 | **+7.049** | −0.279 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +1.891 | **+2.001** | +0.110 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.323** | **+0.308** | **−0.015** |
| 11 | core_clk → tx_cal_clk_90edge | +1.137 | **+0.912** | −0.225 |
| 12 | core_clk → core_clk | +4.394 | **+4.644** | +0.250 |
| 13 | core_clk → i_cam_ck_CLKOUT | +8.925 | **+8.779** | −0.146 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +13.603 | **+13.757** | +0.154 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +7.686 | **+8.147** | +0.461 |
| 16 | CLK_5M → CLK_5M | +196.825 | **+196.843** | +0.018 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +8.407 | **+8.527** | +0.120 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +5.042 | **+5.480** | +0.438 |
| — | **最小 setup** | +0.323 | **+0.213** | −0.110 |

### 5.2 Hold (Min) —— 18/18 全正

| # | Launch → Capture | SENSE5 (ns) | **SENSE6 (ns)** | Δ |
|---|---|---|---|---|
| 1 | tx_cal_clk_90edge → tx_cal_clk_90edge | +0.072 | **+0.069** | −0.003 |
| 2 | tx_cal_clk_90edge → tx_cal_clk | +0.717 | **+0.432** | −0.285 |
| 3 | tx_cal_clk_90edge → core_clk | +0.135 | **+0.069** | −0.066 |
| 4 | sdram_clk → tx_cal_clk_90edge | +0.438 | **+0.530** | +0.092 |
| 5 | sdram_clk → sdram_clk | +0.097 | **+0.084** | −0.013 |
| 6 | rx_cal_clk → rx_cal_clk | +0.027 | **+0.027** | 0 |
| 7 | tx_cal_clk → tx_cal_clk | +0.097 | **+0.098** | +0.001 |
| 8 | vid_clk_dvi2 → vid_clk_dvi2 | +0.046 | **+0.046** | 0 |
| 9 | vid_clk_dvi2 → hdmi_tx_slow_clk | +0.125 | **+0.123** | −0.002 |
| 10 | **hdmi_tx_slow_clk → hdmi_tx_slow_clk** | **+0.027** | **+0.029** | **+0.002** |
| 11 | core_clk → tx_cal_clk_90edge | +0.118 | **+0.123** | +0.005 |
| 12 | core_clk → core_clk | +0.035 | **+0.027** | −0.008 |
| 13 | core_clk → i_cam_ck_CLKOUT | +0.111 | **+0.143** | +0.032 |
| 14 | i_mipi_rx_pclk → i_mipi_rx_pclk | +0.026 | **+0.027** | +0.001 |
| 15 | i_mipi_rx_pclk → i_cam_ck_CLKOUT | +0.116 | **+0.118** | +0.002 |
| 16 | CLK_5M → CLK_5M | +0.080 | **+0.049** | −0.031 |
| 17 | i_cam_ck_CLKOUT → i_mipi_rx_pclk | +0.071 | **+0.071** | 0 |
| 18 | i_cam_ck_CLKOUT → i_cam_ck_CLKOUT | +0.031 | **+0.032** | +0.001 |
| — | **最小 hold** | +0.026 | **+0.027** | +0.001 |

### 5.3 `hdmi_tx_slow_clk` 专项

| 指标 | SENSE5 | **SENSE6** | 变化 |
|---|---|---|---|
| hdmi 内 setup | +0.323 | **+0.308** | −0.015（仍为正） |
| hdmi 内 hold | +0.027 | **+0.029** | +0.002 |
| 全设计最差 slack | +0.026 | **+0.027**（hold：rx_cal/i_mipi/core 各 0.027） | 全正 |

**⇒ 最终时序所有时钟域 setup/hold 全正，0 条负 slack。**

---

## 6. 资源对照与归因

### 6.1 总量（`out\ti60f225_oob.place.rpt`）

| 资源 | SENSE5 | **SENSE6** | 变化 | 判定 |
|---|---|---|---|---|
| XLRs | 31,407 / 60,800 (51.66%) | **31,668 / 60,800 (52.09%)** | **+261** | 见 §6.2 归因 |
| Memory Blocks | 118 / 256 (46.09%) | **118 / 256 (46.09%)** | **0** | ✅ 未变 |
| DSP Blocks | 15 / 160 (9.38%) | **15 / 160 (9.38%)** | **0** | ✅ 未变 |

> 指令："Memory/DSP 变了就停下报告" ⇒ **均未变，未触发停止条件**。

### 6.2 XLR 归因（与 gamma 综合波动分开）

数据来源：两版 `out\ti60f225_oob.hier_util.rpt`。

| 对象 | SENSE5 | **SENSE6** | 变化 | 说明 |
|---|---|---|---|---|
| 顶层 XLR | 31,407 | **31,668** | **+261** | 总量 |
| **`u_v7_mmt` 子树**（本轮改动所在） | 2,718.5 | **2,887.5** | **+169** | **新增逻辑增量**（I2C 诊断采样 + OSD 诊断文本），在指令预期"几十到两百"之内 |
| `inst_gamma_correction`（**本轮未改 RTL**） | 11,445 | **11,556** | **+111** | 10,240-bit 异步读 RAM 映射为逻辑（EFX-0657）；五版实测 11,454/10,994/11,661/11,445/11,556 ⇒ 综合优化波动 |
| 其余模块合计（推算） | — | — | **−19** | 顶层 +261 − mmt +169 − gamma +111 = −19 |

- 顶层 `xlr_ff`：7,784 → **7,803（+19）** —— 与"新增 25 个左右诊断寄存器"量级一致，未见异常推断。
- **⇒ 判定：Memory/DSP 未变；新增逻辑 XLR +169 在预期内；总量 +261 中另 +111 来自未改动 gamma 模块的综合波动（有 5 个版本的历史波动数据佐证）。**

---

## 7. 位流

```
路径  : D:\v7work\v7_SENSE6\out\v7_SENSE6.bit
大小  : 2,632,113 B
时间  : 2026-10-21 22:16:08
SHA256: 09CBCB665D3C3DFD9F30CABAFE23C3726A03B3B71C2534D6986915995D79B607
附属  : D:\v7work\v7_SENSE6\out\v7_SENSE6.hex（由 efx_pgm 生成）
```

- 位流 sha256 不可复现，仅作"这一份产物"的指纹。

---

## 8. 烧录（仅一次，JTAG 临时加载）

### 8.1 烧录前核对

| 项 | 结果 |
|---|---|
| 位流 sha256 | 实测 `09CBCB66…B607` = 期望，**一致** |
| 位流大小 | **2,632,113 B**，一致 |
| 板子 USB/JTAG | ✅ FT4232H（`VID_0403&PID_6011`）**9 个 PnP 实体**全部 `OK`（Converter A–D + COM13–16 + Composite） |
| FTDI 驱动 | ✅ 统一 **2.12.36.4** |
| JTAG 占用 | ✅ 无 |

### 8.2 执行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\flash_vendor.ps1 `
  -Bit "D:\v7work\v7_SENSE6\out\v7_SENSE6.bit" `
  -Sha256 09CBCB665D3C3DFD9F30CABAFE23C3726A03B3B71C2534D6986915995D79B607
```

- 时间：**22:17:33 → 22:17:48**（约 15 秒，**一次成功，未重试**；未出现 `No USB target detected`）。
- 模式：`-m jtag`（**JTAG 临时加载，未写 SPI 闪存**）；脚本退出码 **0**（`nativeExit: 0`）。
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261021_221738.log`（737 B；快照 `...\SENSE6\flash_log_snapshot.txt`，stdout 快照 `...\SENSE6\flash_stdout.log`）。

**日志关键行原文：**
```
Using board profile: 'Generic Board Profile Using FT4232H' for pinout connection
Connecting to JTAG_TAP: efx_ti
jtag programming started!
JTAG Programming on hiftdi://0x0403:0x6011/1
Programming 'D:\v7work\v7_SENSE6\out\v7_SENSE6.bit' via JTAG at freq 6.0 MHz
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```
**判据：**
```
=== 烧录判据 ===
  Device ID read from JTAG : PASS  (期望 0x10660A79)
  finished with JTAG programming : PASS
  设备 ID: 0x10660A79
  烧录成功
```

| 判据 | 要求 | 实测 | 判定 |
|---|---|---|---|
| `Device ID read from JTAG: 0x10660A79` | 逐字出现 | 出现（日志第 6 行） | ✅ |
| `finished with JTAG programming` | 逐字出现 | 出现（日志第 7 行） | ✅ |

**⇒ 板上现在 = v7_SENSE6（I2C 诊断版）。** 待 Kevin 看屏幕（OSD 空闲列应出现 SCL/SDA/A=/E=…/O=/N= 等诊断字符）并调白平衡。

### 8.3 第二次烧录（Kevin 在聊天中直接要求"再烧一下"）✅

- 位流：同一份 `D:\v7work\v7_SENSE6\out\v7_SENSE6.bit`（sha256 `09CBCB66…B607`，2,632,113 B，烧前复核一致）。
- 前置核对：FT4232H（VID_0403&PID_6011）9 个实体全部 `OK`、驱动统一 2.12.36.4、无 JTAG 占用。
- 时间：**22:23:15 开始核对 → 烧录 22:23:23 → 22:23:33 完成**（一次成功，未重试）。
- 模式：`-m jtag`（JTAG 临时加载，未写 SPI）；脚本 exit 0（nativeExit 0）。
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261021_222323.log`（735 B）
- 判据：`Device ID read from JTAG: 0x10660A79` = **PASS**、`finished with JTAG programming` = **PASS**。
- 结论：**第二次烧录成功，板上仍是/再次为 v7_SENSE6**；待 Kevin 看屏幕。

---

## 9. 其它如实记录

| 项 | 记录 |
|---|---|
| 构建后源树完整性 | 166 文件与构建前清单 **0 差异**（`sense6_manifest_after_build.csv`）；构建未回写源码 |
| route 阶段（hold 修复前）告警 | `pnr2.log` 5 条 "may not meet hold"（tx_cal_clk_90edge −0.648 / sdram −0.364 / rx −0.685 / tx −0.382 / core −0.629 ns）；属路由阶段分析，最终 hold 18/18 全正（最小 +0.027） |
| 未验证项 | SENSE6 的 I2C 诊断显示/传感器是否恢复**只能上板观察**；本轮未读屏幕，不下画面结论 |
| v7_sense5_build.md | 已在上一轮（21:39）写完（16,084 B）；本轮复核其关键数字与 SENSE5 日志一致（`place.rpt` 31,407/118/15、位流 2,629,923 B sha `DEA095C2…B6E6`），无需重写 |

---

## 10. 证据索引

| 证据 | 路径 |
|---|---|
| 本文件 | `D:\FPGA\mmt\out\evidence\v7_sense6_build.md` |
| 构建日志 | `D:\v7work\v7_SENSE6\out\build.log`（快照 `...\SENSE6\build.log.snapshot`） |
| 流程 stdout | `...\SENSE6\flow_stdout.log` |
| 最终时序原始表 | `D:\v7work\v7_SENSE6\out\pnr2.log`（final L1250、Setup L1607、Hold L1628）；快照 `...\SENSE6\pnr2_final_timing_tables.txt` |
| 时序逐行对照 CSV | `...\SENSE6\timing_final_SENSE5_vs_SENSE6.csv` |
| 资源 | `D:\v7work\v7_SENSE6\out\ti60f225_oob.place.rpt`（快照 `...\SENSE6\place.rpt.snapshot`）、`ti60f225_oob.hier_util.rpt` |
| 入参核对 / 全树 diff | `...\SENSE6\prep_sense6.log`、`sense5_manifest.csv`、`sense6_manifest_before_build.csv`、`sense6_manifest_after_build.csv` |
| 烧录日志 | `D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261021_221738.log`；快照 `...\SENSE6\flash_log_snapshot.txt`、`flash_stdout.log` |
| 位流 | `D:\v7work\v7_SENSE6\out\v7_SENSE6.bit` |
| 构建工具 | `D:\FPGA\mmt\tools\v7_flow.ps1`、`D:\FPGA\mmt\tools\flash_vendor.ps1`（均未改） |

---

## 11. 边界声明

- **只烧录了本次 SENSE6 位流一次**（JTAG 临时加载，未写 SPI），无重试；未烧录其他任何东西。
- 未 push；未删文件；未改任何 RTL/约束/IP（构建后源树 166 文件 0 差异）。
- 仅新增：`D:\v7work\v7_SENSE6\`（构建副本）、`D:\FPGA\mmt\out\evidence\v7_abc2\SENSE6\`（取证文件）、本文件。
- 板上当前 = v7_SENSE6；是否保持/回退/继续调参由 Kevin 与指挥官决定。
