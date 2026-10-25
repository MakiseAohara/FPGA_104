# v7_MERGE13 构建报告（RTL 三处改动）

> 基线：`D:\v7work\v7_MERGE12`（MERGE12）。工程：`D:\v7work\v7_MERGE13`（全新目录）。
> 构建时间：2026-10-25 14:33:20 → 14:40:16。工具：Efinity 2026.1.132，五步流程。
> 性质：**只编译，不烧录**；MERGE13 未上板。

## 1. 改动清单（仅 RTL 三处 + 新增门控模块）

| # | 改动 | 文件/位置 |
|---|---|---|
| ① | `HOT_ON` 48 → **24**（保持为参数） | `rtl/v7/mmt/v7_mmt_core.v` L23 |
| ② | 报警门控：`alarm_raw ∧ motion ∧ (ir_hot ∨ ai_person)`；单列成 `v7_alarm_gate` 模块（`REQUIRE_IR=1` 时走 `ir_hot | ai_person`，=0 时只看 motion） | 新增 `rtl/v7/mmt/v7_alarm_gate.v`；`v7_mmt_core.v` 实例 `u_gate`；门控使用 `ai_p_eff`（= `ai_alive ? score≥AI_TH : ai_person`） |
| ③ | OSD 的 `EVT` 改为显示固件写入的 **word14 事件类型**（1=INTRUDE、2=TREND、3=PERSON、4=LOWPWR、其它=NORMAL）；RTL `alarm_on` 仍驱动红框/LED/蜂鸣器 | `v7_apb_ext.v`：捕获 word14[23:16]，toggle 握手到视频域输出 `fw_evt_v`；`v7_mmt_core.v` 新增输入 `fw_evt` 并接 `v7_txt_fmt.evt_code`；`v7_txt_fmt.v` 用 `evt_code` 生成 `EVT` 7 字符 |

其它：`ti60f225_oob.xml` 增加 `v7_alarm_gate.v` 的 design_file 行；`v7_mmt_core.v` 新增端口 `fw_evt[7:0]`，顶层新增连线 `fw_evt_v`。

## 2. 新增/更新的仿真

| 测试台 | 内容 | 结果 |
|---|---|---|
| `sim/tb_alarm_gate.v`（新增） | 门控真值表；**验收用例：ir_hot=0、ai_person=1、motion=1、alarm_raw=1 → gate=1**；另测无 AI/无红外→0、无运动→0、alarm_raw=0→0、REQUIRE_IR=0 只看 motion | **ALL TESTS PASSED** |
| `sim/tb_evt_osd.v`（新增） | 依次驱动 evt_code=1/2/3/4/0，捕获 OSD 文字 RAM 128–138 字节并解码：`EVT=INTRUDE/TREND/PERSON/LOWPWR/NORMAL`；反证 alarm_on=1 且 evt_code=0 时仍为 NORMAL | **ALL TESTS PASSED** |
| 既有 `tb_i2c_apb.v` / `tb_apb_regs.v` / `tb_apb_ext.v` | MERGE13 上回归 | **三个均 ALL TESTS PASSED** |

日志：`sim/logs_merge13/`（`tb_alarm_gate.log`、`tb_evt_osd.log`、`tb_i2c_apb.log`、`tb_apb_regs.log`、`tb_apb_ext.log`、`core_syntax.vvp`）。

## 3. 五步构建

| 步 | 结果 |
|---|---|
| [1] efx_map | 退出码 **0** |
| [2] efx_pnr#1 | 退出码 **0** |
| [3] efx_run -f interface | **PASS**（483 行） |
| [4] filter_interface | wrote **483** lines |
| [5] efx_pnr#2 --sync_file | 退出码 **0** |

- `No valid pin(s) found for clock` = **0**
- `No clocks matched` = **87**
- ERROR 行 = **0**

## 4. 资源（MERGE12 → MERGE13）

| 项 | MERGE12 | MERGE13 |
|---|---|---|
| XLR | 41,568 / 60,800（68.37%） | **41,614 / 60,800（68.44%）** |
| LUT | 23,433 | **23,458（+25）** |
| FF | 21,462 | **21,482（+20）** |
| BRAM | 192 / 256 | 192 / 256（不变） |
| DSP | 68 / 160 | 68 / 160（不变） |

## 5. 最终时序（pnr2.log final timing；18 setup + 19 hold，全部为正、0 条负 slack）

| 时钟域 | setup 最差 (ns) | hold 最差 (ns) |
|---|---|---|
| tx_cal_clk | +0.527 | +0.096 |
| tx_cal_clk_90edge | +0.393 | +0.090 |
| sdram_clk | +0.409 | +0.097 |
| rx_cal_clk | +0.460 | +0.031 |
| core_clk | +1.779 | **+0.011（hdmi→core CDC，全局最差）** |
| vid_clk_dvi2 | +7.530 | +0.090 |
| hdmi_tx_slow_clk | **+0.283（全局最差 setup）** | +0.031 |
| i_cam_ck_CLKOUT | +5.304 | +0.045 |
| i_mipi_rx_pclk | +8.676 | +0.028 |
| CLK_5M | +196.384 | +0.050 |

**最小余量**：setup **+0.283 ns**（hdmi 域内），hold **+0.011 ns**（hdmi_tx_slow_clk → core_clk CDC）。

## 6. 产物

| 产物 | 值 |
|---|---|
| 位流 | `D:\v7work\v7_MERGE13\out\v7_MERGE13.bit` |
| 大小 | **2,824,365 B** |
| SHA256 | **`58C667D248A5E3B5B8E6DD1F9FD7ACD0DEA1E1094890450294E80C9577978F46`** |
| 源码包 | 推送清单 `v7_MERGE13_src.zip` |

## 7. 行为影响与未验证项（如实）

- **OSD EVT**：现在完全由固件 word14 驱动；若使用不写 evt 的旧固件/未使能固件决策，`EVT` 会显示 `NORMAL`（红框/LED/蜂鸣器仍由 RTL `alarm_on` 驱动，不受影响）。推荐配 v17 固件（evt=1/2/3/4）。
- **门控里的 ai_person**：实际接的是 `ai_p_eff`；MERGE13 固件组合（v17：写 reg9、reg10=0 使 `ai_alive=0`）下等于 `ai_person`；若未来固件写 reg10（`ai_alive=1`），则按 `score≥AI_TH` 判。
- **HOT_ON=24**：按离线诊断（0.5 m 人体 Δ 均值≈0.85 ℃、最大 1.7 ℃；无人最大 1.4 ℃）设为 24（≈0.9 ℃），仍用单帧判据；建议上板后再按噪声加多帧/面积确认。
- **未上板**：HOT_ON/门控/OSD EVT 三个改动的实际现象、8 Hz 红外与 400 kHz I2C 的稳定性、白平衡新值均未上板验证；MERGE13 未烧录。
- 未改动任何约束/SDC；未新增 RTL 端口到外部引脚；`No clocks matched` 基线不变。
