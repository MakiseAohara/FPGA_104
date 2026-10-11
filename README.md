# FPGA_104 —— 2026 全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 · 易灵思企业赛道 · 赛题三「多模态 AI 智能终端」）

本仓库保存**我们自己写的**代码与文档：RTL 子系统、RISC-V 固件、仿真、约束、工程描述文件与设计文档。

- 目标器件：**Efinix Titanium Ti60F225I3**（DemoBoard Ti60F225I3-V4）
- 工具链：**Efinity 2026.1.132**
- 工程顶层：`rtl/mmt/mmt_top.sv`（`mmt.xml` 里 top_module = `mmt_top`）

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/mmt/` | **我们写的 RTL**：顶层、SoC 子系统封装、跨时钟同步器、I2C 主机、OSD 叠加、报警控制等 |
| `sw/` | RISC-V 固件（C / 汇编 / 链接脚本 / 构建与装载脚本） |
| `sim/` | 仿真：传感器/寄存器 testbench，以及三主口 AXI 互联仿真（`sim/axi_ic/`） |
| `constr/` | 时序约束（SDC） |
| `tools/` | 辅助脚本（固件打包、寄存器生成等） |
| `mmt.xml` / `mmt.peri.xml` | Efinity 工程与引脚约束 |

## ⚠️ 本仓库**故意不包含**厂商提供的 IP 与加密 RTL

以下内容属于 Efinity / Efinix 的授权材料，**不适合放在公开仓库**，因此排除在外：

| 排除项 | 来源 | 如何获得 |
|---|---|---|
| `ip/`（`sapphire_soc`、`axi_interconnect`、`csi_rx_controller`、`tinyml` 等） | Efinity IP 生成器（`ipm_api_service.IPMDesignAPI`）生成 | 用 Efinity 的 Sapphire SoC / AXI Interconnect / CSI RX IP 重新生成；`rtl/mmt` 里保留了生成参数说明 |
| `rtl/ddr3_controller/`、`rtl/dvi_tx/`、`rtl/cam_i2c_ctrl/`、`rtl/debayer/`、`rtl/frame_buffer/`、`rtl/vga/`、`rtl/mipi_config/` | 易灵思官方 Demo 工程（含 IEEE-1735 加密文件） | 从易灵思官方 Demo 包获取（本工程基于 Ti60F225 DemoBoard v4 资料包） |

因此**本仓库不能直接编译**：需要先把上述厂商 IP 与 Demo RTL 放回 `ip/` 与 `rtl/` 对应位置，再按 `docs/` 里的说明配置 `mmt.xml`。

## 已实测的数据（Efinity 2026.1.132，Ti60F225I3）

| 项 | 结果 |
|---|---|
| `efx_map` / `efx_pnr` | 均通过（退出码 0），约 178 s + 183 s |
| XLR | 44,696 / 60,800（73.51%） |
| Block RAM | 222 / 256（86.72%） |
| DSP | 27 / 160（16.88%） |
| 时序 | **setup 全部为正**（最差 +0.394 ns，位于厂商 DDR3 PHY 的 400 MHz 域）；我们的 `core_clk` 域最差 +3.293 ns、视频域 +1.425 ns；CDC 报告无告警 |
| 仿真回归 | 传感器/寄存器 testbench 84 项全通过 |

设计文档（系统全貌、路线 B 接入、时序/CDC 分析、AXI 仿真结论、DDR 放置方案等）**不随本仓库公开**，仅保存在本地工程内。
