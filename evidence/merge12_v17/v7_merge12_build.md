# v7_MERGE12 构建报告（合并 MERGE9 改动 + 白平衡）

> 基线：`D:\v7work\v7_MERGE11`（MERGE11）。工程：`D:\v7work\v7_MERGE12`（全新目录）。
> 构建时间：2026-10-25 14:16:44 起。工具：Efinity 2026.1.132，五步流程 `tools/v7_flow.ps1`。
> 性质：**只编译，不烧录**；MERGE12 尚未上板。

## 0. 决策记录（重要）

任务要求"并入 MERGE9"，但**本机与 origin/main 全部远端分支都没有 MERGE9 的源码包/工程/指令文档**（已检索：`D:\FPGA\mmt\sim\v7_merge9` 不存在、`D:\v7work` 无 MERGE9、6 个远端分支 git grep `IR_REFRESH_CODE|MERGE9|IR_PERIOD_MS=125|SCL_HZ=400` 全部 0 命中）。因此按任务列出的 4 项改动**以等效方式实现**：

| MERGE9 项 | 本次实现（MERGE12 相对于 MERGE11） | 位置 |
|---|---|---|
| `IR_REFRESH_CODE` | 新增 `IR_REFRESH_CODE = 3'b100`（MLX90640 0x800D 刷新率 8 Hz），经 `mmt_sensor_subsystem` 透传到 `mmt_mlx90640_ctrl.REFRESH_CODE` | `v7_mmt_core.v:15,:98`、`mmt_sensor_subsystem.v:35,:211` |
| SCL 400 k | `v7_mmt_core` 参数 `SCL_HZ = 400_000`（传感器 I2C） | `v7_mmt_core.v:12` |
| `IR_PERIOD_MS=125` | `v7_mmt_core` 参数 `IR_PERIOD_MS = 125`（8 Hz） | `v7_mmt_core.v:14` |
| bstep 舍入 | `v7_ir_proc` 背景步进改为**有符号对称舍入**：`(d>0)?((d+7)>>>3) : -(((-d)+7)>>>3)`（原先负数直接 `>>>3` 是向下取整，基线永远追不上） | `v7_ir_proc.v:39-42` |
| 白平衡 | VIO 初值 R `'h118` / G `'h0E8` / B `'h158`（MERGE11 为 `'h158`/`'h118`/`'h1C0`） | `debug_top.v:102-104` |

若后续拿到 MERGE9 原始工程，可按上表逐项对照复核（本表即合并清单）。

## 1. 五步构建

| 步 | 结果 |
|---|---|
| [1] efx_map | 退出码 **0** |
| [2] efx_pnr#1 | 退出码 **0** |
| [3] efx_run -f interface | **PASS**（483 行） |
| [4] filter_interface | wrote **483** lines |
| [5] efx_pnr#2 --sync_file | 退出码 **0** |

- `No valid pin(s) found for clock` = **0**
- `No clocks matched` = **87**（与 MERGE10/11 基线一致）
- ERROR 行 = **0**
- 耗时：14:16:44 → 14:24:08

## 2. 资源（MERGE11 → MERGE12）

| 项 | MERGE11 | MERGE12 |
|---|---|---|
| XLR | 41,493 / 60,800（68.25%） | **41,568 / 60,800（68.37%，+75）** |
| LUT | 23,358 | **23,433（+75）** |
| FF | 21,462 | 21,462（不变） |
| BRAM | 192 / 256 | 192 / 256（不变） |
| DSP | 68 / 160 | 68 / 160（不变） |

## 3. 最终时序（pnr2.log final timing；18 setup + 19 hold，全部为正、0 条负 slack）

| 时钟域 | setup 最差 (ns) | hold 最差 (ns) |
|---|---|---|
| tx_cal_clk | **+0.240** | +0.095 |
| tx_cal_clk_90edge | +0.443 | +0.041 |
| sdram_clk | +0.289 | +0.076 |
| rx_cal_clk | +0.411 | +0.040 |
| core_clk | +1.849 | **+0.022（hdmi→core CDC）** |
| vid_clk_dvi2 | +7.297 | +0.047 |
| hdmi_tx_slow_clk | +0.702 | +0.035 |
| i_cam_ck_CLKOUT | +4.753 | +0.030 |
| i_mipi_rx_pclk | +8.508 | +0.034 |
| CLK_5M | +196.311 | +0.082 |

**全局最差**：setup **+0.240 ns**（tx_cal_clk 域）、hold **+0.022 ns**（hdmi_tx_slow_clk → core_clk，新增 CDC 关系，MERGE11 为 +0.007 ns）。

## 4. 产物

| 产物 | 值 |
|---|---|
| 位流 | `D:\v7work\v7_MERGE12\out\v7_MERGE12.bit` |
| 大小 | **2,826,123 B** |
| SHA256 | **`9940EF0921DEE84B29D986F6609EE4EA734ECEE7AA115F64DEC4DFA7A3EE4D94`** |
| 源码包 | 见推送清单 `v7_MERGE12_src.zip` |

## 5. 未验证项 / 风险（如实）

- **SCL 400 k + MLX 8 Hz**：本次只做了 RTL 参数改动与构建/时序验证，**未上板**。400 kHz 在长杜邦线 + 弱上拉条件下可能通信失败；8 Hz 刷新需 MLX90640 实际支持（0x800D 的 `100` 码），需上板用 OSD `SNS=`/`MMT_LP` 读数确认。
- **bstep 对称舍入**：逻辑改动小，但效果（基线跟踪速度/热点稳定性）未上板验证。
- **白平衡 R/G/B 新值**：需上板目视/用 OSD 画面判断颜色，当前只有构建证据。
- MERGE12 的 `IR_REFRESH_CODE` 与 SCL 参数是"按名称等效实现"，不保证与未找到的 MERGE9 源码逐位一致。
- 所有仿真测试未因本次 RTL 改动重跑（改动仅参数与 bstep 舍入，v7 核心语法编译通过，见 `sim/logs_merge11` 的既有测试仍适用于未改动模块；MERGE12 未新增测试台）。
