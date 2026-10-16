# SDC 约束名核对（task-25）

- 日期：2026-10-13
- 对象：`D:\FPGA\mmt\constr\ti60f225_oob.sdc`（核对时的版本 = 2026-10-13 13:25 那次 efx_pnr 用的 364 行版本）
- 分析人：timing-analyst
- **本次没有跑任何 Efinity 流程**；所有"约束没生效"的结论都来自工具自己的日志（`out\efx_pnr.log`），不是猜的。
- 改动：只改了 `constr\ti60f225_oob.sdc`（364 → 408 行，**5 处**改动），并新建本文档。**未碰 RTL / ip / mmt.xml**。
- 2026-10-13 追加（按 Lead 反馈）：① 补上 JTAG 时钟（改动 5）；② 修正 `i_mipi_rx_pclk` 的观察（厂商摄像头 demo 与我们完全一致，**不是偏差**，已删除原推断）；③ 新增"字节时钟 12.000 还是 14.286"的 A/B 取舍分析（§5A）。

---

## 0. 结论（先看这里）

### 0.1 ★★★ 最严重的一条不是名字错位，而是"整个 MIPI RX 字节时钟域没有时钟" ★★★

```
constr\ti60f225_oob.sdc:281（旧行号）: # create_clock -period 12.000 [get_ports {i_cam_ck_CLKOUT}]
                                        ↑ 被注释掉了
```

`i_cam_ck_CLKOUT` 是**真实存在、且真的在驱动触发器**的时钟网络，但**没有任何 `create_clock`**：

| 事实 | 证据 |
|---|---|
| 它是时钟网络（不是普通数据脚） | `outflow\mmt.interface.csv:29-32` 有 4 条 `clkout, 73/82/130/141, 323, -1, i_cam_ck_CLKOUT` |
| 它落在 MIPI 专用时钟脚上 | `outflow\mmt.pinout.csv:66`（`D8,GPIOT_N_09_CLK6_N,cam_ck.N`）、`:81`（`E8,...,cam_ck.P`），功能列含 `MIPI_GCLK` |
| 它驱动 CSI RX 的字节时钟 | `rtl\mmt\mmt_top.v:564` `.clk_byte_HS(i_cam_ck_CLKOUT)` |
| 它还驱动摄像头上游探针（task-19 刚加的） | `rtl\mmt\mmt_top.v:1479` `.clk_byte(i_cam_ck_CLKOUT)` |
| 该 IP 的规模 | `out\mmt.hier_util.rpt:54`：`inst_efx_csi2_rx` 共 **570 个 FF**、36 块 BRAM |

**后果**：这 570 个 FF（以及探针里字节域的 FF）**既不做建立/保持检查，也没有任何时钟关系**；同时下面 32 条 MIPI RX lane 约束**全部**因 `-clock i_cam_ck_CLKOUT` 找不到而失效（`out\efx_pnr.log:282-313`，逐条报 `No clocks matched 'i_cam_ck_CLKOUT'`）。换句话说，**整条摄像头接收通路的时序从来没被验证过**。

→ **已修**：取消注释（新 `:320`），并把 `i_cam_ck_CLKOUT` 并进第 26 行的 exclusive 时钟组（新 `:26`）。**"建时钟 + 单列一组"这个做法**与厂商 Ti60F225 官方工程一致（`D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:27` 建时钟、`:29` 单独列组）；**取值我们用 12.000ns 而不是厂商 TinyML 的 8.00ns，理由见 §4 改动 3**（两者摄像头 lane 数/端口命名不同）。

> 🔴 **2026-10-13 13:52 实测更正**：`create_clock` 那半**成功了**（时钟表里有 `i_cam_ck_CLKOUT 12.000`），但**"并进第 26 行 exclusive 组"这半没有生效** —— 因为第 26 行在文件里出现在第 320 行**之前**，工具执行到 26 行时这个时钟还不存在。实测证据与补丁见 **§9.2**。这条不修，两个新时钟就会一直按"工具自己编的派生关系"被计时（实测：core_clk↔i_cam_ck_CLKOUT 被编成 **2.000ns**）。

> ⚠️ **优先级提醒（Lead 核实后追加，务必不要误读）**：厂商那套**摄像头 demo**（`07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:256`）**同样没有**这条 `create_clock`（也是注释状态），而它**在板上是能跑出图像的**。
> ⇒ 所以这条属于 **"时序签核质量问题"**（该域从未被 STA 检查过，签核不完整，**必须修** ✓），
> **但不能当作"摄像头不出图"（task-19 的 CSI RX 不吐像素）的功能根因**。
> 排查"不出图"仍应走时钟 lane / 数据 lane / 寄存器配置 / FIFO 那条线（task-19/20/21）。本条的收益是"合入它以后这个域的时序才有保障"，不是"能修好图像"。

### 0.2 ★★ 第二条同类问题：`jtag_inst1_TCK` 也没有时钟（**已修**，改动 5）

`constr\ti60f225_oob.sdc:88（旧）` 只有注释掉的 `# create_clock -period <USER_PERIOD> [get_ports {jtag_inst1_TCK}]`。SoC 的 JTAG 调试口是**真实接口**（`rtl\mmt\mmt_top.v:229-236` 的 8 个端口；`:1521-1527` 注释说明 peri 里声明了 `JTAG_USER1` 硬块），所以 SoC 内部 TAP 的触发器同样**不计时**，且 12 条 JTAG I/O 约束（旧 `:77-88`）全部报 `No clocks matched 'jtag_inst1_TCK'` 而失效。

→ **已修**：新 `:98` 加 `create_clock -period 100.0000 [get_ports {jtag_inst1_TCK}]`（对齐厂商 `tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:26` 的 100ns=10MHz），并把它并进新 `:26` 的 exclusive 组（**只建时钟不并组**会像 2026-10-11 的 `core_clk↔hdmi_tx_slow_clk` 那样被算出"近零约束"的假关系，见 `docs\时序与CDC问题分析.md` §4.2）。
**影响**：新 `:99-110` 的 **12 条 JTAG I/O 约束首次生效**，写在 100ns 域 ⇒ 几乎不可能违例。另外旧 `:25` 那条 `set_clock_groups -group {i_soc_clk} -group {i_mipi_rx_pclk} -group {jtag_inst1_TCK}` 会从"整条作废"变成"部分生效"（只剩 `i_soc_clk` 空组告警，`i_mipi_rx_pclk` 与 JTAG 的互斥关系开始成立）—— 这正是该行原本的意图。

> 🔴 **2026-10-13 13:52 实测更正（两条）**：
> ① 时钟**创建成功**（表里有 `jtag_inst1_TCK 100.000`），但**并组没生效**（顺序问题，同 §0.1 的更正，见 §9.2）；实测 core_clk↔jtag_inst1_TCK 被工具编成 **10.000ns** 的派生关系。
> ② 12 条里只有 **8 条生效**：`:103/104`（`jtag_inst1_RESET`）与 `:107/108`（`jtag_inst1_UPDATE`）报 `No valid input port(s) found` —— 这两个端口被工具判为 **unconnected 并在 PnR 里移除**（`out\mmt.warn.log:5061-5062` 原话），所以这两对约束**永远不可能生效**，应删除。详见 §9.4。

### 0.3 名字错位本身（Claude 指出的那条）——确认成立

`o_cam_d0_FIFO_RD` / `i_cam_d0_FIFO_EMPTY` 这类名字**在本工程里不存在**：RTL 端口是 `cam_d0_FIFO_RD` / `cam_d0_FIFO_EMPTY`（`rtl\mmt\mmt_top.v:98-105`），**不带 `i_`/`o_` 前缀**。d0/d1 的 16 条约束因此从未生效；d2/d3 的 16 条本来写的就是正确名字。

**根因（已查实）**：这段是从**另一个工程**拷来的，只改了一半 ——
`D:\FPGA\易灵思\工作区\03_EVSoC源码\evsoc-main\cam_single\Ti60F225_dsi\edge_vision_soc.sdc:272-279` 用的正是 `o_cam_d0_FIFO_RD` / `i_cam_d0_HS_IN_0[*]`。
顺带说明：**厂商自己的 `Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:257-272` 也有同样的错位**（它也没有前缀 `i_`/`o_` 的正确名字），而 Interface Designer 生成的 `outflow\ti60f225_oob.pt.sdc:323-330` 用的是**正确名字** ⇒ 厂商手改的那份 SDC 本身就是坏的，我们继承了这个 bug。

### 0.4 总账

| | 条数 |
|---|---|
| 核对时**完全没生效**的约束行（工具日志实证） | **85** 行（9 类） |
| 其中本次**已修好**、修复后**实测已生效** | **50** 条（RX lane 32 + 摄像头 I2C/复位 10 + JTAG 8） |
| 其中**从"缺时钟"变成"缺端口"、仍失败**（建议删） | **4** 条（JTAG `jtag_inst1_RESET`/`_UPDATE` 的 4 行，见 §9.4） |
| 其中仍是死约束（建议删或另行处理，本次未动） | **31** 条 |

---

## 1. 取证方法

1. **工具日志是主证据**：`out\efx_pnr.log` 里每条 `WARNING : [SDC <文件>:<行号>] <原因>` 就是"这条约束没生效"的铁证。本次共引用 **85 个不同行号**。这是"实测"，不是"推断"。
2. **端口名对照**：解析 `rtl\mmt\mmt_top.v` 的模块端口表（第 42–239 行，共 **128 个顶层端口**），逐条比对 SDC 里所有 `get_ports {…}`。
3. **时钟名对照**：以 `out\mmt.timing.rpt` 的 "User target constrained clocks" 表（本次 14 条时钟）为准，判断 `-clock X` / `create_clock X` 的 X 是否成立。
4. **交叉参照**：厂商同板同摄像头工程（`07_官方demo工程\Ti60f225_sc431hai2hdmi_v1`、`tinyml\tinyml_vision\Ti60F225_*`）、以及 Interface Designer 生成的 `outflow\mmt.pt.sdc`。

> 下表所有 SDC 行号都是**核对时那版文件（364 行）的行号**（= `efx_pnr.log` 引用的行号）。改完之后的行号见第 4 节。

---

## 2. 逐条对照总表（85 条失效约束，按类分组）

| # | 类别 | SDC 行（旧） | 条数 | 工具报的原因（`efx_pnr.log`） | 影响 | 本次处理 |
|---|---|---|---|---|---|---|
| A | `create_clock` 目标对象不存在 | 5, 7, 19, 20 | 4 | `No valid object(s) found for 'axi_clk' / 'i_soc_clk' / 'fb' / 'pll_inst4_CLKOUT0'`（log:59-70） | 无害（这 4 个名字在网表里不存在，也就没有需要约束的逻辑）—— 但**噪声很大**，掩盖真问题 | 未动，建议删/加注释 |
| B | `create_clock` 值是占位符 | 98 | 1 | `Missing value for option -period`（`-period <USER_PERIOD>` 字面量） | `CLK_25M` 没有时钟。但全工程**没有任何 FF 用 CLK_25M 当时钟**（`grep CLK_25M rtl\mmt\mmt_top.v` 只有端口声明一处） ⇒ 无风险 | 未动，建议删或填 40.000 |
| C | `set_clock_groups` 整条作废 | 25 | 1 | `i_soc_clk`、`jtag_inst1_TCK` 都没时钟 ⇒ `Cannot set clock group when only one non-empty group remains` | 这条想把 `i_mipi_rx_pclk` 和 JTAG 互斥，结果**整条被丢弃**。补上 JTAG 时钟后（改动 5）它会变成"部分生效"（只剩 `i_soc_clk` 空组告警） | 未动（因改动 5 而自动恢复部分效果） |
| D | `set_clock_groups` 组内部分为空 | 26 | 1 | 只有 `axi_clk` 组空，其余组**仍生效**（见 log:77-78，无 "Unable to run"） | 无影响（其余时钟互斥关系已生效，这正是 2026-10-11 修 WNS 的基础） | 未动，建议删掉 `-group {axi_clk}` |
| E | 摄像头 I2C / 摄像头复位 I/O | 61, 62, 65-72 | 10 | `No clocks matched 'i_soc_clk'`（**先**卡在时钟上） | **该 5 个引脚完全没有 I/O 约束**（I2C 很慢，实际风险低，但这是真空白） | ✅ **已修**（名称 + 改成 `-clock CLK_5M`） |
| F | JTAG I/O | 77-88 | 12 | `No clocks matched 'jtag_inst1_TCK'` | JTAG 调试口 I/O 无约束；SoC TAP 域不计时 | ✅ **已修**（改动 5：建 100ns 时钟 + 并组） |
| G | DDR 地址位越界 | 127-130 | 4 | `set_output_delay: No valid output port(s) found` | 约束 `ddr_addr[14]`/`[15]`，而 `ROW_WIDTH=14`（`rtl\ddr3_controller\ddr3_parameter.vh:7`）⇒ 这两根不存在。无害 | ❌ 未修，建议删这 4 行 |
| H | **MIPI RX lane I/O** | 282-313 | **32** | `No clocks matched 'i_cam_ck_CLKOUT'` | ★ **全部失效**：摄像头 4 条 lane 的 HS 数据/FIFO_EMPTY 输入、FIFO_RD/RST 输出都没有外部时序约束；其中 d0/d1 那 16 行**另有**端口名错（双重失效） | ✅ **已修**（加时钟 + 改 d0/d1 名字） |
| I | MIPI TX lane I/O | 317-336 | 20 | `No valid output port found for -reference_pin`（`i_mipi_tx_pclk~CLKOUT~*` 不存在） | DSI TX 已从设计里删除（`mipi_dp_*` 端口不存在，RTL 注释见 `mmt_top.v:11-13`）⇒ 纯死约束，无害 | ❌ 未修，建议整块删除 |

**合计 4+1+1+1+10+12+4+32+20 = 85** ✔ 与 `efx_pnr.log` 引用的 85 个行号一致。

### 2.1 名字对照明细（核心：约束名 / 实际名）

| SDC 里的名字 | 旧行 | 实际应该是什么 | 证据 | 匹配 | 已改 |
|---|---|---|---|---|---|
| `o_cam_d0_FIFO_RD` | 282, 283 | `cam_d0_FIFO_RD` | `mmt_top.v:104` | ✗ | ✅ |
| `o_cam_d0_RST` | 284, 285 | `cam_d0_RST` | `mmt_top.v:103` | ✗ | ✅ |
| `i_cam_d0_FIFO_EMPTY` | 286, 287 | `cam_d0_FIFO_EMPTY` | `mmt_top.v:105` | ✗ | ✅ |
| `i_cam_d0_HS_IN[*]` | 288, 289 | `cam_d0_HS_IN[*]` | `mmt_top.v:98` | ✗ | ✅ |
| `o_cam_d1_FIFO_RD` / `o_cam_d1_RST` / `i_cam_d1_FIFO_EMPTY` / `i_cam_d1_HS_IN[*]` | 290-297 | `cam_d1_FIFO_RD` / `cam_d1_RST` / `cam_d1_FIFO_EMPTY` / `cam_d1_HS_IN[*]` | `mmt_top.v:110-114` | ✗ | ✅ |
| `o_cam_rstn[0]` | 61, 62 | `o_cam_rst_p` | `mmt_top.v:90`（`= ~w_arstn`，见 `:678`） | ✗ | ✅ |
| `i_cam_scl[0]` | 65, 66 | `io_cam_scl_IN` | `mmt_top.v:87` | ✗ | ✅ |
| `o_cam_scl_oe[0]` | 67, 68 | `io_cam_scl_OE` | `mmt_top.v:88`（`= ~scl_padoen_o`，见 `:679`） | ✗ | ✅ |
| `i_cam_sda[0]` | 69, 70 | `io_cam_sda_IN` | `mmt_top.v:82` | ✗ | ✅ |
| `o_cam_sda_oe[0]` | 71, 72 | `io_cam_sda_OE` | `mmt_top.v:84` | ✗ | ✅ |
| `-clock i_soc_clk` | 61-72 | 摄像头 I2C 实际在 **`CLK_5M`** 域 | `mmt_top.v:668` `.clk(CLK_5M)` | ✗ | ✅（改 `CLK_5M`） |
| `-clock i_soc_clk` | （Lead 已修）SPI 4 条 | `core_clk` | `mmt_top.v:549` `assign i_soc_clk = core_clk;` | — | 已是 core_clk（`:86-93`） |
| `-clock jtag_inst1_TCK` | 77-88 | 补 `create_clock -period 100.0000 [get_ports {jtag_inst1_TCK}]` | 厂商 `edge_vision_soc.sdc:26` | 名字本身没问题（是缺时钟） | ✅ 已补（改动 5） |
| `ddr_addr[14]` / `[15]` | 127-130 | 不存在（`ddr_addr[13:0]`） | `ddr3_parameter.vh:7` `ROW_WIDTH 14` | ✗ | ❌ 建议删 |
| `mipi_dp_*`（20 个名字） | 317-336 | 全都不存在（DSI TX 已删） | `mmt_top.v:11-13` 注释 + 端口表无此项 | ✗ | ❌ 建议删 |
| `axi_clk` / `i_soc_clk` / `fb` / `pll_inst4_CLKOUT0` | 5, 7, 19, 20 | 网表里没有这些对象 | `efx_pnr.log:59-70` | ✗ | ❌ 建议删/注 |

> 提醒：`i_soc_clk` 之所以"不存在"是因为 `mmt_top.v:72` 把该端口注释掉了，而 `:549` 只是一根**别名线网**（`assign i_soc_clk = core_clk;`），综合后不会再作为独立对象存在。这就是为什么 `create_clock … i_soc_clk`（`:7`）和 12 条 `-clock i_soc_clk` 全部落空。

---

## 3. 哪些"不生效"是**真风险**，哪些只是冗余

| 判定 | 项目 | 理由 |
|---|---|---|
| **真风险（已修）** | MIPI RX lane 全部 32 条 + 整个字节域无时钟 | 摄像头数据/时钟 lane 的外部建立保持完全没查；IP 内 570 个 FF 不计时。摄像头是本工程的核心输入通路（task-19/20/21 全都在查它）。**注意见 §0.1 的优先级提醒：厂商同款 demo 也缺这条约束却能出图 ⇒ 这是签核质量缺口，不是"不出图"的根因** |
| **真风险（已修）** | JTAG 域无时钟 + 12 条 JTAG I/O | 调试口，100ns 域，实际风险低，但同样"完全没约束"。已按 0.2/改动 5 补上 |
| 低风险（已修） | 摄像头 I2C/复位 10 条 | I2C 5MHz 域、`o_cam_rst_p` 是纯组合，几乎不可能违例；修了只是把空白补上 |
| 纯冗余 | MIPI TX 20 条、`ddr_addr[14]/[15]` 4 条、`axi_clk/i_soc_clk/fb/pll_inst4_CLKOUT0` 4 条 create_clock、`CLK_25M` 占位符 | 对象在设计里根本不存在（或没有 FF 使用该时钟），删掉只是让日志干净、真问题不被淹没 |
| ~~无风险但值得注意~~ → **已排除** | ~~`i_mipi_rx_pclk` 20ns vs 厂商 TinyML 10ns~~ | **Lead 核对后确认不是偏差**：厂商**摄像头** demo（`Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.peri.xml:356`）的 `i_mipi_rx_pclk` 同样是 `out_divider="56"`、SDC 同样是 20.0000ns（`ti60f225_oob.sdc:21`）⇒ 我们与摄像头参考完全一致。100MHz 那个是 TinyML 的**另一种设计**。原文关于 task-19 的推断已删除 |

---

## 4. 我改了什么（5 处，全部在 `constr\ti60f225_oob.sdc`）

> 新行号 = 改完之后的 **408 行**版本。

### 改动 1（新 `:26`）：把 MIPI RX 字节时钟 + JTAG 时钟并进 exclusive 时钟组

```tcl
# 改前（第 26 行末）
… -group {sdram_clk} -group {rx_cal_clk}
# 第一次改后（改动 3 的配套）
… -group {sdram_clk} -group {rx_cal_clk} -group {i_cam_ck_CLKOUT}
# 第二次改后（改动 5 的配套）
… -group {sdram_clk} -group {rx_cal_clk} -group {i_cam_ck_CLKOUT} -group {jtag_inst1_TCK}
```

**为什么必须同时改这条**：只加 `create_clock` 而不声明关系，工具会把新时钟与其它时钟当成"有确定相位关系"来分析，算出类似 `0.001 ns` 的假约束（2026-10-11 那次 WNS -3.589ns 就是这么来的，见 `docs\时序与CDC问题分析.md` §4.2），可能凭空冒出成百条假违规。厂商官方工程也是这么处理的（`edge_vision_soc.sdc:29` 把 `i_cam_ck_CLKOUT_0` 与 `jtag_inst1_TCK` 各自单列一组）。

> 🔴 **实测（13:52）证明了这个担心是对的，而且这条改动本身没生效**：因为 `set_clock_groups`（:25/:26）出现在两条 `create_clock`（:98 / :320）**之前**，工具执行到 26 行时两个时钟都还不存在 ⇒ 实测日志里 26 行报 `No clocks matched 'i_cam_ck_CLKOUT'`、`No clocks matched 'jtag_inst1_TCK'`，于是工具自己编了三条派生关系：`core_clk↔i_cam_ck_CLKOUT = 2.000ns`、`i_mipi_rx_pclk↔i_cam_ck_CLKOUT = 4.000ns`、`core_clk↔jtag_inst1_TCK = 10.000ns`（都是物理上无意义的数字）。**补丁见 §9.2**（把两条 `create_clock` 移到所有 `set_clock_groups` 之前）。

### 改动 2（新 `:61-84`）：摄像头 I2C / 复位 I/O 改成真实名字 + 真实时钟

```tcl
# 改前（10 条，全部失效）
set_output_delay -clock i_soc_clk -reference_pin [get_ports {i_soc_clk~CLKOUT~215~322}] -max 0.091 [get_ports {o_cam_rstn[0]}]
…（i_cam_scl[0] / o_cam_scl_oe[0] / i_cam_sda[0] / o_cam_sda_oe[0]，共 5 信号 × max/min）
# 改后（去 reference_pin，换真实时钟与端口名）
set_output_delay -clock CLK_5M -max 0.091 [get_ports {o_cam_rst_p}]
set_input_delay  -clock CLK_5M -max 0.795 [get_ports {io_cam_scl_IN}]
set_output_delay -clock CLK_5M -max 0.070 [get_ports {io_cam_scl_OE}]
set_input_delay  -clock CLK_5M -max 0.795 [get_ports {io_cam_sda_IN}]
set_output_delay -clock CLK_5M -max 0.070 [get_ports {io_cam_sda_OE}]
…（各带 max/min 一条）
```

域判定依据：`mmt_top.v:668` 摄像头 I2C 主机 `u2_i2c_master_ctrl_top` 的 `.clk(CLK_5M)`；OE 由 `scl_padoen_o` 组合产生（`:679`）。延时数值沿用原值（Interface Designer 按本板布线算的），换到 200ns 的 CLK_5M 后更容易满足。写法与 Lead 之前修 SPI 那 4 条一致（新 `:184-187`）。

### 改动 3（新 `:320`）：★ 取消注释 `i_cam_ck_CLKOUT` 的 `create_clock`

```tcl
# 改前（旧 :281）
# create_clock -period 12.000 [get_ports {i_cam_ck_CLKOUT}]
# 改后
create_clock -period 12.000 [get_ports {i_cam_ck_CLKOUT}]
```

取值 `12.000 ns`（83.3MHz）的依据：
1. 这一行的原值本来就是 `12.000`（本工程 SDC 与厂商 `Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:256` 同值）；
2. 本工程摄像头 I2C 寄存器表与厂商 `Ti60f225_sc431hai2hdmi_v1` **逐字节相同**（`rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v`，两文件 hash 均为 `DA82D962…9528`）⇒ 同一摄像头模式 ⇒ 同一 byte clock；
3. 旁证：厂商 Ti60F225 TinyML 系列（**2 lane**、端口名带 `_0`）用 `8.00`；本工程是 **4 lane** 的 OOB 配置，两者不是同一模式，故不直接采用 8.00。

> ⚠️ 但这个取值**与 IP 自己的配置有 20% 出入**，请务必读 **§5A 的 A/B 分析**（12.000 vs 14.286）后再定稿。

### 改动 4（新 `:326-341`）：MIPI RX d0/d1 端口名去前缀

```tcl
# 改前（16 条，全部失效）
… -max 0.604 [get_ports {o_cam_d0_FIFO_RD}]   # 应为 cam_d0_FIFO_RD
… [get_ports {o_cam_d0_RST}]  [get_ports {i_cam_d0_FIFO_EMPTY}]  [get_ports {i_cam_d0_HS_IN[*]}]
…（d1 同理）
# 改后
… -max 0.604 [get_ports {cam_d0_FIFO_RD}] … [get_ports {cam_d0_FIFO_EMPTY}] … [get_ports {cam_d0_HS_IN[*]}]
…（d1 同理）
```

延时数值与 reference_pin（`i_cam_ck_CLKOUT~CLKOUT~82/130~322`）都原样保留。

### 改动 5（新 `:98`）：补上 `jtag_inst1_TCK` 的 `create_clock`（Lead 采纳的建议）

```tcl
# 改前（旧 :88，只有注释模板）
# create_clock -period <USER_PERIOD> [get_ports {jtag_inst1_TCK}]
# 改后（新 :98）
create_clock -period 100.0000 [get_ports {jtag_inst1_TCK}]
```

- 取值 `100.0000 ns`（10MHz）对齐厂商 `tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:26`；
- 配套已把它加进新 `:26` 的 exclusive 组（否则会产生"近零约束"假关系）；
- 后果：新 `:99-110` 的 **12 条 JTAG I/O 约束首次生效**（写在 100ns 域，几乎不可能违例）；旧 `:25` 的那条 `set_clock_groups` 从"整条作废"变成"部分生效"（`i_mipi_rx_pclk` × JTAG 互斥开始成立，只剩 `i_soc_clk` 空组告警）。

> 说明：改动 2 的位置上我顺手恢复了被替换掉的 2 行 UART 注释模板（无害）；除此之外没有删除任何其它内容。

---

## 5. 哪些改动会让**时序报告变紧**（可能冒出新违例）

**1. 摄像头字节域从"完全不计时"变成"按 12ns 计时"。**
- 新增被检查的路径：`inst_efx_csi2_rx` 字节域内部（lane_aligner / byte2pixel 写侧等）、`u_cam_probe` 字节域 FF → 同步链。
- 预期：12ns 很宽松（83MHz），大概率全过；但 **CSI RX 是加密 IP，其内部路径此前从未被检查过**，出现若干条违例是有可能的 —— 一旦出现，是**真问题**（以前被掩盖），不是我的改动造成的。

**2. 32 条 MIPI RX lane I/O 约束从"失效"变成"生效"。**
- 输入：`cam_d0..d3_HS_IN[7:0]`（4×8=32 根）、`cam_d0..d3_FIFO_EMPTY`；
- 输出：`cam_d0..d3_FIFO_RD`、`cam_d0..d3_RST`（注：RTL `mmt_top.v:551-554` 把这 4 个 RST **恒接 0**，是常量输出，不会违例）。
- 数值与厂商同板 OOB 完全一致（0.604 / 0.725 / 0.560 / 0.362 / 0.070 / -0.140 / 0.420 / 0.325），**但我们的布局布线与厂商 demo 不同**，所以仍可能出现 I/O 违例。这是本次改动**最可能冒出新违例**的地方，请重点看。

**3. 10 条摄像头 I2C/复位 I/O（CLK_5M=200ns）**：几乎不可能违例。

**4. 12 条 JTAG I/O（`jtag_inst1_TCK`=100ns）**：随改动 5 首次生效，100ns 域 ⇒ 几乎不可能违例；同时 SoC JTAG TAP 域开始被计时。

**5. 时钟关系表的变化**：会出现 `i_cam_ck_CLKOUT` / `jtag_inst1_TCK` 相关行（若没有改动 1，就会是一堆 0.001ns 型假约束）。

> **没有变紧的**：核心逻辑（core_clk / DDR3 / HDMI / TinyML）完全不受影响 —— 我改的 54 条约束全部只涉及摄像头接口、I2C 引脚与 JTAG 引脚。

---

## 5A. 字节时钟取值：12.000 还是 14.286？（Lead 要求的备选值分析）

**关键新证据（本次追加）**：CSI RX IP 的生成配置里，字节时钟**自己写着 70MHz**：

```
mmt\ip\csi_rx_controller\settings.json:24:  "HS_BYTECLK_MHZ": "70",     ← 70MHz ⇒ 周期 14.2857ns
mmt\ip\csi_rx_controller\settings.json:22:  "NUM_DATA_LANE": "4",
mmt\ip\csi_rx_controller\settings.json:25:  "CLOCK_FREQ_MHZ": "100",    ← 与我们的 core_clk=100MHz 一致
```

而且**厂商能出图的那套摄像头 demo 配置与我们逐项相同**（`07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\ip\csi_rx_controller\settings.json`：`NUM_DATA_LANE=4`、`HS_BYTECLK_MHZ=70`、`CLOCK_FREQ_MHZ=100`、`PIXEL_FIFO_DEPTH=4096` 全部一致）；它的 SDC 里那条注释同样是 `12.000`。也就是说：

| 取值 | 来源 | 性质 |
|---|---|---|
| **14.2857 ns（70MHz）** | IP 自己的生成参数 `settings.json:24`（D-PHY 的 `tHS_SETTLE_NS=85` 等参数就是按这个频率标定的） | **设计意图值**，最可能等于真实字节时钟 |
| 12.000 ns（83.3MHz） | 两套工程的 SDC 注释里手写的值（本工程旧 `:281`、厂商 `ti60f225_oob.sdc:256`） | **从未被验证过的估计值**（因为那两套设计里它都被注释着，从来没生效过） |
| 8.00 ns（125MHz） | 厂商 Ti60F225 **TinyML** 系列（2 lane、端口名带 `_0`） | 另一种设计，不适用 |

**判断与建议**：
1. **12.000 相对 IP 配置是约 20% 的过约束**（12.000 vs 14.286）。它的好处是留工程余量；坏处是**字节域是第一次被分析**，任何过约束都会以"看起来像真违例"的形式出现，而**我们无法用肉眼区分它是真问题还是过约束假象** —— 这会白烧一轮重编 + 一轮排查。
2. **若重跑后出现字节域内部或 RX lane 的新负 slack**：先把新 `:320` 的 `12.000` 改成 **`14.286`**（与 `settings.json:24` 的 70MHz 对齐）再跑一次。
   - 若负 slack **随之消失** ⇒ 那是过约束假象，**定稿 14.286**（它才是与 IP 配置自洽的值）；
   - 若负 slack **依然存在**（14.286 下仍为负）⇒ 那是**真违例**（该域以前完全没查过），要按真实路径去修，**不要**再往下放松周期。
3. **是否保留 12.000 作为余量**：只有当你能**独立证实**实际字节时钟 ≥ 83.3MHz（例如从 SC431HAI 的 MIPI PLL 寄存器配置反推 lane rate，或示波器量 `i_cam_ck_CLKOUT`）时才值得保留。在无法证实的情况下，选 **14.286**（与 IP 参数一致）更站得住脚：签核报告要能解释"这个 12ns 是哪来的"，而 14.286 有 `settings.json:24` 这个白纸黑字的出处。
4. 无论取哪个，"**该有这个 create_clock**"这个结论不变；影响只在这 32 条 lane I/O 与字节域内部路径的松紧。

> 我这次**没有**把文件里的 12.000 改成 14.286 —— 因为你正在用 12.000 重编，我不想在你的 A/B 对照中途改输入。要换的话只需改新 `:320` 一个数字。

### 5A.1 ✅ 实测结论（2026-10-13 13:52 那次重编）

| 实测项 | 结果 |
|---|---|
| `out\mmt.timing.rpt` 全 408 条路径 | **最小 +0.019 ns，负 slack = 0** ✅（我自己复核过：`Slack` 行 408 条，`<0` 的 0 条） |
| `i_cam_ck_CLKOUT` 是否真进了约束时钟表 | **是**：`i_cam_ck_CLKOUT 12.000 83.333` 与 `jtag_inst1_TCK 100.000 10.000` 都在 "User target constrained clocks" 表里 |
| 12ns（而非 14.286）有没有造出违例 | **没有** ⇒ 按 §5A 第 2 条的判据：**12.000 站得住，保留 12.000** ✓ |
| 新增的 32 条 RX lane I/O + 10 条摄像头 I2C | **全部生效**（这两组在本次日志里一条警告都没有）⇒ 摄像头接口的时序空白已补上 |

**定稿：`:320` 保持 `12.000`，不动。** 14.286 仅作为"将来若出现字节域负 slack"时的后备值保留在文档里。

> ⚠️ 但**同一轮实测还暴露了一个必须修的问题**：我原本"把两个新时钟并进 exclusive 组"（改动 1）**没有生效** —— 原因是 SDC 的**求值顺序**。详见 **§9**（含补丁，按 Lead 要求暂不落到文件）。

---

## 6. 未改、只给建议的项（供 Lead 决定）

| 优先级 | 建议 | 具体改法 | 变紧? |
|---|---|---|---|
| ~~P1~~ **已完成** | ~~补 JTAG 时钟 + 并组~~ | 已按改动 5 写入（新 `:98` + 新 `:26`） | 是（已纳入本次） |
| P2 | 删掉 MIPI TX 死约束 20 行（旧 `:317-336`，改后位置 `:361-380`） | 整块删除（DSI TX 已从设计删除，`mipi_dp_*` 端口不存在） | 否 |
| P2 | 删掉 `ddr_addr[14]`/`[15]` 4 行（旧 `:127-130`，改后位置 `:149-152`） | 删除（`ROW_WIDTH=14`） | 否 |
| P3 | 清理 4 条死 `create_clock`（`:5`,`:7`,`:19`,`:20`） | 删除或改成注释并写明原因 | 否 |
| P3 | `:120` `create_clock -period <USER_PERIOD> [get_ports {CLK_25M}]` | 删除，或填 `40.000`（`mmt.peri.xml` 里 4 个 PLL 的 `ref_clock_freq="25.0000"`）。**注意：本设计无 FF 用 CLK_25M 当时钟，改与不改都不影响时序** | 否 |
| P3 | `:25` 整条 `set_clock_groups` | 补上 JTAG 时钟后它已"部分生效"；可再把空的 `-group {i_soc_clk}` 删掉让整条干净生效 | 否（当前只剩空组告警） |
| P3 | `:26` 里的 `-group {axi_clk}` | 删掉该空组，消掉 1 条 warning | 否 |

---

## 7. Lead 重跑验收清单

重跑 `efx_map` + `efx_pnr` 后，按顺序核对：

1. `out\efx_pnr.log` 里 `[SDC …]` 警告：
   - **必须消失**：`No clocks matched 'i_cam_ck_CLKOUT'`（原 32 条）、`No clocks matched 'i_soc_clk'` 里属于摄像头 I2C 的 10 条、`No valid output port(s) found`（原 d0/d1 的 16 条）、`No clocks matched 'jtag_inst1_TCK'`（原 12 条）。
   - **应仍然存在**（本次未动）：`i_mipi_tx_pclk~CLKOUT~` 20 条、`ddr_addr[14]/[15]` 4 条、4 条死 `create_clock`（`axi_clk`/`i_soc_clk`/`fb`/`pll_inst4_CLKOUT0`）、`CLK_25M` 1 条、`:25`/`:26` 空组告警 ⇒ 合计 **约 31 条**（85 − 54 已修）。
2. `out\mmt.timing.rpt` 的 **"User target constrained clocks"** 表应新增两行：`i_cam_ck_CLKOUT  12.000  83.333` 与 `jtag_inst1_TCK  100.000  10.000`。
3. `out\mmt.timing.rpt` 的 **"Setup (Max) Clock Relationship"** 表：应出现 `i_cam_ck_CLKOUT → i_cam_ck_CLKOUT`、`jtag_inst1_TCK → jtag_inst1_TCK` 两行；**不应**出现它们与其它时钟的 0.001ns 型关系（若出现，说明第 26 行没生效，立刻停下）。
4. 负 slack 是否仍为 0：重点看有没有 **`i_cam_ck_CLKOUT` 域内**或**摄像头 lane I/O** 相关的新负 slack（JTAG 是 100ns，基本不可能出问题）。**若出现，先按 §5A 把字节时钟从 12.000 放松到 14.286 再跑一次**，用这个 A/B 区分"过约束假象"与"真违例"。
5. `out\mmt.cdc.rpt`：应仍为 "No Synchronizer warnings to report."。
6. 资源（XLR/BRAM）不应有变化（纯约束改动）。

**回滚方法**：把 `constr\ti60f225_oob.sdc` 中新增的内容去掉即可 —— 具体是：`:26` 末尾的 `-group {i_cam_ck_CLKOUT}` 与 `-group {jtag_inst1_TCK}`、`:61-84` 的摄像头 I2C 块、`:88-98` 的 JTAG 注释+create_clock、`:320` 的 `create_clock`。`:326-341` 的 d0/d1 名字修正**不会**引起报告变化（时钟不存在时它们照样失效），即使保留也不影响。

**另外提醒**：`constr\ti60f225_oob.sdc` 是 Interface Designer 生成的文件，重新生成接口配置时**可能被覆盖**，本次改动需要重新应用（`outflow\mmt.pt.sdc` 是生成产物，可直接对照，但它是用 `<USER_PERIOD>` 占位、且不含我们手写的时钟组修订）。

---

## 8. 不确定 / 无法确认

1. **`12.000 ns` 是否等于实际 MIPI 字节时钟** → 已升级为 **§5A 的 A/B 方案**：IP 自己的配置是 `HS_BYTECLK_MHZ=70`（=14.2857ns，`settings.json:24`），所以 12.000 是约 20% 过约束。若重跑出现新负 slack，改成 14.286 再跑一次；消失则是过约束假象，仍在则是真违例。**"该有这个 create_clock"这个结论不受影响。**
2. **CSI RX 字节域到底多少个 FF**：只能给上限 570（整个 IP 的 FF 数，`mmt.hier_util.rpt:54`）；IP 加密，无法逐域统计。
3. ~~`i_mipi_rx_pclk` 20ns vs 厂商 10ns~~ → **已由 Lead 排除**：厂商**摄像头** demo 同样是 `out_divider="56"` + 20.0000ns（`Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.peri.xml:356`、`ti60f225_oob.sdc:21`），我们与摄像头参考一致；100MHz 属于 TinyML 的另一种设计。**不是偏差，本条关闭。**
4. **改动 2 的延时数值**（0.795/0.461/0.070/-0.026/0.091/-0.045）：这是 Interface Designer 针对 `i_soc_clk`+pad 参考点算的板级数值，我换了时钟但**没有重算**。因为 CLK_5M 是 200ns，这些数值过于宽松也不会误判失败；但严格来说应该让 Interface Designer 用 CLK_5M 重新生成。
5. **`o_cam_rst_p` 的约束意义**：它是 `~w_arstn` 的纯组合拷贝（`mmt_top.v:678`），没有时钟域。我按 CLK_5M 记了一条名义约束；如果 Lead 认为不该约束它，删掉这 2 行即可（无影响）。
6. **JTAG 的 100ns**：取自厂商 Ti60F225 TinyML demo（`edge_vision_soc.sdc:26`）。我们实际的 TCK 频率取决于调试器（Efinity 默认几 MHz 量级）；100ns 是**保守**取值，偏慢不会掩盖真问题（若要更严格可用 20ns=50MHz，但厂商没这么用）。

---

## 9. 2026-10-13 13:52 重编后的实测复核（含 4 条死 create_clock 的处置 + 顺序补丁）

> 本节全部基于 `out\efx_pnr.log`(13:52)、`out\mmt.timing.rpt`(13:52)、`out\mmt.warn.log`、`outflow\mmt.interface.csv`、`outflow\mmt_template.v`。**本节只写文档，补丁都没有落到 SDC 文件**（等 Lead 说可以再改）。

### 9.1 结果总览

| 项 | 实测 |
|---|---|
| 时序 | `mmt.timing.rpt` 共 **408 条** slack，**最小 +0.019ns、负 slack = 0** ✅ |
| 两个新时钟 | 都进了 "User target constrained clocks"：`i_cam_ck_CLKOUT 12.000 / 83.333`、`jtag_inst1_TCK 100.000 / 10.000` ✅ |
| 我修的 32 条 RX lane + 10 条摄像头 I2C | **全部生效**（日志里这些行号 0 警告）✅ |
| JTAG 12 条 | **8 条生效**；`jtag_inst1_RESET`/`_UPDATE` 的 4 条**仍失败**（见 9.4） |
| `[SDC]` 警告 | 不重复失败行号 **85 → 35**；日志文本行 246（口径见 9.5） |

### 9.2 ★ 顺序问题：Lead 的怀疑**已实测证实**（这是本轮最重要的待修项）

实测日志（`efx_pnr.log` 内 `[SDC …:26]` 的三种消息）：

```
No clocks matched 'i_cam_ck_CLKOUT'
No clocks matched 'jtag_inst1_TCK'
set_clock_groups: No valid clock(s) found for -group 'i_cam_ck_CLKOUT'
set_clock_groups: No valid clock(s) found for -group 'jtag_inst1_TCK'
```

⇒ 第 26 行**执行时**这两个时钟还不存在（`create_clock` 在 `:98` / `:320`，位于其后），所以两条 `-group` 被丢弃。**Efinity 的 SDC 是按文件顺序求值的**：`set_clock_groups` 只能对**此刻已存在的时钟**生效 —— 这是本轮实测新得到的结论。

**后果（实测的派生关系，全部来自 `mmt.timing.rpt` 的 Setup 表）**：

| 发射 → 捕获 | 工具编出的约束 | Slack |
|---|---|---|
| `core_clk` → `i_cam_ck_CLKOUT` | **2.000 ns** | +1.274 |
| `i_cam_ck_CLKOUT` → `core_clk` | **2.000 ns** | +0.316 ← 目前最紧的一条 setup |
| `i_mipi_rx_pclk` → `i_cam_ck_CLKOUT` | **4.000 ns** | +1.824 |
| `i_cam_ck_CLKOUT` → `i_mipi_rx_pclk` | **4.000 ns** | +1.463 |
| `core_clk` → `jtag_inst1_TCK` | **10.000 ns** | +9.476 |
| `jtag_inst1_TCK` → `core_clk` | **10.000 ns** | +8.076 |

这些数字正是"两个时钟没被声明关系时，工具在公共周期上取最坏边沿间距"的指纹，且算术完全对得上：`12 & 10 → LCM 60 → 最小间隔 2.000`；`12 & 20 → LCM 60 → 4.000`；`100 & 10 → LCM 100 → 10.000`。**这同时是我在 `docs\时序与CDC问题分析.md` §4.2 对旧 WNS(-3.589) 机制推断的第二次独立验证**（旧的 0.001 就是 `7.143 & 10 → LCM 50 → 0.001`）。

**为什么现在没出事、但仍然必须修**：这 6 条派生关系的 slack 目前都是正的（最紧 +0.316），所以负 slack = 0；但它们是**物理上无意义的时序要求** —— 一旦布线稍差就会像 2026-10-11 那样爆出假违例，而我们又得花一轮去分辨真假。修掉它 = 明确告诉工具"这两对时钟不互查"。

### 9.3 4 条死 `create_clock` 的性质与处置（Lead 要求逐条说明）

| 行 | 名字 | 它到底存在于哪 | 为什么不是合法对象 | 是否造成时序分析空白 | 正确写法 |
|---|---|---|---|---|---|
| `:5` | `axi_clk` | 只是**子模块端口标签**：`mmt_top.v:599` `.axi_clk(core_clk)`、`:736`、`:986`、`:946` `.m_axi_clk(core_clk)`、`:1204` `.i_axi_clk(i_mipi_clk)`（而 `:548` `i_mipi_clk = core_clk`） | 顶层**没有**名叫 `axi_clk` 的网络；这些端口的物理时钟**全都是 `core_clk`** | **无空白** ✅（`core_clk` 已约束，覆盖了它们）——与 Lead 初判一致 | **删** |
| `:7` | `i_soc_clk` | 端口已在 `mmt_top.v:72` 被注释掉；`:549` `assign i_soc_clk = core_clk;` 只是别名线网 | 别名被综合折叠进 `core_clk`，对象消失 | **无空白** ✅ | **删** |
| `:19` | `fb` | **本工程里根本没有**（`grep \bfb\b rtl\mmt\mmt_top.v` 无命中；它是厂商另一套设计的帧缓冲时钟名） | 网表里不存在 | **无空白** ✅ | **删** |
| `:20` | `pll_inst4_CLKOUT0` | `mmt.peri.xml:368` 里**确实**是 `pll_inst4` 的输出 0 | 但**没有任何逻辑连它** ⇒ 综合把该网络删掉（本工程只用同一 PLL 的输出 1 = `CLK_5M`，见 `mmt.peri.xml:369`） | **无空白** ✅（无负载） | **删**；将来真给它接负载时改用 `create_generated_clock -source … -name pll_inst4_CLKOUT0 [get_pins …]` |

**通用判据（很重要，可复用到以后）**：Efinity 的 `create_clock <裸名>` 是在**综合后网表**上解析名字的。报 `No valid object(s) found` ⟺ **该网络不存在** ⟺ 不可能有任何触发器被它驱动 ⟹ **不存在"被掩盖的时序路径"**。
⇒ 所以这 4 条的正确处置是**删除**，而**不是**改成 `create_generated_clock`（后者同样要求对象存在）。

**附带收益**：每条失败连报 3 行（`No valid object` / `No valid pin` / `Unable to run`），再乘 3 遍 timing analysis ⇒ 4 条 = **36 行日志噪音**（占本轮 246 行的 15%）。删掉它们是最便宜的"日志减肥"。

### 9.4 新发现：`jtag_inst1_RESET` / `jtag_inst1_UPDATE` 是被 PnR 移除的空端口

本轮新增的 4 条失败（`:103/104/107/108`）报的是 `set_input_delay: No valid input port(s) found`。工具自己在 `out\mmt.warn.log` 里给了原因（多处重复，例如 `:5061-5062`）：

```
[EFX-0011 VERI-WARNING] Input/inout port jtag_inst1_UPDATE is unconnected. Place and route may remove this unconnected port. (VDB-8003) (rtl\mmt\mmt_top.v:235)
[EFX-0011 VERI-WARNING] Input/inout port jtag_inst1_RESET  is unconnected. Place and route may remove this unconnected port. (VDB-8003) (rtl\mmt\mmt_top.v:236)
```

事实链（都已核对）：
- 这两个端口**在接口模板和 interface.csv 里是有的**：`outflow\mmt_template.v:50,57`、`outflow\mmt.interface.csv:313,321`；
- RTL 也接到了 SoC：`mmt_top.v:235,236`（声明）→ `:1575,1576`（`.jtag_update/.jtag_reset`）→ `mmt_soc_subsystem.v:51,52` → `:399,400`（`.jtagCtrl_update/.jtagCtrl_reset`）；
- 但工具判定为 **unconnected** 并移除 ⇒ `get_ports` 找不到 ⇒ 这 4 条约束**以后也不可能生效**。

**处置：删掉 `:103/104/107/108` 这 4 行**（它们的目标对象不存在）。
若团队确实要约束这两个信号，属于 RTL/接口侧动作（要让它们真的被内部逻辑消费），**不是 SDC 能解决的** —— 已超出本任务写权限，仅记录。
（这也解释了为什么它们从"缺时钟"变成了"缺端口"：**从一种失败换成了另一种失败**，不是新引入的风险。）

### 9.5 "警告 85 → 246" 的口径澄清（避免被误判成回归）

- **246 是"文本行数"，不是"失败约束条数"**：同一批警告被 **3 遍 timing analysis**（placement 后 / 布线后 / 最终）各打印一次。实测：`No valid object(s) found for 'axi_clk'` 出现 **3** 次；`set_input_delay: No valid input port(s) found` 出现 **12** 次（= 4 行 × 3 遍）；日志里 `[SDC]` 警告聚成 3 簇（61–190 / 623–752 / 1362–1491），每簇 **82 行**。246 = 3 × 82 ✓
- **同口径对比**：**不重复的失败行号 85 → 35**（上一轮我报的 85 就是"行号"口径）。
- 每遍的警告行数：本轮 **82**；上一轮约 **96**【推断：旧日志已被覆盖，此数按当时观察到的警告区间估算】。
⇒ 结论：**日志不是变脏，而是换了口径**；真正的问题是 9.2 的顺序 + 9.3/9.4 的死约束。

### 9.6 补丁（**都写在文档里，等 Lead 说可以再改**）

**Patch A —— 顺序修正（必做，改完 9.2 的 6 条派生关系才会消失）**

```tcl
# 把下面两行从当前位置（JTAG 段 :98、MIPI RX 段 :320）**移到第 24 行之前**
# （即放在文件最前面、所有 set_clock_groups 之前；紧挨现有的 create_clock 段 :5-23 末尾最自然）
create_clock -period 12.000   [get_ports {i_cam_ck_CLKOUT}]
create_clock -period 100.0000 [get_ports {jtag_inst1_TCK}]
```

预期效果（供重跑核对）：
1. `[SDC …:26]` 不再出现 `No clocks matched 'i_cam_ck_CLKOUT'` / `'jtag_inst1_TCK'`；
2. `mmt.timing.rpt` 的 Setup/Hold 表里，9.2 表格中那 6 行**全部消失**；
3. 仍然保留（都是域内检查）：`i_cam_ck_CLKOUT → i_cam_ck_CLKOUT  12.000`（+7.068）、`jtag_inst1_TCK → jtag_inst1_TCK 100.000`（+94.881）；
4. `:25` 从"整条作废"变成"部分生效"（`i_mipi_rx_pclk` × JTAG 互斥成立，只剩 `i_soc_clk` 空组告警）；
5. **负 slack 仍应为 0**（被拿掉的最紧一条是 +0.316 的假关系；hold 的 +0.019 在 `core_clk→core_clk`，不受影响）。

**Patch B —— 删掉 4 行指向不存在端口的 JTAG 约束（必做）**

```tcl
# 删除新 :103、:104（jtag_inst1_RESET 的 max/min）与新 :107、:108（jtag_inst1_UPDATE 的 max/min）
# 依据：out\mmt.warn.log 报这两个端口 unconnected 且被 PnR 移除（见 9.4）
```

**Patch C —— 删掉 4 条死 `create_clock`（推荐，纯日志减肥，确认无时序影响）**

```tcl
# 删除 :5(axi_clk) :7(i_soc_clk) :19(fb) :20(pll_inst4_CLKOUT0) —— 依据见 9.3
# 同时可删掉 :26 里的空组 -group {axi_clk}、:25 里的空组 -group {i_soc_clk}
```

**Patch D —— 可选**：删掉 `:120` 的 `create_clock -period <USER_PERIOD> [get_ports {CLK_25M}]`（占位符，且本设计无 FF 用 CLK_25M），以及 `:149-152`（`ddr_addr[14]/[15]`）与 `:361-380`（`mipi_dp_*` 20 行）两块死约束。

> 全部做完后，**每遍 timing analysis 的 `[SDC]` 警告可以从 82 行降到 0 行**（82 − 12[Patch C] − 8[Patch B] − 8[ddr_addr] − 40[mipi_dp] − 2[CLK_25M] − 12[L25/L26 空组+顺序] = 0）。

---

## 附录 A — 关键证据索引

| # | 结论 | 证据 |
|---|---|---|
| 1 | 85 条约束没生效（含逐条原因） | `out\efx_pnr.log:59-...`（`[SDC …:<行>]` 警告，共 85 个行号） |
| 2 | `i_cam_ck_CLKOUT` 是真时钟网络 | `outflow\mmt.interface.csv:29-32`；`outflow\mmt.pinout.csv:66,81` |
| 3 | 它驱动 CSI RX 与探针 | `rtl\mmt\mmt_top.v:564`、`:1479` |
| 4 | 该 IP 570 个 FF | `out\mmt.hier_util.rpt:54`（`inst_efx_csi2_rx` 的 `xlr_ff` 列） |
| 5 | 原 `create_clock` 被注释 | 核对时 `constr\ti60f225_oob.sdc:281`；厂商同款 `Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:256` |
| 6 | 厂商把该时钟单列一组 | `tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:27,29` |
| 7 | 摄像头 I2C 在 CLK_5M 域 | `rtl\mmt\mmt_top.v:668`、`:679` |
| 8 | 真实端口名（无 i_/o_ 前缀） | `rtl\mmt\mmt_top.v:98-105`（d0）、`:110-114`（d1）、`:82-90`（I2C/rst） |
| 9 | 名字错位来源（EVSoC 工程） | `工作区\03_EVSoC源码\evsoc-main\cam_single\Ti60F225_dsi\edge_vision_soc.sdc:272-279` |
| 10 | 厂商手改的 SDC 也有同样错位 | `07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:257-272` |
| 11 | Interface Designer 生成的是正确名字 | `outflow\mmt.pt.sdc:323-330` |
| 12 | `ddr_addr` 只有 14 位 | `rtl\ddr3_controller\ddr3_parameter.vh:7` |
| 13 | `i_soc_clk` 只是 core_clk 的别名线网 | `rtl\mmt\mmt_top.v:72`（端口已注释）、`:549` |
| 14 | JTAG 是真实接口 | `rtl\mmt\mmt_top.v:229-236`、`:1521-1527`；厂商 `edge_vision_soc.sdc:26`（100ns） |
| 15 | DSI TX 已从设计删除 | `rtl\mmt\mmt_top.v:11-13` 注释 + 端口表无 `mipi_dp_*` |
| 16 | 摄像头寄存器表与厂商 OOB 逐字节相同 | `rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v` 与 `07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v` hash 均为 `DA82D962F02D3E585C97BF81EA057A9E0E9766915449960F98EF6C903B695928` |
| 17 | IP 自己配置的字节时钟是 70MHz（⇒14.2857ns） | `ip\csi_rx_controller\settings.json:22-25`（`NUM_DATA_LANE=4`、`HS_BYTECLK_MHZ=70`、`CLOCK_FREQ_MHZ=100`） |
| 18 | 厂商能出图的摄像头 demo 与本工程 IP 配置逐项相同 | `07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\ip\csi_rx_controller\settings.json`（`NUM_DATA_LANE=4`、`HS_BYTECLK_MHZ=70`、`CLOCK_FREQ_MHZ=100`、`PIXEL_FIFO_DEPTH=4096` 全同） |
| 19 | 厂商摄像头 demo **同样没有** 这条 create_clock（却能在板上出图） | `07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.sdc:256`（注释状态） |
| 20 | `i_mipi_rx_pclk` 我们与厂商摄像头 demo 一致 | `mmt.peri.xml:342`（div=56）与 `Ti60f225_sc431hai2hdmi_v1\ti60f225_oob.peri.xml:356`（div=56）；SDC 均 20.0000ns |
| 21 | JTAG 时钟取值 100ns 的出处 | `tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:26` |
| 22 | 13:52 实测：零负 slack（408 条，最小 +0.019） | `out\mmt.timing.rpt`（`Slack` 行 408 条，负值 0 条） |
| 23 | 两个新时钟确实创建成功 | `out\mmt.timing.rpt` 的 "User target constrained clocks"：`jtag_inst1_TCK 100.000`、`i_cam_ck_CLKOUT 12.000` |
| 24 | 顺序问题实证（26 行执行时两时钟还不存在） | `out\efx_pnr.log` 中 `[SDC …:26] No clocks matched 'i_cam_ck_CLKOUT'`、`… 'jtag_inst1_TCK'` |
| 25 | 工具编出的派生关系（2.000 / 4.000 / 10.000） | `out\mmt.timing.rpt` 的 Setup 与 Hold Clock Relationship 表 |
| 26 | `jtag_inst1_RESET`/`_UPDATE` 被判 unconnected 并被移除 | `out\mmt.warn.log:5061-5062`（VDB-8003；另在 :2486-2487、:3003-3004 等多处重复） |
| 27 | 警告按 3 遍 timing analysis 重复（口径） | `No valid object(s) found for 'axi_clk'` 出现 3 次；`set_input_delay: No valid input port(s) found` 出现 12 次；`[SDC]` 警告聚成 3 个 82 行的簇（61–190 / 623–752 / 1362–1491） |
| 28 | `axi_clk` 只是子模块端口标签，物理时钟是 core_clk | `rtl\mmt\mmt_top.v:599,736,946,986`（`.axi_clk/.m_axi_clk (core_clk)`）、`:1204`（`i_mipi_clk = core_clk`，见 `:548`） |
