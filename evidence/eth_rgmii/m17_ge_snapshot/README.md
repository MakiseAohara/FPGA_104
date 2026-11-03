# m17_ge 构建输入快照（2026-11-03）

用途：把"含网口的整套构建输入 + 报告"固化下来，供队友独立分析显示问题。**不含位流**。

## 文件来源

| 文件 | 说明 |
|---|---|
| `ti60f225_oob_top.v` | 含 `u0_ge` 实例化的顶层（GE 版） |
| `ti60f225_oob.peri.xml` | Efinity peripheral 配置 |
| `ti60f225_oob.sdc` | **原始时序约束**（未含本次试验加的两条 CDC 约束） |
| `ti60f225_oob.map.rpt` | 综合/映射报告 |
| `ti60f225_oob.timing.rpt` | 最终时序报告 |
| `ti60f225_oob.pinout.rpt` | 引脚/IO 标准/所属 bank |
| `ti60f225_oob.place.rpt` | 布局报告（含 Global Clocks 占用） |
| `ti60f225_oob.route.rpt` | 布线摘要 |
| `ti60f225_oob.cdc.rpt` | 跨时钟域检查报告 |
| `design_issue.xml` | Efinity 设计问题清单 |

**重要说明**：v1（`9A62F22A`）与 v2（`86D10972`）两次构建的 `*.timing.rpt / *.map.rpt`
在后续构建中被覆盖，现已不在磁盘上。这里给的是 **TEST-A（不含 GE、原始 SDC）** 那一版报告
（SHA256 `2F28EC01`）；MERGE17 的最终时序报告另见 `evidence/v29_rtl_ir_rot/timing_final.rpt`。
需要 v1/v2 报告可以按下面的命令重编复现（同一 RTL/SDC 下构建是确定的）。

v2 使用的约束快照见 `evidence/eth_rgmii/sdc_cdc_fix_2026-11-03.sdc`（在原始 SDC 末尾追加了
`set_false_path hdmi_tx_slow_clk -> core_clk` 和 `set_clock_groups -asynchronous -group {core_clk} -group {rxc}`）。

## 复现命令

```powershell
cd D:\eth_build\m17_ge
& D:\Efinity\2026.1\bin\efx_run.bat ti60f225_oob.xml -f compile
```

## 已完成的初步分析（对应任务第 2 条）

### a) 网口引脚 IO 标准与 bank 电压

| 引脚 | 信号 | 方向 | IO 标准 | bank 电压 | bank |
|---|---|---|---|---|---|
| H1 | rxc.P | Input | 1.8 V LVCMOS | 1.8 V | 1B |
| H3 | --EXT_CONFIG_CLK-- / rx_dv.N | Input | 1.8 V LVCMOS | 1.8 V | 1A |
| R2 | tx_en_o.N | Output | 1.8 V LVCMOS | 1.8 V | 1A |
| R3 | phy_rst_n | Output | **3.3 V LVCMOS** | 3.3 V | BL |

- HDMI/TMDS 全部在 **bank 3A（1.8 V）**：F13/F15/G13/G14/G15/H12/H13/H14；
- 传感器 I2C（`io_sns_sda`）在 **TL bank（3.3 V LVCMOS）**；
- **未发现同一个 bank 内混用不同电压**：1A/1B 全 1.8 V，BL/BR/TL/TR 全 3.3 V，3A/3B/4A/4B 各自单一电压。
- 需要人工确认的两点（软件判断不了）：
  1. `rx_dv.N` 落在 `H3`，该脚是 **`EXT_CONFIG_CLK` 复用脚**（工程用 active x1 + `enable_external_master_clock=off`，理论上可作普通 IO，但属于配置脚复用，值得在硬件上确认）；
  2. `phy_rst_n` 用 **3.3 V** 驱动，若板上 PHY 的复位脚是 1.8 V 域，需要确认电平兼容。

### b) 全局时钟占用

`ti60f225_oob.place.rpt` 里：**Global Clocks (GBUF): 19 / 32 (59.38%)** —— 没到芯片上限。
（这是 TEST-A 不含 GE 的数值；GE 版会再加 `rxc` 与 TX DDIO 时钟，约 21/32，仍有余量。）

### c) `hdmi_tx_slow_clk -> core_clk` 失败路径的性质

MERGE17 的时序报告里这条路径的发起/捕获是 `u_apb_ext` 的 `evt_q -> evt_c`、`env_q -> env_c`
（视频域采样到的证据字，CPU 通过 APB 回读），**不是像素/OSD 通路**，且 MERGE17 自身 slack 更差
（-0.984 ns）却能正常显示 —— 因此**不能把它当作黑屏的默认答案**，补同步器之前必须先证明相关性。

### d) 已实测的对照（截至本次提交）

| 位流 | SHA256 前 8 | GE | SDC | 固件 | HDMI | 网口 |
|---|---|---|---|---|---|---|
| MERGE17 | `3A69AAFB` | 无 | 原始 | v3.8 | ✅ 正常 | ❌ |
| GE v1 | `9A62F22A` | 有 | 原始 | e15 | ⚠️ 冻结 | ✅ |
| GE v2 | `86D10972` | 有 | +CDC 约束 | e15 | ❌ 黑屏 | ✅ |
| P1 | `8D069E0B` | 无 | +CDC 约束 | v3.8 | ❌ 黑屏 | ❌ |
| TEST-A | `2F28EC01` | 无 | 原始 | v3.8 | 待观察 | ❌ |
| MERGE21_WB | `D165EDCA` | 无 | 原始 | v3.8 | ❌ 不启动（串口无输出） | ❌ |

结论倾向：**v1 冻结 → v2 黑屏的唯一变量是本次加的 CDC 约束**（false path 让该路径彻底不受约束），
所以 v2/P1 的黑屏不能用来判定"GE 破坏了视频"；TEST-A（无 GE、原始 SDC）才是干净的对照。
