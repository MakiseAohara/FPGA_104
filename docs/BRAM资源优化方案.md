# BRAM 资源优化方案（222/256 = 86.72% 归因与削减清单）

- 工程：`D:\FPGA\mmt`（Efinity 2026.1.132，Ti60F225I3，顶层 `mmt_top`）
- 分析时间：2026-10-11
- 分析者：bram-optimizer（task-5）
- 数据基线：`out\mmt.map.rpt` / `out\mmt.hier_util.rpt` / `out\mmt.res.csv` / `out\mmt.place.rpt`（均为 2026-10-11 19:2x 那一轮 efx_map+efx_pnr 的产物，efx_map/efx_pnr 均 exit 0）
- **本轮没有跑任何 Efinity 流程**。文中「实测」= 直接读报告得到的数字；「推算」= 用厂商公式/原语模式表算出来的数字，**必须由 Lead 重跑 efx_map 验证**。

---

## 0. 结论摘要（TL;DR）

1. **222 块 = 218 个 EFX_RAM10 + 4 个 EFX_DPRAM10**（`out\mmt.map.rpt:5136-5137`），单块 10,240 bit，器件 256 块 ⇒ BRAM 总量仅 2.56 Mbit（320 KB）。
2. **实测归因（自底向上加总正好 = 222，无残差）**：SoC 71、TinyML 55、DDR3 控制器 39、帧差背景 RAM 20、显示帧缓冲 checker0 15，其余 7 个小项（debayer 行缓冲 / 面板寄存器表 / CSI2 4 lane / OSD / 红外帧缓存 / I2C ROM / DVI 编码器）合计 22。
3. **三条最重要的"反直觉"结论**（都推翻了任务书里的猜测）：
   - **`CACHE_DEPTH` 512→256/128 一块都省不了**（省 0 块）。原因：缓存数据 RAM 是 **128 位宽**，EFX_RAM10 只有 20 bit/块的宽度模式，128 bit 至少要 `ceil(128/20)=7` 块；深度只要 ≤512，深度不增加块数。而且生成器允许的最小值本来就是 512，256/128 根本不是合法选项。
   - **`OUT_CH_FIFO_A` / `FILTER_FIFO_A` / `CNT_DTH` 也都省 0 块**。前两个是生成器**自动**取值、界面不可配（`'visible': False`）；且公式是 `AW = max(ceil(log2(N)), 9)`，任何 ≤512 的取值都得到 AW=9、块数不变。`CNT_DTH` 不出现在任何 BRAM 公式里，**只影响逻辑不影响 RAM**。
   - **唯一"改一个参数省一大块"的 TinyML 开关是 `TINYML_CACHE: ENABLE → DISABLE`，省 22 块**（整个 cache 子树），代价是推理时权重全部走 DDR。
4. **最优先推荐（省最多且功能性风险最小、有实测/公式双重依据）**：
   | # | 改动 | 省 | 类型 |
   |---|---|---|---|
   | 1 | `OCRSize 32768 → 16384`（SoC 片内 RAM 32KB→16KB） | **−16 ～ −19** | 重生成 SoC IP |
   | 2 | `checker0.RD_FIFO_DEPTH 1024 → 512` | **−6** | 纯 RTL |
   | 3 | `TINYML_CACHE ENABLE → DISABLE` | **−22** | 重生成 TinyML IP |
   | 4 | `IN_PARALLEL 8 → 4` | **−4**（+6 DSP） | 重生成 TinyML IP |
   | 5 | `ICacheSize/DCacheSize 4096 → 2048` | **−4（±2）** | 重生成 SoC IP |
5. **「必须再砍 30 块」的推荐组合 = 方案 A：`RD_FIFO_DEPTH 512` (−6) + `OCRSize 16384` (−16) + `ICache/DCache 2048` (−4) + `IN_PARALLEL 4` (−4) = −30**，222 → 192 块（75.0%）。
6. **硬结论：完全不碰 SoC / TinyML IP、只改 RTL，最多只能砍约 20～22 块，砍不出 30 块。** 30 块必然要至少重生成一次 IP（详见 §7）。

---

## 1. 实测基线

| 项 | 数值 | 证据 |
|---|---|---|
| Memory Blocks | **222 / 256 (86.72%)** | `out\mmt.place.rpt:336` |
| EFX_RAM10 | 218 | `out\mmt.map.rpt:5136` |
| EFX_DPRAM10 | 4 | `out\mmt.map.rpt:5137` |
| XLR | 44696 / 60800 (73.51%) | `out\mmt.place.rpt:325` |
| DSP48 / DSP24 | 22 / 5（合计 27） | `out\mmt.map.rpt:5132-5133` |
| SRL8 | 1220 | `out\mmt.map.rpt:5135` |
| FF | 22230 | `out\mmt.map.rpt:5134` |

> ⚠️ **关于报告时效性（重要）**：本次分析期间，Lead 侧正在重新生成 `out\` 下的报告（`mmt.res.csv` 先被其它进程占用、随后被重写为 0 字节）。本文所有**数字**与**行号**均取自 **19:2x 那一轮**成功读到的产物。
> - 如果 Lead 后来重跑过流程且**没有改配置**，数字应当一致，但 `out\mmt.res.csv` / `out\mmt.hier_util.rpt` 的**行号可能位移**，请按关键字（如 `+u_bg_ram`、`+Cache.u_tinyml_cache`、`DC_FIFO`）匹配行，而不是按行号硬找。
> - 如果 Lead **已经应用了本文的任何一项改动**再重跑，那么 §1 的基线（222/256）就会变，需要用新模式重新核对 §3 的归因。

---

## 2. EFX_RAM10 的映射规则（本方案所有推算的基础）

### 2.1 原语只有 8 种形状（厂商原文）

`D:\Efinity\2026.1\ipm\ip\efx_bram\source_exp\bram_decompose.vh:22-29` 给出 EFX_RAM10 的全部模式（`bram_feature_table(index) = (地址位宽, 数据位宽, ...)`）：

| 模式号 | 地址位宽 | 深度 | 数据位宽/块 | 单块容量 |
|---|---|---|---|---|
| 0 | 9 | 512 | **20** | 10240 bit |
| 1 | 9 | 512 | 16 | 8192 bit |
| 2 | 10 | 1024 | 10 | 10240 bit |
| 3 | 10 | 1024 | 8 | 8192 bit |
| 4 | 11 | 2048 | 5 | 10240 bit |
| 5 | 11 | 2048 | 4 | 8192 bit |
| 6 | 12 | 4096 | 2 | 8192 bit |
| 7 | 13 | 8192 | **1** | 8192 bit |

**关键含义**：
- 单块**最大宽度 20 bit**（仅在 512 深时）；
- 想做得更深，宽度就得变窄（1024 深→10 bit，2048 深→5 bit，8192 深→1 bit）；
- ⇒ **一个宽 RAM 的块数由"宽度 / 20"决定，与深度无关（只要深度 ≤512）**。这是 §6 中所有"省 0 块"结论的根据。

### 2.2 厂商自己的块数估算函数

`D:\FPGA\tinyml\tools\tinyml_generator\lib\resource_lib.py:177-186`：

```python
def calc_bram_size(self, ADDR_WIDTH=None, DATA_WIDTH=None):
    addr_width_per_bram  = 9      # 512 深
    data_width_per_bbram = 20     # 20 bit 宽
    bram_size = pow(2, 9) * 20    # = 10240
    if ADDR_WIDTH <= 9 and DATA_WIDTH >= 20:
        bram_count = roundup(DATA_WIDTH / data_width_per_bbram)   # 只按宽度算
    else:
        total_size = pow(2, ADDR_WIDTH) * DATA_WIDTH
        bram_count = roundup(total_size / bram_size)
    return bram_count
```

### 2.3 模型标定：用实测数据反验（13/14 命中）

通用推算式：**块数 = min over 8 种模式 { ceil(W / w_mode) × ceil(D / 2^a_mode) }**，并对深度 >512 的情形取"稠密打包"下界 `ceil(W×D / 10240)`。

| RAM（实测位置） | W | D | 模型给 | **实测** | 命中 |
|---|---|---|---|---|---|
| `Cache.u_tinyml_cache/tinyml_cache_rem_mem_inst` (`res.csv:181`) | 128 | 512 | (9,20): 7×1 = **7** | **7** | ✅ |
| `.../cache_rd_fifo` (`res.csv:209`) | 129 | 512 | 7×1 = **7** | **7** | ✅ |
| `.../output_data_fifo` (`res.csv:316-318`) | 128 | 512 | **7** | **7** | ✅ |
| `.../filter_data_ram` (`res.csv:333`) | 64 | 512 | 4×1 = **4** | **4** | ✅ |
| `.../IDRAM_U[0].input_data_ram` (`res.csv:334`) | 65 | 512 | 4×1 = **4** | **4** | ✅ |
| `output_multiplier_ram` / `output_shift_ram` / `bias_data_ram` (`res.csv:330-332`) | 32 | 512 | 2×1 = **2** ×3 | **2** ×3 | ✅ |
| `.../cache_miss_ext_ar_fifo` (`res.csv:197-199`) | 54 | 8 | 3×1 = **3** | **3** | ✅ |
| `u_ddr3_top/u_phy_top/u_ddr_phy_if/u1_cmd_fifo` (`res.csv:352-354`) | 90 | 16 | 5×1 = **5** | **5** | ✅ |
| `.../u_tinyml_common_s_axi4addr8_to_m_axi4addrx/u2_fifo_145w256d` (`res.csv:235-237`) | 145 | 256 | 8×1 = **8** | **8** | ✅ |
| `.../u5_fifo_131w256d` (`res.csv:291-293`) | 131 | 256 | 7×1 = 7 | **4** | ⚠️ 工具比模型更好 |
| `u_algo/u_frame_diff/u_bg_ram` (`res.csv:660`) | 8 | 19200 | (11,5): 2×10 = **20** | **20** | ✅ |
| `checker0/.../ddr_rd_buffer_inst/u_rd_fifo` (`res.csv:130-131`) | 128 | 1024 | 稠密 ceil(131072/10240) = **13** | **13** | ✅ |
| `checker0/.../u_data_tx/u_rd_fifo` (`res.csv:140`) | 16 | 1024 | (9,20): 1×2 = **2** | **2** | ✅ |
| `u_soc/.../system_ramA_logic/ram_symbol0..3` (`mmt.map.rpt:5076-5114`) | 8 | 8192 | (13,1): 8×1 = **8** ×4 | **8** ×4 = **32** | ✅ |

> 唯一例外是 `u5_fifo_131w256d`（工具用 4 块，比模式表算出的 7 块更好，说明 mapper 还能做更优的混排）。本方案对每一条推算都给**区间**，并在涉及该 FIFO 的地方不依赖它。
>
> 结论：**该模型可以直接用来做"省几块"的定量推算**，误差 ±1～2 块（另有稠密打包下界更乐观）。

---

## 3. 222 块 BRAM 逐项归因

### 3.1 按子系统（实测，自底向上加总 = 222）

| 子系统 | 块数 | 性质 | 是否可配 |
|---|---|---|---|
| `u_soc`（Sapphire SoC） | **71** | 片内 RAM + iCache/dCache + DDR AXI 队列 + 外设 FIFO | 部分可配（见 §4） |
| `u_tinyml_accel`（TinyML 加速器） | **55** | cache 22 + 卷积流水 14 + AXI 位宽转换 12 + DMA 7 | 部分可配（见 §5） |
| `u_ddr3_top`（DDR3 控制器） | **39** | PHY FIFO 22 + lb2_axi FIFO 17 | 厂商 IP 固定 |
| `u_algo`（帧差法背景帧） | **20** | 1 个 19200×8 背景 RAM | **本工程 RTL，可配** |
| `checker0`（`frame_buffer` 显示通路） | **15** | 读 FIFO 13 + data_tx 2 | **本工程 RTL，可配** |
| `debayer_top` 行缓冲 | 4 | true_dual_port_ram 16b×2048 | 本工程 RTL |
| `inst_panel_config/inst_piv2_reg` | 4 | DPRAM10，40b×512，带 `Panel_1080p_reg.mem` 初始化 | 半固定 |
| CSI2 RX lane aligner | 4 | 4 lane × 1 块 | 厂商 IP 固定 |
| `u_osd`（字模 ROM + 热力图 + 文本） | 4 | 2 + 1 + 1 | 本工程 RTL |
| `u_sensors/u_ir_frame_ram` | 2 | mmt_dpram | 本工程 RTL |
| `u2_i2c_master_ctrl_top/u_user_rom` | 2 | i2c 寄存器表 ROM（161 深） | 固定 |
| `dvi_encoder_m0` | 2 | simple_dual_port_ram | 厂商 IP 固定 |
| **合计** | **222** | | |

> **勘误**：任务书里写的"`frame_buffer`：20（`u_algo` 分支）"不准确。实测 `u_algo` 的 20 块是**帧差法背景帧 RAM**（`u_bg_ram`），`frame_buffer` 实例在顶层叫 **`checker0`**（`rtl\mmt\mmt_top.v:658-672`），占 15 块。

### 3.2 `u_soc` = 71 块明细

| 叶子 | 块 | 证据 | 为什么需要 | 可配性 |
|---|---|---|---|---|
| `system_ramA_logic`（OCR） | **32** | `hier_util:445`；`map.rpt:5076-5114` | `OCRSize=32768`(32KB) → 4 个 symbol，每个 8192B×8bit → 模式 (13,1) 8 块 | **`settings.json:80`，可配** |
| `system_ddr_ddrLogic_cc_fifo/io_input_cmd_queue` | 10 | `hier_util:414` | SpinalHDL `StreamFifoCC`，DDR 命令队列（宽随 `DDRWidth=128`/`DDR_IdWidth=8`） | 厂商 IP 固定 |
| `.../io_output_rsp_queue` | 7 | `hier_util:418` | DDR 响应队列 | 厂商 IP 固定 |
| `system_cores_0_logic_cpu/dataCache_1` | 6 | `hier_util:401`；`res.csv:569` | VexRiscv 数据 cache，`DCacheSize=4096` | **`settings.json:71`，可配** |
| `system_cores_0_logic_cpu/IBusCachedPlugin_cache` | 6 | `hier_util:403`；`res.csv:568` | VexRiscv 指令 cache，`ICacheSize=4096` | **`settings.json:70`，可配** |
| `system_cores_0_logic_cpu`（自身） | 4 | `hier_util:400`；`res.csv:567` | VexRiscv 生成逻辑内部 RAM（`VexRiscv_566a7baf...`） | 厂商生成，不建议动 |
| `system_ddr_ddrLogic_bmbToAxiBridge` read/writeCmdInfo_fifo | 1+1 | `hier_util`（`u_soc` 叶子） | BMB→AXI 桥命令信息 | 固定 |
| `system_uart_0_io_logic` 2 个队列 | 1+1 | 同上 | UART 收发队列 | 固定 |
| `system_spi_0_io_logic` 2 个队列 | 1+1 | 同上 | SPI 收发队列 | 固定 |
| **小计** | **71** | | | |

> 说明：`u_soc` 的 71 块里只有 **OCR 32 + iCache 6 + dCache 6 = 44 块**是真正可以动的，且**全部要重新生成 SoC IP**。

### 3.3 `u_tinyml_accel` = 55 块明细

| 叶子 | 块 | 证据 | 为什么需要 |
|---|---|---|---|
| `Cache.u_tinyml_cache`（合计） | **22** | `hier_util:485,517` | `TINYML_CACHE=ENABLE`，`CACHE_DEPTH=512` |
| ├ `tinyml_cache_core_inst/tinyml_cache_core_ram_inst/tinyml_cache_rem_mem_inst` | 7 | `hier_util:517`；`res.csv:181` | 缓存数据 RAM，`common_simple_dual_port_ram(DATA_WIDTH=128)`，512 行 × 128 bit |
| ├ `checker_inst/u_tinyml_cache_checker_read_cache_mem/cache_rd_fifo` | 7 | `hier_util:497`；`res.csv:209` | 回读 FIFO，`DATA_WIDTH=129`（与 `resource_lib.py:148` 的 `AXI_DW+1` 一致） |
| ├ `checker_check_hit_miss/cache_miss_ext_ar_fifo` | 3 | `hier_util:492`；`res.csv:197-199` | 缺失请求 FIFO `DEPTH=8, DATA_WIDTH=54` |
| ├ `tinyml_cache_core_inst/u_axi_interconnect/.../u1_rd_queue_fifo` | 1 | `res.csv` cache 子树 | 内部互联读队列 |
| ├ `load_control_fifo` | 1 | `res.csv:192-194` | `DEPTH=8, DATA_WIDTH=18` |
| ├ `cache_line_update_fifo` | 1 | `res.csv:201-203` | `DEPTH=16, DATA_WIDTH=3` |
| ├ `cache_rd_req_fifo` | 1 | `res.csv:211-213` | `DEPTH=8, DATA_WIDTH=17` |
| └ `checker_readback_fifo` | 1 | `res.csv:220-222` | `DEPTH=32, DATA_WIDTH=1` |
| `Cache.u_tinyml_common_s_axi4addr8_to_m_axi4addrx` | **12** | `hier_util:559,615`；`res.csv:235,291` | AXI 地址位宽转换（`common_module_2`）：`u2_fifo_145w256d`(145b×256) 8 块 + `u5_fifo_131w256d`(131b×256) 4 块；深度 256 在 `resource_lib.py:168-169` 里是**硬编码** `FIFO2_A=256` |
| `u_tinyml_common_dma_if/output_data_fifo` | 7 | `hier_util:664`；`res.csv:316-318` | DMA 输出 FIFO 128b×512（`common_module_1`，`resource_lib.py:161`） |
| `Convolution.../mac_operator/filter_data_ram` | 4 | `hier_util:649`；`res.csv:333` | `DATA_WIDTH = IN_PARALLEL×8 = 64` |
| `Convolution.../mac_operator/IDRAM_U[0].input_data_ram` | 4 | `hier_util:650`；`res.csv:334` | `DATA_WIDTH = IN_PARALLEL×8+1 = 65` |
| `output_multiplier_ram` / `output_shift_ram` / `bias_data_ram` | 2+2+2 | `hier_util:658,659,648`；`res.csv:330-332` | 各 `DATA_WIDTH=32`，深度 `2^OUTPUT_CH_AW = 512` |
| **小计** | **22+12+7+4+4+6 = 55** | | |

> `resource_lib.py:117-137` 的厂商公式给出的卷积部分 = `om 2 + os 2 + b 2 + filter 4 + input 4 = 14`，**与实测 14 完全一致**。

### 3.4 `u_ddr3_top` = 39 块明细

| 叶子 | 块 | 证据 |
|---|---|---|
| `u_phy_top/u_ddr_phy_if` | 22 | `hier_util:293`（`u1_cmd_fifo` 5 + `u3_dout_fifo` 8 + `u4_din_fifo` 7 + `u2_ctl_fifo` 2） |
| `lb2_axi_clk.u_lb2_axi_clk` | 17 | `hier_util:166`（`u2_din_fifo` 8 + `u3_dout_fifo` 7 + `u1_cmd_fifo` 2） |
| **小计** | **39** | 全部由厂商 DDR3 控制器 IP 生成（`DQ_WIDTH=16`、`USER_DW=128`），**不建议动** |

### 3.5 `checker0` = 15 块 + 一个需要 Lead 复核的异常

| 叶子 | 块 | 证据 |
|---|---|---|
| `checker0/u_ddr_buffer/ddr_rd_buffer_inst/u_rd_fifo` | **13** | `hier_util:18`；`res.csv:130-131`（`DC_FIFO(FIFO_DEPTH=1024)`，`DATA_WIDTH` 由 `rtl\frame_buffer\ddr_rd_buffer.v:324` 传入 `AXI_DATA_WIDTH=128`） |
| `checker0/u_data_tx/u_rd_fifo` | 2 | `res.csv:140`（`DC_FIFO(DATA_WIDTH=16,FIFO_DEPTH=1024)`） |
| `checker0/u_ddr_buffer/ddr_wr_buffer_inst/u_wr_fifo` | **0** | `res.csv:129`（`ddr_wr_buffer_inst` RAMs = 0） |

> ⚠️ **异常，请 Lead 复核（不是 BRAM 问题，但会影响本方案第 1 优先项的信心）**：
> `out\mmt.map.rpt:1635-1660` 的 Memory Trimming Report 显示
> `checker0/u_ddr_buffer/ddr_wr_buffer_inst/u_wr_fifo/FifoBuff__D$*` 的 **读地址端口被 tie off、读数据被 disconnect（"because it is disabled"）**，共 13 个 slice。
> 也就是说：**128 bit × 1024 深的写 FIFO 一块 BRAM 都没占**（这正是 checker0 只有 15 块而不是 28 块的原因）。
> 两种可能，无法在本任务范围内定论（标"无法确认"）：
> (a) 写 FIFO 的读侧确实是死逻辑 ⇒ **帧缓冲写通路可能不工作**（功能风险，且与 task-1/task-6 的验证相关）；已知 `wr_fifo_wren` 的驱动链是活的（`rtl\frame_buffer\frame_buffer.v:163` → `:203` → `rtl\frame_buffer\ddr_buffer.v:136` → `ddr_wr_buffer.v:106`），且 `ddr_wr_buffer.v:482` 的 `wr_fifo_rden` 也不是常量，**所以 (a) 看起来不像**；
> (b) mapper 把该 FIFO 用 SRL/寄存器实现（本设计 `EFX_SRL8=1220` 块，`map.rpt:5135`），读端口因此没有 BRAM 端口可言。
> **建议**：Lead 在最终验证时确认 checker0 的 DDR 写通路功能正常；如果确认 (b)，则 §4 的 R1 结论（读 FIFO 13 块）不受影响。

### 3.6 其余小项（实测）

| 叶子 | 块 | 证据 | 说明 |
|---|---|---|---|
| `debayer_top/inst_line_buffer_debayer/inst_y_buffer` | 4 | `hier_util:35`；`res.csv` `true_dual_port_ram(DATA_WIDTH=16,ADDR_WIDTH=11)` | 16b×2048，行缓冲 |
| `inst_panel_config/inst_piv2_reg` | 4 | `hier_util:151`；`res.csv` `true_dual_port_ram(DATA_WIDTH=40, ... RAM_INIT_FILE="Panel_1080p_reg.mem")` | DPRAM10（就是那 4 个 DPRAM10），面板初始化表 |
| CSI2 lane aligner | 4 | `res.csv` `genblk1[0..3].u1_inst` 各 1 块 | 4 lane 各 1 块 1bit FIFO |
| `u_osd`（`font_rom`） | 2 | `hier_util:373`（`+u_osd` mem=2）；`out\mmt.map.rpt:5116-5118`（`u_osd/font_rom__D$1/2` 各 1 块）；`rtl\mmt\osd\mmt_osd_overlay.v:98`（`reg [7:0] font_rom [0:1519]`，`$readmemh("font8x16.hex")`） | 95 字符 8×16 字模 |
| `u_osd_th_ram` | 1 | `hier_util:374`；`res.csv` `mmt_dpram_2clk(AW=10,DEPTH=768)` | 热力图 32×24 |
| `u_osd_txt_ram` | 1 | `hier_util:375`；`res.csv` `mmt_dpram_2clk(DEPTH=256)` | 文本 3×48 |
| `u_sensors/u_ir_frame_ram` | 2 | `hier_util:379`；`res.csv` `mmt_dpram` | MLX90640 原始帧 |
| `u2_i2c_master_ctrl_top/u_reg_set/u_user_rom` | 2 | `hier_util:160`；`res.csv` `i2c_master_reg_rom(TOTAL_ROM_DEPTH=161)` | I2C 寄存器表 |
| `dvi_encoder_m0` | 2 | `hier_util`；`res.csv` `simple_dual_port_ram` | TMDS 编码器 |
| **小计** | **22** | | |

---

## 4. 削减清单（按性价比排序）

排序原则：**省块数 ÷ 风险**，同时优先"纯 RTL / 配置类"。

### R1（强烈推荐，纯 RTL）`checker0.RD_FIFO_DEPTH` 1024 → 512 ⇒ **省 6 块**

- **改哪里**：`rtl\mmt\mmt_top.v:665` → `.RD_FIFO_DEPTH ( 512 )`
- **证据链**：实测 13 块（`res.csv:130-131`，`DC_FIFO(FIFO_DEPTH=1024)`，`DATA_WIDTH=128`；`res.csv:131` 与 `hier_util:18` 一致）
- **推算过程（推算）**：128 bit × 512 深 ⇒ 模式 (9,20) 下 `ceil(128/20)=7` 块（深度 512 正好占满一块深度），稠密下界 `ceil(65536/10240)=7`。两边都指向 **7 块** ⇒ 1024→512 **省 6 块**。
- **附带结论**：继续降到 256 **不再省**（256 ≤ 512，仍受 7 块宽度下界约束）。**512 是甜点，别降到 256**。
- **功能/性能影响**：DDR 读预取缓冲 16 KB → 8 KB。`BURST_LEN=127` ⇒ 每 burst 127×16B = 2032 B，8 KB ≈ 4 个 burst 余量；`rtl\frame_buffer\ddr_rd_buffer.v:269` 的触发线 `RD_FIFO_DEPTH < rd_fifo_wrusedw + BURST_LEN + 5` 会自动跟随常量。**风险中等**：1920×1080 像素流的 DDR 读带宽余量需上板复核。
- **验证方法**：① `efx_map` 后看 `out\mmt.map.rpt` Resource Summary `EFX_RAM10` 应从 218 → ~212；② 上板看 HDMI 画面有无撕裂/闪烁；③ `out\mmt.place.rpt:336` 应从 222 → 216。
- **不要动**：`rtl\mmt\mmt_top.v:664` 的 `WR_FIFO_DEPTH` —— 实测写 FIFO 占 **0 块**（§3.5），改它不省块。

### R2（推荐，需重生成 SoC IP）`OCRSize` 32768 → 16384 ⇒ **省 16 ～ 19 块**

- **改哪里**：`ip\sapphire_soc\settings.json:80` → `"OCRSize": "16384"`
- **证据链**：实测 32 块（`hier_util:445`），`map.rpt:5076-5114` 显示是 `ram_symbol0..3` 各 8 块，每块模式 (13,1)。
- **推算过程（推算）**：每个 symbol 是 8 bit 宽 × 8192 字节深。32 KB→16 KB 后每 symbol 4096×8：模式 (12,2) 给 `ceil(8/2)=4 × ceil(4096/4096)=1 = 4` 块/symbol ⇒ 4×4 = **16 块**；稠密下界 `ceil(131072/10240)=13` ⇒ 区间 **13 ～ 16**。保守取 **−16**。
- **功能/性能影响**：RISC-V 片内 RAM 32 KB → 16 KB。当前固件仅用 **3089 B**（`sw\link.ld` 重编结果，见 task-3 报告），余量充足。**但必须与 bootloader 变体 / LDSize 一起复核**：`soc_config` 里 `--ramHex "...\bootloader\bootloader_124K.hex"` 与 `LDSize=16380` 的匹配关系由 `docs\DDR固件与模型放置方案.md`（task-3）负责，改 OCRSize 后如果 bootloader 需要落进片内 RAM，要重新确认变体。
- **验证方法**：① 重新生成 IP → `efx_map`，`EFX_RAM10` 应 218 → ~202；② `sw` 重编，确认 `RAM` 段未溢出且 `ld` 脚本的 RAM 长度改为 16384；③ 按 task-3 的方法做装载 round-trip 校验。
- **这是本方案性价比最高的一条**（省 16～19 块，只损失本来就富余的片内 RAM）。

### R3（推荐，需重生成 TinyML IP）`TINYML_CACHE` ENABLE → DISABLE ⇒ **省 22 块**

- **改哪里**：`ip\tinyml\tinyml_core0_define.v:17` → `` `define TML_C0_TINYML_CACHE "DISABLE" ``（**必须重新生成 IP**，见 §7）
- **证据链**：实测 cache 子树 22 块（`hier_util:485`，`Cache.u_tinyml_cache` mem=22）；生成器资源模型对 DISABLE 返回全 0 —— `resource_lib.py:31-32`（`'TINYML_CACHE': {"LITE": "[0,0,0,0,0]"}`），且 `tinyml_generator.py:164-179` 明确 `combo: ["ENABLE","DISABLE"]`、默认值就是 `"DISABLE"`。
- **推算过程（实测+厂商模型）**：`CALC = 22 − 0 = −22`。这是唯一一条"一步省 20 块以上"的开关。
- **功能/性能影响**：**大**。权重/激活不再片上缓存，每次访问都走 DDR ⇒ ① 推理明显变慢；② 与 frame_buffer 抢 DDR 带宽（1920×1080 像素流 + TinyML 同时跑）。只有在"推理帧率不敏感、但功能必须装得下"时才用。
- **验证方法**：① `efx_map` 后 `EFX_RAM10` 218 → ~196；② 实测推理一帧耗时（与 ENABLE 版本对比）；③ 上板确认画面与推理结果都不受影响。

### R4（推荐，需重生成 TinyML IP）`IN_PARALLEL` 8 → 4 ⇒ **省 4 块 且省 6 个 DSP**

- **改哪里**：`ip\tinyml\tinyml_core0_define.v:3` → `8` 改 `4`
- **证据链**：`filter_data_ram` 4 块（`hier_util:649`，`DATA_WIDTH=IN_PARALLEL×8=64`）、`input_data_ram` 4 块（`hier_util:650`，`DATA_WIDTH=65`）；DSP：`res.csv:335` `MAC_U[0]...` 12 个 DSP48（`map.rpt:5015-5038`）。
- **推算过程（厂商公式）**：`resource_lib.py:132-133`
  - `filter_ram = calc_bram_size(FILTER_AW=9, INPUT_CNT×8)`：8→`ceil(64/20)=4`（实测 4 ✅），4→`ceil(32/20)=2` ⇒ **−2**
  - `input_ram  = calc_bram_size(FILTER_AW=9, INPUT_CNT×8+1)`：8→`ceil(65/20)=4`（实测 4 ✅），4→`ceil(33/20)=2` ⇒ **−2**
  - 合计 **−4 块**；DSP 12 → 6（每级 8 乘 + 4 量化 ⇒ 4+2）⇒ 全器件 27 → 21。
- **功能/性能影响**：深度卷积吞吐**减半**。mobilenetv1 person-detect 以 depthwise 卷积为主 ⇒ 推理帧率约减半。**这是本条唯一的代价，但它是官方 hello world 的既有配置**（`IN_PARALLEL=4`），说明功能上完全可用。
- **验证方法**：① `efx_map`；② `out\mmt.res.csv` 中 `filter_data_ram`/`input_data_ram` 的 RAM 列应从 `4(4)` → `2(2)`；③ DSP 27 → 21；④ 实测算子耗时。

### R5（推荐，需重生成 SoC IP）`ICacheSize`/`DCacheSize` 4096 → 2048 ⇒ **省 4 块（推算，区间 2 ～ 6）**

- **改哪里**：`ip\sapphire_soc\settings.json:70` 与 `:71` → `"2048"`
- **证据链**：`dataCache_1` 6 块（`hier_util:401`，`res.csv:569`）、`IBusCachedPlugin_cache` 6 块（`hier_util:403`，`res.csv:568`），合计 12 块。
- **推算过程（推算，标注不确定）**：4 KB = 1024 word × 32 bit；按模式 (9,20)，32 bit 数据 + tag 需要 2 条 20-bit 通道 × `ceil(1024/512)=2` 层 = 4 块，加 tag/状态 RAM 实测为 6 块。减半到 2 KB（512 word）后深度层数 2→1 ⇒ 每 cache 约 −2 块 ⇒ 合计 **−4 块**。因为 VexRiscv 的 cache 内部结构（行大小、tag RAM 形状）在报告中不可见，**这里是估算，区间 2～6 块，必须以重跑为准**。
- **功能/性能影响**：RISC-V 命中率下降、固件变慢。固件很小（3089 B），风险低。
- **验证方法**：① 重新生成 → `efx_map`，看 12 → 8 左右；② `sw` 重编并跑通。

### R6（备选，纯 RTL，但风险高）`u_algo` 背景帧 RAM 降规格 ⇒ **省 10 ～ 14 块**

- **现状**：`rtl\mmt\mmt_top.v:1665-1666` `.IMG_W(160) .IMG_H(120)` → `rtl\mmt\algo\mmt_frame_diff.v:105-112` `mmt_dpram #(.DW(8), .AW(15), .DEPTH(19200))` ⇒ 实测 20 块（`hier_util:163`，`res.csv:660`）。
- **推算（模型精确命中）**：8 bit × 19200 深，模式 (11,5) ⇒ `ceil(8/5)=2 × ceil(19200/2048)=10 = 20`，与实测 20 **完全一致**。
- **两个可选做法**：
  - (a) 分辨率 160×120 → 80×60（PIX_NUM 19200 → 4800）⇒ `2 × ceil(4800/2048)=2×3=6` ⇒ **省 14 块**。
  - (b) 只把背景位深 `DW` 8 → 4 ⇒ `ceil(4/5)=1 × 10 = 10` ⇒ **省 10 块**。
- **代价（都高）**：帧差法灵敏度直接下降，`diff_min_area` / `diff_threshold` 需要重新标定，**影响赛题任务 2「运动分析」的准确率**。(a) 还必须同步改 `u_downscale`（`rtl\mmt\mmt_top.v:1307`）的输出分辨率，否则 `PIX_NUM` 与像素流不匹配。
- **验证方法**：先用 `sim` 或 Python 原型（`rtl\mmt\algo\mmt_frame_diff.v:5` 注释提到的 `工作区\02_传感器与算法原型\frame_diff.py`）对比新旧参数下的检测结果，再 `efx_map` 看块数。
- **建议**：仅在真的需要 30 块又不想动 IP 时才用。

### R7（低价值，不建议）其它

| 项 | 块 | 为什么不建议 |
|---|---|---|
| `u_osd/font_rom` 2 块（`mmt_osd_overlay.v:98`） | 2 | 缩字模要放弃字符，收益 1～2 块 |
| `debayer y_buffer` 4 块（`ADDR_WIDTH=11` → 10） | 推算 2 | 行缓冲深度与行宽绑定，风险大、收益小 |
| `inst_piv2_reg` 4 块（DPRAM10） | 4 | 由 `Panel_1080p_reg.mem` 决定，改不了 |
| `u_ir_frame_ram` 2 块 | 2 | MLX90640 整帧缓存，删了就丢功能 |
| CSI2 / dvi_encoder / i2c ROM | 8 | 厂商 IP 固定 |
| DDR3 PHY + lb2_axi FIFO 39 块 | 39 | 厂商 IP 固定；只有换 `DDRWidth`/DQ 位宽才变，牵动硬件 |

---

## 5. 重要「负面结论」：这些改了**不省块**

任务书里点名要评估的几个参数，结论是**不要浪费时间**：

### N1. `CACHE_DEPTH` 512 → 256 / 128 ⇒ **省 0 块**

两个独立理由，任一条都足以否掉：

1. **不是合法取值**。`D:\FPGA\tinyml\tools\tinyml_generator\tinyml_generator.py:171-177`：
   ```python
   "CACHE_DEPTH": { 'val': "512",
                    'combo': ["512", "1024", "2048", "4096", "8192", "16384"], ... }
   ```
   **允许的最小值就是 512**。256/128 只能靠手改 macro 硬来。
2. **即使硬改也省不了**。`resource_lib.py:153`：`cache_ram = calc_bram_size(CACHE_AW, AXI_DW=128)`；按 `:181` 的分支，`ADDR_WIDTH ≤ 9 且 DATA_WIDTH ≥ 20` 时**只按宽度算**：`ceil(128/20) = 7`。
   - `CACHE_DEPTH=512` → `CACHE_AW=9` → **7 块**（实测 7 ✅，`res.csv:181`）
   - `CACHE_DEPTH=256` → `CACHE_AW=8` → 仍是 **7 块**
   - `CACHE_DEPTH=128` → `CACHE_AW=7` → 仍是 **7 块**
   物理原因就是 §2.1：128 bit 宽必须占满 7 条 20-bit 通道，而 512 深正好是一块 RAM 的满深度，**减深度不减块**。只有往**大**做才变：1024 → `(10,10)` 模式不行 ⇒ 需要 2 层 ⇒ **13～14 块**。
3. 唯一收益是把 `resource_lib.py:155` 里的 LUT/FF 估算（`9*CACHE_AW` LUT、`CACHE_AW*22` FF）略微减小，且**代价是命中率下降**。**净收益为负，不建议动。**

### N2. `OUT_CH_FIFO_A` / `FILTER_FIFO_A` / `CNT_DTH` ⇒ **省 0 块**

1. **这三个参数不是用户可配的**。`tinyml_generator.py:77-97` 里三者都是 `'visible': False`，由生成器自动取值（当前 256 / 288 / 256，官方默认 512 / 512 / 256）。它们是被模型自动调优过的结果。
2. **即使改也不省**。`resource_lib.py:123-124`：
   ```python
   OUTPUT_CH_AW = roundup(log(OUTPUT_CH_FIFO_A,2)) if (roundup(log(OUTPUT_CH_FIFO_A,2)) > 9) else 9
   FILTER_AW    = roundup(log(FILTER_FIFO_A,2))    if (roundup(log(FILTER_FIFO_A,2))    > 9) else 9
   ```
   任何 **≤512** 的取值都得到 `AW = 9` ⇒ 相关 RAM（`om_ram`/`os_ram`/`b_ram` = `calc_bram_size(9,32)=2`；`filter_ram = calc_bram_size(9, 64)=4`；`input_ram = calc_bram_size(9,65)=4`）**块数完全不变**。当前 256/288 早就落在 9 这一档。
3. **`CNT_DTH` 与 BRAM 无关**。`grep CNT_DTH resource_lib.py` → **零命中**：它不出现在任何 BRAM 公式里。它只对应 `CNT_WTH=9`（见 `res.csv:322-328` 的模块参数），影响的是计数器位宽和比较逻辑（XLR/DSP），**只影响逻辑，不影响 RAM**。

### N3. 厂商 IP 固定开销（71−44=27 块 SoC + 39 块 DDR3 + 8 块其它）

`u_soc` 的 DDR 队列 17 块、VexRiscv 自身 4 块、bmbToAxi/UART/SPI 队列 6 块；`u_ddr3_top` 全部 39 块；CSI2 4 块、dvi_encoder 2 块、i2c ROM 2 块。
这些由 `DDRWidth=128`、`DDR_IdWidth=8`、`DQ_WIDTH=16`、`USER_DW=128` 等架构参数决定，**改一个就会牵动硬件或功能，不建议为了 BRAM 去动**。
（"把 `DDR_IdWidth` 8→4 能否让 `io_input_cmd_queue` 从 10 块降下来" —— **无法确认**，需要实验；即使有效也只影响 1～3 块。）

---

## 6. 「必须再砍 30 块」的推荐组合

### 方案 A（推荐：平衡，功能全保留）—— **恰好 −30 块，222 → 192（75.0%）**

| 步骤 | 改动 | 省 | 需要重生成 IP？ |
|---|---|---|---|
| A1 | `rtl\mmt\mmt_top.v:665` `RD_FIFO_DEPTH 1024`→`512` | −6 | 否（纯 RTL） |
| A2 | `ip\sapphire_soc\settings.json:80` `OCRSize 32768`→`16384` | −16 | **是**（SoC） |
| A3 | `ip\sapphire_soc\settings.json:70,71` `ICacheSize`/`DCacheSize 4096`→`2048` | −4 | **是**（SoC） |
| A4 | `ip\tinyml\tinyml_core0_define.v:3` `IN_PARALLEL 8`→`4` | −4 | **是**（TinyML） |
| | **合计** | **−30** | |

**总代价**：① DDR 读预取缓冲 16 KB→8 KB（带宽余量变薄，需上板确认画面稳定）；② RISC-V 片内 RAM 32 KB→16 KB（固件只用 3089 B，够）；③ RISC-V iCache/dCache 各 4 KB→2 KB（固件变慢但对功能无影响）；④ 深度卷积吞吐减半 ⇒ TinyML 推理帧率约减半。
**收益**：BRAM 从 86.72% 降到 75.0%，留出 64 块余量（≈640 KBit）给后续功能；额外白送 6 个 DSP（27→21）。
**验证**：一次 `efx_map` 就能看全部数字（`out\mmt.map.rpt` Resource Summary + `out\mmt.res.csv` 的 RAM 列），再走一次完整流程确认时序仍全正（R1 改了时序路径、R2/R3/R5 改了 IP）。

### 方案 B（保推理速度，牺牲 DDR 带宽与推理缓存）
`TINYML_CACHE ENABLE→DISABLE`（−22） + `RD_FIFO_DEPTH 512`（−6） + `ICache/DCache 2048`（−4） = **−32 块**。
**代价**：权重全走 DDR，推理慢且与像素流抢带宽。**只有"必须装得下"时才选**。

### 方案 C（纯 RTL，完全不碰 IP）—— **最多约 −22 块，砍不到 30**
`RD_FIFO_DEPTH 512`（−6） + `IMG_W/IMG_H 80×60`（−14） + `OSD 精简`（−2） = **约 −22**；
如果只用「背景位深 8→4」替代分辨率减半，则是 −6 −10 −2 = **−18**。
⇒ **硬结论：不重生成任何 IP，砍不出 30 块。**

### 方案选择建议
- 如果**推理帧率是硬指标** → 选方案 B（牺牲推理速度不可接受时反过来，只能在 A 和 B 里权衡）；
- 如果**任务 2 的运动检测精度是硬指标** → 不要用 R6（不要碰背景帧分辨率/位深）；
- 一般情况 → **方案 A**，因为它保留全部功能，只是把三个"富余的余量"（DDR 预取深度、片内 RAM、RISC-V cache）和一项"官方 demo 就在用的并行度"降下来。

---

## 7. 改动分类：哪些要重新生成 IP / 重跑流程（Lead 侧动作）

### 7.1 纯 RTL（改完直接 `efx_map` + `efx_pnr` 即可）
| 改动 | 文件:行 |
|---|---|
| `RD_FIFO_DEPTH 1024→512` | `rtl\mmt\mmt_top.v:665` |
| （若选）`IMG_W/IMG_H 160×120→80×60`，需同步 `u_downscale` | `rtl\mmt\mmt_top.v:1665-1666`、`:1307` |
| （若选）背景位深 `DW 8→4` | `rtl\mmt\algo\mmt_frame_diff.v:106` |
| **不要动** `WR_FIFO_DEPTH` | `rtl\mmt\mmt_top.v:664`（实测 0 块） |

### 7.2 需要重新生成 IP（务必重跑完整流程 + 重编固件）
| 改动 | 配置文件:行 | 生成后必须验证 |
|---|---|---|
| `OCRSize 32768→16384` | `ip\sapphire_soc\settings.json:80` | `sw` 重编、`link.ld` 的 RAM 长度、bootloader 变体与 `LDSize` 的匹配（见 `docs\DDR固件与模型放置方案.md`）、装载 round-trip |
| `ICacheSize`/`DCacheSize 4096→2048` | `ip\sapphire_soc\settings.json:70-71` | `sw` 重编跑通；iCache/dCache 是否仍启用 |
| `TINYML_CACHE ENABLE→DISABLE` | `ip\tinyml\tinyml_core0_define.v:17` | 推理功能与耗时；DDR 带宽余量 |
| `IN_PARALLEL 8→4` | `ip\tinyml\tinyml_core0_define.v:3` | 推理结果正确性 + 耗时；DSP 27→21 |

**一个省事的可能性（需要 Lead 实验确认）**：`ip\tinyml\tinyml_accelerator.v` 是从 `ip\tinyml\tinyml_core0_define.v` 用 `` `include `` 取参数的（`tinyml_accelerator.v:23,172,17808`），而且 `out\mmt.res.csv` 显示 `CONV_DEPTHW_STD_IN_PARALLEL` 类参数是以**模块 parameter 形式**传进 RTL 的（例如 `res.csv:320-321` 的 `tinyml_conv_depthw_standard(OUTPUT_CNT=...,OUTPUT_CH_FIFO_A=32'sb0100000000,FILTER_FIFO_A=32'sb0100100000)`，`res.csv:181` 的 `common_simple_dual_port_ram(DATA_WIDTH=128)`）。
⇒ **理论上只改 `tinyml_core0_define.v` 里的宏、不跑官方 generator，也可能生效**。
**建议做法**：Lead 先只改这一个头文件、跑一次 `efx_map`，然后检查 `out\mmt.res.csv` 里对应节点的 RAM 列有没有变（`filter_data_ram` 4→2 等）。**变了**就说明宏足够、省一次重生成；**没变**就必须用官方 generator（`D:\FPGA\tinyml\tools\tinyml_generator\tinyml_generator.py`）重新生成整个 IP。

### 7.3 三类改动的顺序建议
1. 先做**纯 RTL 的 R1**（−6 块）并跑一次流程 —— 零 IP 风险，立刻拿到 6 块余量，验证方法最简单；
2. 再做 **R2 + R5（SoC IP 一次重生成搞定，−20 块）**；
3. 最后按需做 **R3 或 R4（TinyML IP）**。
这样每次只引入一类变量，出问题好定位。

---

## 8. 验证方法汇总（Lead 重跑后看什么）

每次 `efx_map` 后按顺序看 4 个数字：

1. `out\mmt.map.rpt` 的 `### Resource Summary ###`：
   - `EFX_RAM10` + `EFX_DPRAM10` = 总块数（当前 **218 + 4 = 222**，`map.rpt:5136-5137`）
2. `out\mmt.place.rpt:336`：`Memory Blocks: N / 256 (P%)`（当前 222/256 = 86.72%）
3. `out\mmt.res.csv` 对应节点的 **RAM 列**（第 6 列），用于**逐项**确认是哪一块在变：
   - `bbox_ram` → `+u_bg_ram`（`res.csv:660`）
   - 读 FIFO → `+u_rd_fifo:DC_FIFO(...)`（`res.csv:130`）
   - OCR → `system_ramA_logic/ram_symbol0..3`
   - iCache/dCache → `+dataCache_1` / `+IBusCachedPlugin_cache`（`res.csv:569,568`）
   - TinyML cache → `+Cache.u_tinyml_cache`（`res.csv:161`）
   - TinyML 卷积 → `+filter_data_ram` / `+IDRAM_U[0].input_data_ram`（`res.csv:333,334`）
4. `out\mmt.map.rpt:1634-1673` 的 **Memory Trimming Report**：出现新的 `tied off / disconnected` 条目就说明有 RAM 被优化掉（可能是好事也可能是坏逻辑，需分辨，见 §3.5）。

另外**必须**同时确认时序没有回归（改 IP 会改变布局）：跑完 `efx_pnr` 后看 `out\mmt.timing.rpt` 的负 slack 条数为 0。BRAM 从 222 降到 192 会释放大量布线资源，**预计时序会变好**，但 R1 改了 `rd_fifo` 相关路径，需实测。

---

## 9. 待确认 / 无法确认的事项

| # | 事项 | 状态 |
|---|---|---|
| 1 | `checker0/u_ddr_buffer/ddr_wr_buffer_inst/u_wr_fifo` 的 128b×1024 写 FIFO 读端口被 disabled（`map.rpt:1635-1660`），一块 BRAM 都没占 | **无法确认**是"写通路死了"还是"SRL 实现"。驱动链 (`frame_buffer.v:163,203` → `ddr_buffer.v:136` → `ddr_wr_buffer.v:106`) 和 `ddr_wr_buffer.v:482` 的 `wr_fifo_rden` 都看着是活的，倾向前者不成立。**请 Lead 复核功能** |
| 2 | VexRiscv iCache/dCache 的块数对 `CacheSize` 的敏感度（R5 的 −4 是估算） | **推算**，区间 2～6，需重跑确认 |
| 3 | OCRSize 用模式 (12,2) 打包是否真能被 mapper 选中（决定省 16 还是 13） | **推算**，区间 13～16 |
| 4 | `u5_fifo_131w256d` 实测 4 块 vs 模型 7 块（工具混排更优） | 已知偏差，未影响任何推荐项的算术 |
| 5 | 把 `DDR_IdWidth` 8→4 能否减小 SoC 的 DDR 队列（17 块） | **无法确认**，需实验；收益 ≤3 块，不建议优先 |
| 6 | 只改 `tinyml_core0_define.v` 宏而不跑 generator 是否生效（可省一次重生成） | **需实验**（§7.2） |
| 7 | 本文所有「省 N 块」数字 | **全部为推算，待 Lead 重跑 efx_map 验证**；实测数字均已标注行号 |

---

## 10. 附录

### 10.1 复现本次归因的命令（只读，不跑流程）

```powershell
# 1) 总账
Select-String -Path D:\FPGA\mmt\out\mmt.map.rpt -Pattern 'EFX_RAM10|EFX_DPRAM10|EFX_SRL8'
Select-String -Path D:\FPGA\mmt\out\mmt.place.rpt -Pattern 'Memory Blocks|XLRs:|DSP Blocks'

# 2) 逐模块 self 归因（父节点减去直接子节点，自底向上加总 = 222）
#    见本文件 §3；解析脚本要点：按 '+' 的缩进建栈，self = mem - 直接子节点 mem 之和
# 3) 每个 RAM 的宽度/深度（模块参数）
Select-String -Path D:\FPGA\mmt\out\mmt.res.csv -Pattern 'DC_FIFO|common_simple_dual_port_ram|common_efx_fifo_wrapper|mmt_dpram'
# 4) 原语模式表
Get-Content 'D:\Efinity\2026.1\ipm\ip\efx_bram\source_exp\bram_decompose.vh' | Select-Object -Skip 17 -First 14
# 5) 厂商 BRAM 估算公式
Get-Content 'D:\FPGA\tinyml\tools\tinyml_generator\lib\resource_lib.py' | Select-Object -Skip 116 -First 71
```

### 10.2 关键证据索引

| 结论 | 证据位置 |
|---|---|
| 总块数 = 222 | `out\mmt.place.rpt:336`；`out\mmt.map.rpt:5136-5137` |
| EFX_RAM10 的 8 种形状（20bit 宽度上限） | `D:\Efinity\2026.1\ipm\ip\efx_bram\source_exp\bram_decompose.vh:22-29` |
| 厂商块数公式 | `D:\FPGA\tinyml\tools\tinyml_generator\lib\resource_lib.py:177-186` |
| CACHE_DEPTH 合法范围（最小 512） | `...\tinyml_generator.py:171-177` |
| TINYML_CACHE 只有 ENABLE/DISABLE | `...\tinyml_generator.py:164-179` |
| OUT_CH_FIFO_A/FILTER_FIFO_A/CNT_DTH 不可见 | `...\tinyml_generator.py:77-97` |
| 卷积 BRAM 公式（AW=max(log2(N),9)） | `resource_lib.py:117-137` |
| cache BRAM 公式 | `resource_lib.py:140-156` |
| AXI 位宽转换 FIFO 深度硬编码 256 | `resource_lib.py:167-173` |
| TinyML 参数入口 | `ip\tinyml\tinyml_core0_define.v:1-18` |
| SoC 参数入口 | `ip\sapphire_soc\settings.json:70,71,80` |
| 帧缓冲 FIFO 深度 | `rtl\mmt\mmt_top.v:664-665`；`rtl\frame_buffer\ddr_rd_buffer.v:6,324` |
| 帧差背景 RAM | `rtl\mmt\mmt_top.v:1665-1666`；`rtl\mmt\algo\mmt_frame_diff.v:39,105-112`；`rtl\mmt\sensors\mmt_dpram.v:26-45` |
| 字模 ROM | `rtl\mmt\osd\mmt_osd_overlay.v:96-100` |
| 写 FIFO 被 disable 的异常 | `out\mmt.map.rpt:1634-1673` |
