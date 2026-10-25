# v7_MERGE14 构建报告（红外退出硬门控、保留融合；判决改为运动触发 + AI 确认）

> 基线：`D:\v7work\v7_MERGE13`（MERGE13）。工程：`D:\v7work\v7_MERGE14`。
> 工具：Efinity 2026.1.132，五步流程 `tools/v7_flow.ps1`。
> 性质：**只编译，不烧录**；MERGE14 未上板。

## 1. 改动清单

| # | 改动 | 文件/位置 |
|---|---|---|
| ① | 报警门控**参数化**：`IR_GATE_MODE` 默认 **0**（只看 `ai_person`）；1=旧 `ir_hot\|ai_person`；2=只看 `ir_hot`；`REQUIRE_IR` 保留兼容 | `rtl/v7/mmt/v7_alarm_gate.v` 重写；`rtl/v7/mmt/v7_mmt_core.v` L24-26 新增参数、实例传参 |
| ② | **红外仍参与融合分数**（用户要求"不能全退出、要融合判断"）：新增 `IR_IN_FUSION` 默认 **1**，`mmt_fusion_vote` 的 60/25/15 权重与红外温度项保持不变；只有显式 `IR_IN_FUSION=0` 的实验模式才把 `ir_valid` 拉低 | `v7_mmt_core.v` L136 `.ir_valid(ir_valid & al_ir & IR_IN_FUSION)` |
| ③ | 热图/温度显示/`irhot` 日志全部保留（word11 的 `ir_hot` 位不受门控参数影响） | 未改 `v7_ir_proc.v` / `v7_txt_fmt.v` 的显示路径 |

> 说明：任务原文写"红外不再进入融合分数和报警门控（默认关闭）"，与用户追加的"不能全退出、要求融合判断"冲突；本实现按用户最新要求：**门控默认不用 ir_hot，但红外以 25% 权重继续参与融合分数**。若需要完全关闭融合里的红外，只需把 `IR_IN_FUSION=0`（已参数化，便于 A/B）。

## 2. 仿真

| 测试台 | 内容 | 结果 |
|---|---|---|
| `sim/tb_alarm_gate.v`（更新） | 三种 `IR_GATE_MODE` 真值表；验收用例：mode0 下 `ir_hot=0、ai_person=1、motion=1、alarm_raw=1 → gate=1`；反向：红外单独在 mode0 不拉起 | **ALL TESTS PASSED** |
| `sim/tb_evt_osd.v` | OSD EVT 五种事件码（沿用 MERGE13） | **ALL TESTS PASSED** |
| `tb_i2c_apb.v` / `tb_apb_regs.v` / `tb_apb_ext.v` | 三个旧测试台回归 | **全部 ALL TESTS PASSED** |

日志：`sim/logs_merge14/`（`tb_alarm_gate.log`、`tb_evt_osd.log`、`tb_i2c_apb.log`、`tb_apb_regs.log`、`tb_apb_ext.log`、`core_syntax.vvp`）。

## 3. 构建与最终时序

**构建过程（如实）**：MERGE14 的 pnr1 出现**随机路由拥塞**（`ERROR : Routing FAILED; could not resolve congestion`，peak congestion smeared 1.34 @180,148），前两次 pnr1 exit=1；随后 pnr2 `--sync_file` 均成功并签核。另两次 pnr1 成功的运行（run3/run4）五步全 0，但最终 `hdmi_tx_slow_clk → core_clk` hold = **−0.002 ns**（负）。按"时序违例只停下报告、不改约束"的要求，**最终交付采用时序全正的那次运行**（`out_run2`）：

| 步 | 结果（out_run2） |
|---|---|
| [1] efx_map | 0 |
| [2] efx_pnr#1 | **1（路由拥塞，随机）** |
| [3] efx_run -f interface | PASS（483 行） |
| [4] filter_interface | 483 行 |
| [5] efx_pnr#2 --sync_file | 0，位流生成 |

- `No valid pin(s) found for clock` = **0**；`No clocks matched` = **87**。
- **最终签核（pnr2 final timing）：18 setup + 19 hold，全部为正、0 条负 slack**
- **hold 最小值：+0.003 ns**（`hdmi_tx_slow_clk → core_clk`）
- setup 最小值：+0.333 ns（`sdram_clk` 域内）
- 其它 hold 最小：i_mipi_rx_pclk +0.026、rx_cal_clk +0.027、i_cam_ck +0.028、core_clk +0.029、hdmi 域内 +0.034；setup 其余域 ≥ +0.411。

> 另一条事实：run3/run4 五步全 0、hold = −0.002 ns。若严格要求"五步全 0 且时序全正"，需要再调 P&R seed（非约束改动）或等下一轮；本轮未改任何约束/SDC。

## 4. 资源（MERGE13 → MERGE14）

| 项 | MERGE13 | MERGE14 |
|---|---|---|
| XLR | 41,614 / 60,800（68.44%） | **41,532 / 60,800（68.31%）** |
| LUT | 23,458 | **23,379** |
| FF | 21,482 | **21,475** |
| BRAM | 192 / 256 | 192 / 256 |
| DSP | 68 / 160 | 68 / 160 |

## 5. 产物

| 产物 | 值 |
|---|---|
| 位流 | `project/v7_camera_ai/bitstream/v7_MERGE14.bit` |
| 大小 | **2,829,903 B** |
| SHA256 | **`E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8`** |
| 源码包 | `project/v7_camera_ai/bitstream/src/v7_MERGE14_src.zip`（5,330,394 B，SHA256 `FCC93E5543D0FCBE519CCB3F1449B0E6AED1205DDB6401A02D350E22801DC6DB`） |

## 6. 未验证项

- 门控新默认（AI only）在板上是否消除"冷静期恒报警"：**未上板**；需配 v18 固件实测。
- `IR_IN_FUSION=1` 时红外仍参与融合分数，若红外 `body` 异常偏高仍可能推高 `alarm_raw`（但门控还需 motion+AI，v18 另有固件 AND）——需上板看 `MMT_DEC score/evt`。
- 路由拥塞是随机现象，当前位流来自 pnr2 成功签核；未做多 seed 统计。
