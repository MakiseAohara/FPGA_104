# GE_FIX_P3 — 从 MERGE17 源码加千兆网口（2026-11-03）

> 结论先行：**未产出可用位流**。集成代码与环境全部就绪，卡在 **GE 引脚的 IO bank 电压不匹配**（bank 1A/1B 为 1.8 V，3.3 V LVCMOS 不被支持），interface 阶段报错；A/B 两版位流均未生成。以下为完整过程与证据。

## 1 复现 MERGE17（基线确认）

| 项 | 结果 |
|---|---|
| 源码快照 | `D:\v7work\v7_MERGE17` → 复制为 `D:\v7work\v7_MERGE17_REPRO`（排除 out/work_syn/work_pnr/outflow） |
| 源码差异 | 与 MERGE17 快照逐文件 SHA256 比对：**0 差异**（262 文件） |
| 流程/种子 | `v7_flow_seed6.ps1`，`--seed 6`，`--optimization_level TIMING_3`、`--placer_effort_level 2` |
| 工具版本 | Efinity **2026.1.132**（与产出 MERGE17 时相同） |
| 复现位流 | `v7_REPRO.bit`，**2,845,704 B**，SHA256 **78A4E87D298926BF8A8837EA074C07B6962481AFBC921F6BCDEBDF235AA5C7C8** |
| 目标位流 | `v7_MERGE17.bit`，**2,845,704 B**，SHA256 **3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF** |

**判定**：大小完全一致、源码 0 差异、seed/工具一致，但哈希不同 → **PnR 布局布线非确定性**（Efinity placer 同 seed 不保证逐字节复现；此前 MERGE16 也是多 seed 才成功）。因此"逐字节复现位流"这一条**不成立**，但"源码是 MERGE17 那一版"已由 0 差异确认，按此继续。

## 2 GE 集成（MERGE17_GE_A）

### 2.1 RTL 改动（顶层 `ti60f225_oob_top.v`）

| 改动 | 内容 |
|---|---|
| 端口 | 新增 14 个：`ge_rxc`、`ge_rxd[3:0]`、`ge_rx_ctl`（输入）；`ge_txd[3:0]`、`ge_txc`、`ge_tx_ctl`、`ge_phy_rst_n`、`ge_mdc`（输出）。`ge_mdio` 因 Efinity 不支持顶层三态（EFX-0410）已移除 |
| 实例 | `ge_top_user u0_ge`，`clk=core_clk`，APB 接 `soc_apb_*`，`psel` 带窗口译码 `paddr[6:2] ∈ 27..31`（0x6C–0x7C） |
| 读多路 | `case` 增加 `5'd27..5'd31: soc_apb_prdata = ge_prdata;` |

### 2.2 文件清单（XML design_file）

新增：`rtl/ge/ge_top_user.v`、`ge_raw_tx.v`、`ge_raw_rx.v`、`ge_eth_apb.v`、`crc.v`、`util_gmii_to_rgmii.v`（后两者来自厂商 GE demo `04_Ti60F225_tse_hj_demo_v5/rtl/heijin_test`）。
> 注：`ge_raw_tx.v` 依赖 `ge_dpram32`（在 `ge_eth_apb.v` 内）与 `crc`（厂商 `mac/crc.v`），缺一即 map 失败——已按报错逐个补齐。

### 2.3 引脚（peri.xml，14 个）

| 信号 | 引脚 | 信号 | 引脚 |
|---|---|---|---|
| ge_rxc | GPIOL_P_07 | ge_txd[0..3] | GPIOL_N_07 / N_06 / P_00 / N_05 |
| ge_rxd[0..3] | GPIOL_P_06 / P_05 / N_09 / N_10 | ge_txc | GPIOL_P_09 |
| ge_rx_ctl | GPIOL_N_00 | ge_tx_ctl | GPIOL_N_08 |
| ge_mdc | GPIOL_N_11 | ge_phy_rst_n | GPIOL_P_11 |

### 2.4 SDC

新增：`create_clock -name ge_rxc -period 8.000 [get_ports ge_rxc]` + 输入/输出 delay 各 2 ns。

## 3 编译结果（关键阻塞）

| 阶段 | 结果 |
|---|---|
| efx_map | **PASS**（退出码 0） |
| efx_pnr#1 | **PASS**（退出码 0） |
| efx_run -f interface | **FAIL** |

Interface 报错（原文摘要）：

```
Design check issue : name:ge_rxc type:gpio sev:error
  rule:gpio_rule_io_standard_bank
  msg:Mismatch voltage in I/O standard assignment in bank (1.8 V) and instance (3.3 V LVCMOS)
Design check issue : name:ge_rxc type:gpio sev:error
  rule:gpio_rule_io_standard_compatibility
  msg:I/O standard (3.3 V LVCMOS) is not supported in bank 1A
```

**检查结果（任务补充第 1 条要求的结论）**：GE 的 14 个引脚全部落在 **bank 1A / 1B**，该 bank 为 **1.8 V**，**不支持 3.3 V LVCMOS**；而传感器 I2C（`GPIOL_11` / `GPIOL_09`，J7 脚 32/34）在另一 bank（3.3 V）。**两者不同 bank，无法用同一电压**。

## 4 未完成项与原因

| 项 | 状态 | 原因 |
|---|---|---|
| MERGE17_GE_A 位流 | **未产出** | IO 标准冲突（1.8 V bank 配 3.3 V） |
| MERGE17_GE_B（跨域同步器） | **未做** | A 未通过，无对照 |
| `hdmi_tx_slow_clk → core_clk` 路径分析 | **未完成** | A 未出时序报告 |
| A 版差异清单 | 已完成（见 §2） | — |

## 5 下一步（需要决策）

1. **确认板载 PHY 的 IO 电压**：YT8531SC 的 RGMII 侧是 1.8 V 还是 3.3 V？
   - 若 PHY 侧 1.8 V：把 peri 里 14 个 GE 引脚改为 `1.8 V LVCMOS` 即可直接编译（其余不动）。
   - 若必须 3.3 V：需要把这 14 个信号换到 3.3 V bank 的引脚（bank 内空闲脚目前未梳理）。
2. 改完后重跑 A（约 40 分钟），再按 §3 的 issue 分析跨域路径决定是否做 B。

## 6 现场文件

| 文件 | 说明 |
|---|---|
| `D:\v7work\v7_MERGE17_REPRO\` | 集成工程（含 rtl/ge/ 6 文件、peri、sdc、xml） |
| `D:\v7work\v7_MERGE17_REPRO\out\v7_REPRO.bit` | 复现位流（78A4E87D…，2,845,704 B） |
| `D:\v7work\v7_MERGE17_REPRO\out\map.log` / `outflow/ti60f225_oob.log` | 编译日志（含上述报错原文） |
