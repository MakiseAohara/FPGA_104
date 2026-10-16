# TinyML 加速器访存地址审计

> 目的：在**跑 AI 之前**，用静态证据回答「TinyML 加速器的 DDR 访问会不会越界到视频区(R5)/代码区/R8」。
> 背景是今天刚修掉的一类真实 bug：`frame_buffer` 漏转发几何参数 ⇒ 帧步长按 1920 版算 ⇒
> bank2 写进 R7 张量区前 **1.80 MB**（`docs\帧步长修复-DDR分区对齐.md:54-58`）。
>
> 规矩：每条结论给 `文件:行`；**【实测】**（读到的文件内容/反汇编/官方文档原文）与
> **【推断】**（由证据推出但没直接读到）分开标；加密 IP 内部一律写 **【无法从 RTL 确认】**。
>
> 本文档**只读**，没有改动 `D:\FPGA\mmt\**` 下任何文件，没有跑 Efinity。
> 日期：2026-10-13。

---

## 0. 一句话结论

> **【实测】现在不会越界——因为固件从来没给加速器发过任何一条命令，TinyML 主口在运行中一笔事务都没有。**
> **【推断】一旦接上推理，越界风险不在"加速器自己乱跑"，而在"固件传进去的指针 + 张量尺寸参数"：
> 地址完全由命令参数决定，而加速器没有任何硬件地址窗口保护，DDR3 控制器也没有可见的越界检查。**
> **⇒ 结论是"当前安全，但接入推理后必须用硬件观测来定"，最小手段见 §6（7 个只读寄存器：最大 AW/AR 地址、
> 采样计数与越界粘滞位、越界笔数、命令计数、魔数）。**

分层回答（这是本审计的核心）：

| 问题 | 结论 | 依据 |
|---|---|---|
| Q1 TinyML 主口能不能到达 R5/R8/代码区？ | **能**。三主口共用同一个 256MB 从口窗口，互联**不做按主口的隔离** | §1 |
| Q2 DDR3 控制器会拦住越界地址吗？ | **【无法从 RTL 确认】**；可见参数显示只会截断/回绕（2^28=256MB），**大概率不报错** | §2 |
| Q3 加速器内部会不会自己造出越界地址？ | **地址不是它自己编的**——IP 里没有任何基址/窗口参数，wrapper 直通；地址来自 CPU 传的指针 | §3 |
| Q4 现在会不会越界？ | **不会**：固件从未发起推理（`sw\main.c:21,340`），命令计数为 0 ⇒ 零事务 | §4 |
| Q5 接上推理后呢？ | **【无法从静态证据确认】**，需要 §6 的硬件观测；风险形态与今天 frame_buffer 同型 | §5 |

---

## 1. AXI 互联的地址译码：三个主口 → 一个 256MB 窗口，**没有按主口的隔离**

### 1.1 结构（【实测】）

顶层 `rtl\mmt\mmt_top.v:816-917` 例化 `axi_interconnect u_ddr_axi_ic`，
三个主口按**扁平向量高位在前**拼接：

| 互联口 | 主设备 | 顶层信号 | 证据 |
|---|---|---|---|
| s2（最高位） | TinyML 加速器 | `tml_awaddr[31:0]` / `tml_araddr[31:0]` / `tml_awid[3:0]` / `tml_arid[3:0]` | `mmt_top.v:821-822, 833, 850-851, 861` |
| s1 | Sapphire SoC | `soc_ddr_awaddr` / `soc_ddr_araddr` | `mmt_top.v:822, 851` |
| s0（最低位） | frame_buffer（checker0） | `fb_awaddr` / `fb_araddr` | `mmt_top.v:822, 851` |

互联的**唯一**下游（m 口）接到 DDR3 控制器：`mmt_top.v:873-916` → `s_axi_*` →
`ddr3_top u_ddr3_top` 的从口（`mmt_top.v:1034-1074`）。
⇒ **三个主口共享同一条通往 DDR 的通路，互联里没有"哪个主口只能访问哪段地址"的配置。**

### 1.2 互联自己的地址表：只有一个窗口，0x00000000 + 2^28 = 256MB（【实测】）

`ip\axi_interconnect\settings.json:15-40`：

```json
"ARB_MODE": "\"PRIORITY\"",
"S_PORTS": "3",                    // 3 个上游主口
"M_PORTS": "1",                    // 1 个下游从口
"TABLE0_AXI_S0__MIN": "32'd0",        "TABLE0_AXI_S0__MAX": "32'd28",
"TABLE0_AXI_S1__MIN": "32'd268435456", "TABLE0_AXI_S1__MAX": "32'd24",
"TABLE0_AXI_S2__MIN": "32'd285212672", "TABLE0_AXI_S2__MAX": "32'd12",
...（S3..S7 为 IP 默认表残留）
"DATA_WIDTH": "128", "ADDR_WIDTH": "32", "ID_WIDTH": "4", "PROTOCOL": "\"AXI4\""
```

官方 IP 文档把这两个参数的含义写死了（`D:\Efinity\2026.1\ipm\ip\efx_axi_interconnect\ipm\doc\topics\axi-interconnect-core-params.html:242-257` 原文）：

> **Destination Address Space (Address Width)** 12 - 32 —— *Defines the **slave address width**.*
> **Destination Address Offset (Base Address)** h00001000 - hFFFFF000 —— *Starting offset address for each slave.*

以及 `axi-interconnect-fd.html:175-176`：

> **Address decoders**—Decodes address from the incoming AXI transaction and determines the targeted AXI slave transaction.

所以 `TABLE0_AXI_S0__MIN = 0`、`__MAX = 28` 的含义是：
**下游从口 0 的基址 = 0x00000000，地址宽度 = 28 位 ⇒ 窗口 = [0x00000000, 0x10000000) = 256MB。**

交叉验证：本工程作者在同一处标注了同样的结论（`rtl\mmt\mmt_top.v:320-322`）：

> `Efinity IP efx_axi_interconnect 5.6` / `参数 S_PORTS=3 / M_PORTS=1 / DATA_WIDTH=128 / ID_WIDTH=4 / ADDR_WIDTH=32`
> `默认 ARB_MODE=PRIORITY、PROTOCOL=AXI4、**下游地址窗口 0x00000000 宽 28 位(256MB)**`

**判据（回答 task-26 的 Q1）**：
- 我们计划用的三个区间 R5 `0x02000000`、R7 `0x03000000`、R8 `0x04000000` **都在** `[0, 0x10000000)` 内 ⇒ **都能到达 DDR3**，地址不会被互联吃掉；
- 但反过来：**互联不会阻止 TinyML 去访问 R5 或代码区**——它只有一个窗口，三个主口在它眼里没有区别。
- `0x10000000` 及以上的地址**不在**任何窗口内。此时 IP 的行为（返回 DECERR？直接转发？截断到 28 位？）
  **【无法从 RTL 确认】**：`ip\axi_interconnect\axi_interconnect.v` 有 **84 处 `pragma protect`**（加密），
  `axi_interconnect_define.vh` 里只有 `localparam`，没有译码逻辑。

> 顺带一个重要事实：**"物理 DDR 256MB" 与 "互联窗口 256MB" 恰好一致**
> （物理容量见 `docs\DDR固件与模型放置方案.md` §1.3，由 `rtl\ddr3_controller\ddr3_parameter.vh:5-8` 几何反推）。
> 也就是说：**合法的和有风险的边界是同一条线 0x10000000**。任何主口只要发出 ≥ 0x10000000 的地址，
> 就已经同时越过"互联窗口"和"物理内存"两条线。

---

## 2. DDR3 控制器：窗口覆盖 R7，但**没有可见的越界保护**

### 2.1 覆盖情况（【实测】可见参数）

`rtl\ddr3_controller\ddr3_parameter.vh`：

```
:5  `define RANK_WIDTH   1
:6  `define BANK_WIDTH   3        // 8 banks
:7  `define ROW_WIDTH    14       // 16384 rows
:8  `define COL_WIDTH    10       // 1024 columns
:10 `define DQS_WIDTH    2
:11 `define DQ_WIDTH     16       // 16-bit data bus
:15 `define DRAM_WIDTH   8        // x8 devices
:20 `define ADDR_WIDTH   30
:22 `define AXI_ADDR_WIDTH 32
:23 `define AXI_DATA_WIDTH 128
```

- `rtl\ddr3_controller\local_bus_ctl\local_bus_ctl.v:36`（明文可读）：
  `parameter ADDR_WIDTH = RANK_WIDTH + BANK_WIDTH + ROW_WIDTH + COL_WIDTH;`
  ⇒ 内部存储地址 = 1+3+14+10 = **28 位** ⇒ 2^28 = 268,435,456 B = **256MB**。
- `rtl\ddr3_controller\axi4_bus_ctl\axi4_bus_ctl.v:28`（明文可读的默认值）：`parameter AXI_AW = 30,`
- `rtl\ddr3_controller\ddr3_top.v:104-105, 132-133`：对外从口是 `s_axi_awaddr[AXI_ADDR_WIDTH-1:0]` = **32 位**。

⇒ **R7 张量区 `0x03000000–0x03FFFFFF` 完全落在 256MB 内，控制器能正常访问它**（【实测】参数 + 【推断】容量换算）。
不存在"张量区落到物理内存之外"的问题。

### 2.2 有没有越界保护？（【无法从 RTL 确认】+【推断】）

- `rtl\ddr3_controller\` 下**所有**模块文件都加密：`ddr3_top.v`、`axi4_bus_ctl.v`、`local_bus_ctl.v`、
  `memory_bus_ctl.v`、`lb2_axi_clk.v` 每个文件都有 **20 处 `pragma protect`** ⇒ 内部地址比较/响应逻辑读不到。
- 全目录 grep `DECERR / SLVERR / 2'b11` 只命中 `axi4_bus_ctl.v:58,76`（`s_axi_bresp/s_axi_rresp` 端口声明）
  和 `ddr3_top.v:127,149`（同名的端口声明）——**没有任何可见的"越界就报错"的赋值**。
- 【推断】结合 `AXI_AW = 30`（默认）与内部 28 位存储地址：**高地址位很可能是被直接丢弃（truncate）**，
  即 `addr ≥ 0x10000000` 会**回绕/别名**到低地址，而不是返回错误响应。
  这意味着一次越界写**不会报错，只会静默地改掉低地址的数据**——和今天 frame_buffer 那个 bug 一样"无声"。

> **【无法从 RTL 确认】的确切行为**（三种可能，后果差别很大）：
> ① 截断回绕（最危险：越界写会盖掉 app 区/权重区，且无任何报错）；
> ② 返回 DECERR/SLVERR（最理想：至少主口能知道错了，但我们三个主口目前**都没有检查 bresp/rresp**）；
> ③ AXI 层被截到 30 位后再进 28 位内部地址（等价于①）。
> 证实方法见 §6（硬件探针）与 §7。

### 2.3 一个可选的"硬件防火墙"（加固选项，**待验证**）

既然互联的窗口是参数化的（`TABLE0_AXI_S0__MAX = 28` = 256MB），理论上可以把它改成
**26 位 = 64MB**（窗口 `[0, 0x04000000)`）：

- 覆盖检查：app/权重 `0x1000–0x47FFFF` ✅、R5 帧缓存 `0x02000000–0x02BDDDFF` ✅、
  R7 张量 `0x03000000–0x03FFFFFF` ✅；只有**没人用**的 R8 `0x04000000+` 被切掉。
- 但这只有在 §2.2 的行为是"② 返回错误响应"时才等于装了一道防火墙；
  如果行为是"① 截断回绕"，改窗口**毫无保护作用**（甚至更糟：把 0x04000000 映射回 0x0）。
- ⇒ **【推断】不建议现在改**。先按 §6 量出真实行为，再决定。
- 注意：改这个参数属于 **IP 重新生成 = Lead 的活**，且会改网表 ⇒ 必须重跑流程。

---

## 3. 加速器内部的地址从哪来：**来自 CPU 传的指针**，IP 里没有任何基址参数

这一节回答"加密 IP 内部地址生成看不到"这个难点——**看不到，但可以从它的外部 API 反推出地址的来源。**

### 3.1 IP 里根本没有"基址/窗口"这类参数（【实测】）

`ip\tinyml\tinyml_top.v:25-45` 的全部参数：

```verilog
parameter AXI_DW, ADD_MODE, MIN_MAX_MODE, MUL_MODE, FC_MODE, LR_MODE, TINYML_CACHE, CACHE_DEPTH,
parameter CONV_DEPTHW_MODE, CONV_DEPTHW_LITE_PARALLEL, CONV_DEPTHW_LITE_AW,
parameter CONV_DEPTHW_STD_IN_PARALLEL, CONV_DEPTHW_STD_OUT_PARALLEL,
parameter CONV_DEPTHW_STD_OUT_CH_FIFO_A, CONV_DEPTHW_STD_FILTER_FIFO_A, CONV_DEPTHW_STD_CNT_DTH,
parameter FC_MAX_IN_NODE, FC_MAX_OUT_NODE, ENABLED_ACCELERATOR_CHANNEL
```

**没有 base address / 地址窗口 / 地址掩码参数**。`tinyml_accelerator_channels.v:56-57` 同样只有
`AXI_DW_M`、`STRING_LENGTH`。⇒ 地址不是由 IP 配置决定的。

### 3.2 wrapper 是**直通**的，不加偏移（【实测】）

`ip\tinyml\tinyml_accelerator_channels.v:323-354`（单通道分支，明文、MIT 许可）：

```verilog
if (`NUMBER_OF_CHANNELS == 1) begin : single_channel
    assign m_axi_awaddr         = s_axi_tinyml_awaddr;   // :326  ← 无偏移、无掩码
    ...
    assign m_axi_awsize         = $clog2(AXI_DW_M/8);    // :330  = 4 → 16 字节/beat
    assign m_axi_awburst        = 2'b01;                 // :331  INCR
    assign m_axi_awcache        = 4'b0011;               // :334
    assign m_axi_araddr         = s_axi_tinyml_araddr;   // :346  ← 同上
```

⇒ 送到互联 s2 的地址 = 加密核内部产生的地址，**没有任何顶层可调的基址**。

顺带（对"对齐"有用）：加速器的 AXI 突发是**固定 `awsize=4`（16 字节/beat）+ INCR**，
突发长度由核内部给。⇒ **基址若不按 16 字节对齐，首拍需要 strobe 掩码**；
厂商文档要求的 8 字节对齐（见 3.3）是底线，建议我们按 **16 字节（更保守 128 字节）** 对齐张量。

### 3.3 那地址是谁给的？——**CPU 通过自定义指令把指针传进去**（【实测】）

命令通路（`rtl\mmt\mmt_top.v`）：

- 加速器命令口：`.cmd_valid(ci_cmd_valid) / .cmd_function_id(ci_function_id[9:0]) /
  .cmd_inputs_0/.cmd_inputs_1(各 32 位) / .cmd_ready / .rsp_valid / .rsp_outputs_0`
  （`mmt_top.v:935-944`）。
- 这些信号由 SoC 的**自定义指令（custom instruction）端口**驱动：
  `mmt_top.v:1638-1645` 接到 `u_soc`（`mmt_soc_subsystem`）的 `ci_*`，
  而 `rtl\mmt\soc\mmt_soc_subsystem.v:330-337` 明确把它们接到
  `cpu0_customInstruction_cmd_valid / function_id / inputs_0 / inputs_1 / rsp_ready / …`
  （注释 `:313-319` 说明方向与来源）。
- SoC 侧确实开了自定义指令：`ip\sapphire_soc\source\soc_config:15` `--customInstruction true`。

厂商软件 API 证实**参数就是地址**（`D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\embedded_sw\SapphireSoc\software\standalone\evsoc_tinyml_pdti8\src\platform\tinyml\ops\`）：

`conv.h:8-41`（**实测原文**）：

```c
OP_STATUS_T conv_drv(
        const int stride_width, ... const int output_height,
        const int32_t output_activation_min, const int32_t output_activation_max,
        const int32_t *output_multiplier, const int32_t *output_shift,
        const int8_t  *input_data,      // ← 输入张量地址（指针）
        const int8_t  *filter_data,     // ← 权重地址
        const int32_t *bias_data,       // ← 偏置地址
        const int32_t *input_shape, const int32_t *output_shape, const int32_t *filter_shape,
        int8_t        *output_data);    // ← 输出张量地址
```

`cache.h:10-20`：

```c
void cache_init_trigger(
        int32_t set_0_num_of_cache_lines, int32_t set_0_num_of_cache_words,
        int32_t set_0_roll_update_gap_bytes,
        int32_t set_0_ext_addr,          // ← 32 位地址，显式传入
        ...  int32_t set_1_ext_addr, int roll_update_enable);
```

调用点证实这些指针来自 TFLite 张量本体
（`...\src\tensorflow\lite\kernels\internal\reference\integer_ops\conv.h:70-75`，
把 `input_data / filter_data / bias_data / output_data` 原样传给 `conv_drv`）。

**⇒ 结论（回答 Q3）：加速器不"自己编"地址；它的每一笔 AXI 地址都源自 CPU 命令里的指针，
再按 shape/stride/size 参数在内部递推。**

**⇒ 风险因此变成两层**：
1. **基址层**：固件把张量基址写到别处（例如误用 `0x02000000` = R5）⇒ 直接踩视频区。
   这一层**固件可防**（用 `sw\ddr\mmt_ddr.h:48` 的 `MMT_TENSOR_BASE 0x03000000` 而不是硬编数字）。
2. **尺寸层（更隐蔽）**：基址对，但 shape/stride/通道数写错 ⇒ 加速器按错误的尺寸**递推越过缓冲区尾部**。
   **这与今天 frame_buffer 的 bug 完全同型**（`docs\帧步长修复-DDR分区对齐.md:28`：漏转发 `FB_NUM/MAX_VID_WIDTH/MAX_VID_HIGHT` ⇒ 步长算成 1920 版 ⇒ 越界 1.80MB）。
   **这一层静态审计防不住**（尺寸递推在加密核内部），只能靠硬件观测。

---

## 4. 命令通路现状：**固件从未发起过推理**（【实测】）

| 检查项 | 结果 |
|---|---|
| `sw\main.c` 有没有调推理？ | **没有**。`:21` "3) AI 推理（TinyML）的调用还没接（要等 TinyML Generator 生成加速器）"；`:340` "TODO：接 TinyML 推理。现在用'帧差面积归一化'占位" |
| 全 `sw\**` 有没有 `opcode_R(CUSTOM0, …)` / `ops_*` / `conv_drv` / `cache_init_trigger`？ | **零命中**（grep 过 `sw\` 下全部 `.c/.h/.S`）。唯一命中 `0x500F` 的是 D-cache 失效指令（`sw\ddr\ddr_app.c:136`、`sw\ddr\loader.c:164,274`），与 TinyML 命令无关 |
| `mmt_soc_regs.v` 里有没有 TinyML 命令/地址寄存器？ | **没有**（读完寄存器映射 `:15-66` 与读写 case `:361-421`：只有传感器/算法/帧缓存遥测/摄像头探针/测试图案） |
| ⇒ `ci_cmd_valid` 会被谁拉高？ | 只有 CPU 执行自定义指令时。**当前固件不执行任何自定义指令**（除 D-cache 那条），所以 `ci_cmd_valid` 恒 0 |

**⇒ 所以今天这个位流在运行中，TinyML 主口的 AXI 事务数恒为 0 ⇒ 不可能越界。**
但必须说清楚：**这是"没跑"，不是"跑不坏"。** 一旦接入推理，§3 的两层风险立刻生效。

> 附：`ip\tinyml\tinyml_core0_define.v:17` 显示当前配置是
> `TML_C0_TINYML_CACHE "DISABLE"`（注释：2026-10-12 为省 22 块 BRAM 关掉，"权重每次从 DDR 读"）。
> 缓存关掉**不影响地址范围**，但会让权重读取**每次都真的打到 DDR** ⇒ 地址审计只会更重要，不会更松。

---

## 5. 结论：会不会越界

**分层结论（这三条要一起看，别只挑一条）：**

1. **【实测】当前位流：不会。** 固件从未发命令 ⇒ 零事务 ⇒ 无从越界（§4）。
2. **【推断】硬件层面：没有任何东西能阻止它越界。**
   - 互联只有一个 256MB 窗口、不区分主口（§1）；
   - 加速器 IP 没有基址/窗口参数，wrapper 直通（§3.1/3.2）；
   - DDR3 控制器加密，可见参数显示只会截断/回绕，**没有可见的越界保护**（§2.2）。
3. **【无法从静态证据确认】接入推理之后：取决于固件传什么。**
   风险有两层：**基址传错**（固件可防）和**尺寸参数递推越界**（同 frame_buffer 的 bug 型态，静态防不住）。
   ⇒ 必须按 §6 装硬件观测，**把"能不能越界"变成一个能读出来的数字**。

**判据（回答 task-26 第 5 点）：现在不能给"一定会/一定不会"，只能给"当前不会 + 接入后必须有观测"。**
所以下面给出最小验证手段。

---

## 6. 最小验证手段：TinyML 访存遥测寄存器（方案，**我没有改 RTL**）

思路照搬 task-22 给 frame_buffer 做的那套（`docs\上板判据-最大写地址.md`）：**在 core_clk 域对 AXI 握手采样。**

### 6.1 要在 `mmt_soc_regs.v` 新增的寄存器（读口，地址都不与现有映射冲突）

**冲突核查（【实测】，快照时间 2026-10-13 15:22）**：
`mmt_soc_regs.v` 此刻的读地址占用是——
显式 case：`0x00–0x2C / 0x4C / 0x5C / 0x64 / 0x6C-0x7C / 0xC8-0xD4 / 0xD8 / 0xDC`；
摄像头探针走 `default`：`PADDR[7:2] ∈ [32,47]` 即 **`0x80–0xBC`**（`mmt_soc_regs.v:350-354`），
其中 `0xC0/0xC4` 是**故意不映射**的探针窗口越界保护（`:344-347`）。
⇒ **`0xE0` 及以上是空闲的**。

> ⚠️ **警告：`mmt_soc_regs.v` 正在被 task-24（bram-optimizer）并发修改。**
> 就在本次审计期间，`FB_AWADDR_MAX / FB_AW_STAT` 已从 `0xA8/0xAC` 移到 `0xD8/0xDC`
> （`:396-403` 的注释记了原因：原先插在探针线性窗口里，把 raddr 10/11 挡死了）。
> ⇒ **实施前必须重新 grep 一遍地址占用**（`Select-String '16''h00[0-9A-Fa-f]{2}:'`），
> 下表只是"截至 15:22 空闲"的建议。

| 建议地址 | 名称 | 内容 | 用途 |
|---|---|---|---|
| `0xE0` | `TML_AWADDR_MAX` | `[31:0]` 历史最大 `tml_awaddr`（只在 `awvalid && awready` 那拍取样，单调不减） | 最大的写地址 |
| `0xE4` | `TML_ARADDR_MAX` | `[31:0]` 历史最大 `tml_araddr` | 最大的读地址 |
| `0xE8` | `TML_AW_STAT` | `[15:0]` AW 采样次数（饱和 0xFFFF）`[16]` 至少采样过一次 `[17]` 曾采到 `≥ 0x04000000` `[18]` 曾采到 `< 0x03000000` | **必须与 `0xE0` 联合读**：`amax=0 且采样=0` = 根本没跑，不是"没越界"（这是 task-22 踩过的坑） |
| `0xEC` | `TML_AR_STAT` | 同 `0xE8`，针对 AR | 同上 |
| `0xF0` | `TML_OOR_CNT` | `[31:0]` 落在 `[0x03000000, 0x04000000)` **之外**的事务笔数（AW+AR 合计，饱和不回绕） | **直接回答"越界了没有"** |
| `0xF4` | `TML_CMD_CNT` | `[31:0]` `ci_cmd_valid && ci_cmd_ready` 握手次数 | 证明"固件到底有没有发命令"（当前应为 0） |
| `0xF8` | `TML_LAST_FUNC` | `[9:0]` 最近一次 `ci_function_id` `[10]` 曾经发过命令 `[31:16]` 固定魔数 `16'hA5C3` | 魔数用来区分"探针没进这版位流"与"真读数是 0"（task-24 的同款教训） |

其中 `0xF0` 的两个边界用 `mmt_ddr.h:48-49` 的 `MMT_TENSOR_BASE/MMT_TENSOR_LIMIT` 作为判据常量最省事。

### 6.2 需要 Lead 加的行（**锚点已核对，按锚点插入**）

所有信号**已经在 `mmt_top.v` 里存在**，且**同属 core_clk 域**（互联 `.clk(core_clk)` `mmt_top.v:817`；
加速器 `.m_axi_clk(core_clk)` `:946`；`u_soc .clk(core_clk)` `:1539` → `mmt_soc_subsystem .clk(clk)` `:248`
→ `mmt_soc_regs .clk(clk)` `:440`）⇒ **不需要 `mmt_sync2`，直接接即可**。

1. **`rtl\mmt\mmt_top.v`** —— 新增 wire 不用（信号已存在）；只需在 `u_soc` 例化里**追加 8 行连接**：
   锚点 `mmt_top.v:1703-1717`（`.fb_awvalid … .cam_probe_rdata` 这一段）之后，形如：

   ```verilog
   .tml_awaddr      (tml_awaddr),      // 顶层已有：mmt_top.v:429
   .tml_awvalid     (tml_awvalid),     // :428
   .tml_awready     (tml_awready),     // :437
   .tml_araddr      (tml_araddr),      // :447
   .tml_arvalid     (tml_arvalid),     // :446
   .tml_arready     (tml_arready),     // :455
   .ci_cmd_valid    (ci_cmd_valid),    // :417（wire 已声明，:1638 已接 u_soc 输出）
   .ci_cmd_ready    (ci_cmd_ready),    // :422
   .ci_function_id  (ci_function_id),  // :418
   ```

2. **`rtl\mmt\soc\mmt_soc_subsystem.v`**：
   - 端口表：锚点 `:206-220`（`fb_awvalid … vid_frame_cnt`）之后追加同样的 9 个 `input`；
   - `u_soc_regs` 例化（`:439` 起）：锚点 `:503-517`（`.fb_awvalid … .vid_frame_cnt`）之后追加 9 行 `.xxx(xxx)`。

3. **`rtl\mmt\soc\mmt_soc_regs.v`**（⚠️ 该文件正被 task-24 并发修改，行号以实施时为准）：
   - 端口表：锚点 `:140-149`（`fb_awvalid/fb_awready/fb_wvalid/fb_wready/fb_awaddr`）之后追加 9 个 `input`；
   - 计数器：全部加 `(* preserve, syn_keep = 1 *)`（同 `:248/:288` 的理由：这批输入曾被工具证成常量而折掉）；
   - 读 case：锚点 `:416`（`16'h00D4`）之后追加 7 条 `case`（`0xE0/0xE4/0xE8/0xEC/0xF0/0xF4/0xF8`）；
     **不要**去动 `:400/:403` 的 `0xD8/0xDC`（那是 fb 的最大写地址，task-22/24 刚搬过去的）；
   - 关键采样逻辑（与 `:297-301` 的 fb 版同构）：

   ```verilog
   if (tml_awvalid && tml_awready) begin
       if (tml_awaddr > tml_aw_max) tml_aw_max <= tml_awaddr;
       if (tml_aw_smp != 16'hFFFF)  tml_aw_smp <= tml_aw_smp + 16'd1;
       if (tml_awaddr <  32'h03000000) tml_aw_lo <= 1'b1;
       if (tml_awaddr >= 32'h04000000) tml_aw_hi <= 1'b1;
       if ((tml_awaddr < 32'h03000000) || (tml_awaddr >= 32'h04000000))
           if (tml_oor_cnt != 32'hFFFFFFFF) tml_oor_cnt <= tml_oor_cnt + 32'd1;
   end
   ```

4. **固件**（`sw\**`，属 ddr-loader 的写权限）：串口多打一行，例如
   `[TML] CMD=%u AWmax=0x%08X ARmax=0x%08X OOR=%u awsmp=%u amaxed=%u` —— 格式自定，但**必须把
   `TML_CMD_CNT` 和 `OOR` 放进去**。

### 6.3 判读表（**这是本审计最实用的产物**）

| 场景 | `CMD_CNT`(0xF4) | `AW_STAT` 采样(0xE8[15:0]) | `OOR`(0xF0) | `AWADDR_MAX`(0xE0) | 结论 / 动作 |
|---|---|---|---|---|---|
| **A 当前状态**（固件没接推理） | **0** | 0 | 0 | 0 | 加速器完全没动 ⇒ 不存在越界；**这不是"验证通过"，只是"没跑"** |
| **B 命令发了但零事务** | >0 | 0 | 0 | 0 | 命令通道活着但没产生 AXI ⇒ 查 `TML_LAST_FUNC`(0xF8)；很可能是参数全 0 / 命令被忽略 |
| **C 正常** | >0 | >0 | **0** | `0x03000000 ≤ amax < 0x04000000` | **TinyML 只在 R7 内活动** ⇒ 可以放心跑 AI |
| **D 越界（基址错）** | >0 | >0 | >0 | `amax < 0x03000000` 且落在 `0x02000000–0x02BDDDFF` | 踩进 **R5 视频区** ⇒ 查固件是不是把张量基址写成了 0x02000000 |
| **E 越界（尺寸错）** | >0 | >0 | >0 | `0x04000000 ≤ amax` | 尺寸参数递推过头（同 frame_buffer bug 型态）⇒ 查 shape/stride/通道数 |
| **F 探针没进位流** | 读 `0xF8` 拿不到魔数 `0xA5C3` | — | — | — | **所有 0 都不可信**（旧位流读 `0xE0+` 也是 0）⇒ 先确认位流版本 |

**两条判读纪律（都是从 task-22/24 的坑里总结的）**：
1. **绝不单看 `AWADDR_MAX`**：`amax = 0` 搭配 `采样 = 0` 只说明"没跑"，必须与 `CMD_CNT`、采样计数联合读。
2. **绝不单看 `OOR = 0`**：必须先确认 `CMD_CNT > 0` **且** `AW_STAT[16] = 1`（至少采样过一次），
   否则 `OOR = 0` 只可能是"没发生任何事务"。

---

## 7. 剩余不确定项（每条给证实方法）

| # | 不确定项 | 现状 | 怎么证实 |
|---|---|---|---|
| U1 | 互联对**窗口外地址**（≥0x10000000）的行为：DECERR / 直通 / 截断 | **【无法从 RTL 确认】**（84 处 pragma protect） | ① 上板：让固件**故意**读 `0x10000000` 看 `bresp/rresp`（需固件能看响应码）；② 或说服 Efinix 支持；③ 或按 §6 的 OOR 探针间接观察 |
| U2 | DDR3 控制器对越界地址是否报错 | **【无法从 RTL 确认】**（全部加密）；**【推断】只截断/回绕** | 同上；另可在**未使用的** R8 区做一次"写 0x10000000 再看 0x00000000 有没有变"的破坏性试验（**只能在实验位流上做**，不要在正式位流上做） |
| U3 | 加密核内部到底按哪些尺寸递推地址、最大能递推多远 | **【无法从 RTL 确认】** | **只能靠 §6 的硬件探针**（这是本审计的核心建议）；仿真不可行（IP 加密，需 Questa/Riviera，参考 `docs\AXI互联仿真结论.md` 的结论） |
| U4 | 接上推理后固件会传什么指针 | 尚无推理代码（`sw\main.c:340` TODO） | 写推理代码时**只用** `sw\ddr\mmt_ddr.h:48` 的 `MMT_TENSOR_BASE`，并在启动时把该地址打印出来比对 |
| U5 | `TINYML_CACHE` 现在是 DISABLE（`ip\tinyml\tinyml_core0_define.v:17`），若改回 ENABLE 是否改变地址行为 | 参数表里 `CACHE_DEPTH=512` 只是深度，**没有地址参数** ⇒ 【推断】不改变地址范围 | 改回 ENABLE 后重读同样的探针寄存器，`OOR` 应仍为 0 |
| U6 | 张量对齐要求（厂商 8 字节；加速器 `awsize=4` = 16 字节/beat） | 【实测】厂商注释 `main.cc:63-64` 要求 ≥8 字节；wrapper 固定 16B beat（`channels.v:330`） | 代码里按 **128 字节**对齐分配张量；上板看数据是否正确（错位会表现为 `tkeep` 移位，厂商注释原话） |

---

## 附 A：本文档引用到的证据文件清单

| 文件 | 关键行 | 证明什么 |
|---|---|---|
| `D:\FPGA\mmt\rtl\mmt\mmt_top.v` | `:816-917` | 三主口 → 一从口的互联例化（扁平向量高位在前） |
| 同上 | `:873-916`, `:1034-1074` | 互联 m 口 = DDR3 控制器从口，中间没有任何地址过滤 |
| 同上 | `:320-322` | 作者标注：下游窗口 `0x00000000` 宽 28 位 = 256MB |
| 同上 | `:428-460` | TinyML AXI 主口信号（含 `tml_awaddr/tml_araddr`） |
| 同上 | `:929-981` | 加速器例化（命令口 + AXI 口） |
| 同上 | `:1638-1645`, `:1703-1717` | 命令口接 SoC；遥测信号锚点（新增寄存器用） |
| `D:\FPGA\mmt\ip\axi_interconnect\settings.json` | `:16-40` | 互联地址表：S0 base 0 / width 28；S_PORTS=3 / M_PORTS=1 |
| `D:\Efinity\2026.1\ipm\ip\efx_axi_interconnect\ipm\doc\topics\axi-interconnect-core-params.html` | `:242-257` | 官方原文：Address Width = **slave address width**；Offset = base address |
| 同上 `axi-interconnect-fd.html` | `:175-176` | 官方原文：地址解码器决定目标从口 |
| `D:\FPGA\mmt\ip\axi_interconnect\axi_interconnect.v` | 84 处 pragma protect | **互联内部译码无法从 RTL 确认** |
| `D:\FPGA\mmt\rtl\ddr3_controller\ddr3_parameter.vh` | `:5-8, 11, 15, 20, 22-23` | DDR3 几何 ⇒ 256MB；AXI 地址 32 位 |
| `D:\FPGA\mmt\rtl\ddr3_controller\local_bus_ctl\local_bus_ctl.v` | `:36` | 内部地址 = RANK+BANK+ROW+COL = 28 位 |
| `D:\FPGA\mmt\rtl\ddr3_controller\axi4_bus_ctl\axi4_bus_ctl.v` | `:28` | `parameter AXI_AW = 30` |
| `D:\FPGA\mmt\rtl\ddr3_controller\*.v` | 各 20 处 pragma protect | **DDR3 控制器内部无法从 RTL 确认** |
| `D:\FPGA\mmt\rtl\mmt\soc\mmt_soc_subsystem.v` | `:305-337` | 命令口 = SoC 的 `cpu0_customInstruction_*` |
| 同上 | `:206-220`, `:503-517` | 遥测端口锚点 |
| `D:\FPGA\mmt\rtl\mmt\soc\mmt_soc_regs.v` | `:15-66`, `:361-421` | 现有寄存器映射（`0xE0` 起空闲；快照 2026-10-13 15:22） |
| 同上 | `:350-354`, `:344-347` | 探针 decode 只覆盖 `0x80–0xBC`，`0xC0/0xC4` 故意不映射 |
| 同上 | `:396-403` | task-24 把 `FB_AWADDR_MAX/FB_AW_STAT` 从 `0xA8/0xAC` 搬到 `0xD8/0xDC`（**本审计期间发生**，说明该文件在并发修改） |
| `D:\FPGA\mmt\ip\tinyml\tinyml_top.v` | `:25-45` | IP 参数里**没有**基址/窗口 |
| `D:\FPGA\mmt\ip\tinyml\tinyml_accelerator_channels.v` | `:326, 330-334, 346` | wrapper **直通**地址，无偏移；`awsize=4`/INCR |
| `D:\FPGA\mmt\ip\tinyml\tinyml_accelerator.v` | 1176 处 pragma protect | **加速器内部地址生成无法从 RTL 确认** |
| `D:\FPGA\mmt\ip\tinyml\tinyml_core0_define.v` | `:17-20` | 当前 `TINYML_CACHE=DISABLE`、`CACHE_DEPTH=512` |
| `D:\FPGA\mmt\ip\sapphire_soc\source\soc_config` | `:15` | `--customInstruction true`（命令通道存在） |
| `...\evsoc_tinyml_pdti8\src\platform\tinyml\ops\conv.h` | `:8-41` | **地址 = CPU 传的指针**（input/filter/bias/output） |
| 同上 `ops\cache.h` | `:10-20` | `set_0_ext_addr / set_1_ext_addr` 是显式 32 位地址 |
| `...\src\tensorflow\lite\kernels\internal\reference\integer_ops\conv.h` | `:70-75` | TFLite 张量指针原样传给 `conv_drv` |
| `...\evsoc_tinyml_pdti8\src\main.cc` | `:63-67, 86-87` | 厂商固定 DDR 缓冲 `0x01100000` / `0x01600000`；要求 ≥8 字节对齐；arena 在 `.bss` |
| `D:\FPGA\mmt\sw\main.c` | `:21`, `:340` | **固件从未发起推理**（功能空白） |
| `D:\FPGA\mmt\sw\ddr\mmt_ddr.h` | `:39-52` | 本工程 DDR 分区常量（含 `MMT_TENSOR_BASE=0x03000000`） |
| `D:\FPGA\mmt\docs\帧步长修复-DDR分区对齐.md` | `:14-20, 54-58, 78-89` | 今天那个真实越界（1920 版步长 ⇒ 覆盖 R7 前 1.80MB；修好后 max `0x029E3000`） |
| `D:\FPGA\mmt\docs\DDR固件与模型放置方案.md` | §1.3 | 物理 DDR 256MB 的推断依据 |

## 附 B：与 R7（0x03000000）的对照小结（回答 task-26 第 3 点）

| 项目 | 厂商 TinyML 参考设计 | 我们（mmt） | 判定 |
|---|---|---|---|
| app 区 | flash `0x380000` → DDR `0x00001000` 起，`LDSize=16380K` | 同（`docs\DDR固件与模型放置方案.md` §2.4） | **一致** |
| 张量/缓冲地址 | 硬编在 `main.cc:65,67`：`0x01100000` / `0x01600000` | 计划 `0x03000000`（`mmt_ddr.h:48`） | **不同地址，但同一原则**：都放在"app 区之上、与其它硬件缓冲区错开" |
| 缓冲区是否可能覆盖 app 区 | 厂商用注释明确禁止（`main.cc:64`） | 我们靠 §3.2 的内存图（`docs\DDR固件与模型放置方案.md` §3.2） | 一致 |
| 对齐要求 | ≥8 字节（`main.cc:63-64`） | 计划 8 字节（`mmt_ddr.h:48` 注释） | 建议提高到 **16/128 字节**（加速器固定 16B beat，见 U6） |
| 越界保护 | 无（依赖软件正确） | 无（本审计结论） | **一致，且都靠软件自律** |
