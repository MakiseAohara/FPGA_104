# DDR 固件与模型放置方案

> 目标：把项目目标里最后一条「**模型与固件放 DDR 运行**」从「完全没做」推进到「照着做就能做」。
>
> 本文档**不需要板子、不需要跑 Efinity 流程**，全部结论来自读配置、读网表、反汇编厂商预编译文件。
> 每一处地址/参数后面都跟着 `文件:行`；凡是推断，都会明确写「**推断**」以及「怎么证实」。
>
> 状态：**方案 + 已本地实测的链接脚本/打包脚本**（见 `sw\ddr\`）。
> 未做：SoC IP 尚未重新生成（bootloader 还是 124K 那版）、位流尚未生成、上板未验证。

---

## 0. 一句话结论（TL;DR）

1. **给 CPU 看的 DDR 基址是 `0x00001000`，不是 0。**
   `0x00000000–0x00000FFF` 是总线解码的**空洞**，落进去会拿到一笔错误响应。
   证据：`ip\sapphire_soc\sapphire_soc.v:11628`；官方同款 SoC 的 BSP 宏 `soc.h:68-69`。
2. **DDR 解码窗口 3.5GB（0xE0000000），但板上物理 DDR 只有 256MB。**
   所有地址必须 < `0x10000000`。证据：`rtl\ddr3_controller\ddr3_parameter.vh:6-15`。
3. **`bootloader_124K.hex` 与 `LDSize=16380` 的不一致是真的，但根因不是"回落"。**
   - `LDSize` 只被用来改链接脚本的长度（`sw_script.py:602-604`），**跟 bootloader 选型无关**；
   - DDR 模式下生成器**硬编码**选 `bootloader_124K.hex`（`soc_gen.py:784-785`）；
   - 而那个 124K 的 bootloader 实测**只从 flash 搬 124KB**（反汇编见 §2.2），
     所以拿它启动一个 16MB 应用区是**载入不全**的。
   - **正确做法（官方 TinyML 参考设计的原样做法）**：`settings.json` 里
     `HexFile_PathEnable=1'b1` + `HexFile_Path` 指向 16MB 版 bootloader
     （`ref_files\bootloader_16MB\SapphireSoc\bootloader.hex`），它会从 flash `0x380000`
     搬 16MB 到 DDR `0x1000` 再跳过去。
4. **板载 flash 只有 8MB（GD25LQ64）**，而 bootloader 固定从 flash `0x380000` 起读，
   所以「固件 + 模型」总共只有 `0x800000-0x380000 = 4.5MB` 可用。
   本文据此给出 **app 1MB + 权重 3.5MB** 的切分。
5. **模型进 DDR 最省事的路子**：把模型权重直接**拼在固件后面**，一次搬进去
   （`sw\ddr\pack_image.ps1` 已实现并自测）。
   走这条路，权重固定在 DDR `0x00100000`，固件直接从那里读，**不需要在固件里写 flash 驱动**。

---

## 1. 给 CPU 的 DDR 区基址到底是多少

### 1.1 结论

| 项目 | 值 | 性质 |
|---|---|---|
| DDR 给 CPU 的**基址** | **0x00001000** | **实证** |
| DDR 解码**大小** | 0xE0000000（3.5GB） | 实证 |
| 实际可寻址区间（解码层） | `0x00001000 ≤ addr < 0xE0001000` | 实证 |
| 板上**物理** DDR 容量 | **256MB**（`0x00000000–0x0FFFFFFF`） | 推断（有几何参数依据，见 1.3） |
| `0x00000000–0x00000FFF` | **解码空洞，禁止使用** | 实证 |

### 1.2 证据链（三步，互相独立）

**证据 1：SoC 网表里的 BMB 解码（我们自己的工程）**

`ip\sapphire_soc\sapphire_soc.v:11628`：

```verilog
assign logic_hitsS0_2 = ((32'h00001000 <= io_input_cmd_payload_fragment_address)
                      && (io_input_cmd_payload_fragment_address < 32'he0001000));
```

这就是主总线解码器 `BmbDecoder_2`（模块定义在 `:11403`，例化在 `:3582`，实例名
`system_bridge_bmb_decoder`）的 4 个从口命中判断之一。四个从口分别是：

| 从口 | 命中条件 | 接到谁 | 行号 |
|---|---|---|---|
| `io_outputs_0` | `(addr & ~0x7fff) == 0xf9000000` | 片内 RAM（32KB） | `:11594` |
| `io_outputs_1` | `(addr & ~0xffffff) == 0xf8000000` | APB 桥（16MB 外设） | `:11611` |
| **`io_outputs_2`** | **`0x1000 ≤ addr < 0xE0001000`** | **→ BMB→128bit 扩位 → `system_ddr_*`（**DDR**）** | **`:11628`** |
| `io_outputs_3` | `(addr & ~0xffffff) == 0xe1000000` | AXI Slave（16MB，外部 AXI 从口） | `:11645` |

`io_outputs_2` → DDR 这条链路：`:3634` 接到 `system_bridge_bmb_upSizer`（`:3671` 例化），
其输出（`:3690`）接到 `system_ddr_bmb_slaveModel_arbiterGen_oneToOne_arbiter`。
整条链没有任何其它模块，所以 **`hitsS0_2` 的区间就是 CPU 眼里的 DDR 区间**。

**证据 2：同一份解码出现在厂商自己的 DDR demo 里（排除"我们配错"的可能）**

`07_官方demo工程\_ddr_demo_ti60\ip\soc\soc.v:11586` 是同一行（掩码/常量完全一致），
而那份 demo 是厂商交付、已经综合布线成功、上板跑通的工程。

**证据 3：厂商 BSP 头文件把同一个数写成了宏**

`07_官方demo工程\_ddr_demo_ti60\embedded_sw\soc\bsp\efinix\EfxSapphireSoc\include\soc.h:68-69`：

```c
#define SYSTEM_DDR_BMB 0x1000
#define SYSTEM_DDR_BMB_SIZE 0xe0000000
```

厂商软件侧也认为 DDR 基址是 **0x1000**。三者一致，基址 0x1000 可以定案。

**顺带确认 `0x1000` 之前的 4KB 是什么**：`sapphire_soc.v:11673 / 11677 / 11693` 的
`logic_rspNoHitValid / logic_rspNoHit_doIt / logic_rspNoHit_singleBeatRsp` 说明
**没命中任何从口的地址会走一条"假响应"分支**（返回一笔错误响应，不是死等）。
所以 `0x0–0xFFF` 既不是 RAM 也不是 DDR，写它只会拿到总线错误——**别把向量表/栈放那儿**。

### 1.3 物理 DDR 到底多大（我为什么写 256MB）

`rtl\ddr3_controller\ddr3_parameter.vh`：

```
:6  `define BANK_WIDTH   3      // 8 banks
:7  `define ROW_WIDTH    14     // 16384 rows
:8  `define COL_WIDTH    10     // 1024 columns
:11 `define DQ_WIDTH     16     // 16-bit data bus
:15 `define DRAM_WIDTH   8      // x8 devices
```

单颗容量 = 2^3 × 2^14 × 2^10 × 8 bit = 1 Gbit = 128MB；
16 位数据总线用 2 颗 x8 颗粒并排 ⇒ **256MB**。

> **推断**（有依据但不是直接读到的）：这是从控制器几何参数反推的，没有读到板上 DDR3 颗粒丝印。
> **怎么证实**：① 看板卡原理图/实物颗粒型号（资料包 `参考资料\_zip_extract\Ti60F225A_V4_SCH.pdf.txt`）；
> ② 上板后用固件对 `0x0F000000 / 0x10000000 / 0x20000000` 做"写-读-反码-读"测试，
> 能过的最大地址就是真实容量。**在证实之前，按 256MB 规划是最保险的**
> （比按 3.5GB 规划安全得多：越界访问在 DDR3 控制器上的行为没人保证）。

### 1.4 和现有固件的关系

- 现在固件链接在片内 RAM：`sw\link.ld:39` `RAM (rwx) : ORIGIN = 0xF9000000, LENGTH = 32K`，
  由 `sw\hex2soc.ps1` 直接把 `.bin` 灌进 SoC 的 RAM 初始化文件 ⇒ **上电就跑固件，没有 DDR 参与**。
- 要"跑在 DDR 里"，固件必须由一个**跑在片内 RAM 里的 bootloader** 搬进去，
  因为 FPGA 配置阶段只能初始化片内 RAM（`binGen.py` 生成的就是那 4 个
  `EfxSapphireSoc..._ram_symbol*.bin`），**DDR 的内容无法由位流预置**。

---

## 2. `bootloader_124K.hex` vs `LDSize=16380` 疑点：查清了

### 2.1 `LDSize` 到底是什么（先把它和 bootloader 解耦）

从 IP 参数定义（`D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\ipm\component.pickle`）里读出的原文：

- 显示名：`LDSize`；描述：**"Application Region Size" / "Modify linker script's memory region size for application"**；
- 可选值：124 / 252 / 508 / 1020 / 2044 / 4092 / 8188 / **16380** / 32764 / 65532 / 131068 / 262140
  （GUI 上显示为 124KB / 252KB / … / **16MB** / 32MB …）；
- 约束：`enable = (${DDR} == 1)`，且 checker `(${LDSize}*1024) < ${DDRSize}`。

生成器里它**只在一个地方被用**——`D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\embedded_sw\sw_script.py:602-604`：

```python
elif ddrChoice == '1':
    line = line.replace(': 4K', f': {ldStackSize}K')
    line = line.replace('= 124K', f'= {ldSize}K')     # ← 只改链接脚本里的 MEMORY LENGTH
```

也就是说：**`LDSize=16380` ⇒ 生成的 `default.ld` 变成 `ORIGIN = 0x00001000, LENGTH = 16380K`。
它跟"用哪个 bootloader hex"一点关系都没有。**
（`LDSize=16380` 本身是合法值，正好对应 GUI 里的 16MB，不是非法残留。之前那种
"DDR=0 时残留的 LDSize=124"的困惑在这一版 IP 里已经不存在了——现在 DDR=1。）

### 2.2 bootloader 变体是怎么选的 + 那支 124K 到底搬多少

生成器 `D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\generator\soc_gen.py:781-792`：

```python
"""
Step 2: Target correct bootloader hex
"""
if (ddrChoice == '1' and spi0_en == '1'):
        binfile='bootloader_124K.hex'          # ← DDR + 有 SPI0 时，硬编码 124K
else:
        binfile='bootloader_'+str(i_ocrSize)+'K.hex'   # 非 DDR：按片内 RAM 大小选
```

所以这不是"回落分支"，是**设计好的 DDR 分支**：DDR 模式下生成器**永远**塞 124K 那支。
`i_ocrSize` 是 `OCRSize/1024`（`:740-741`），我们 OCRSize=32768 ⇒ 32000，而
`generator\bootloader\` 里根本没有 32000K 的文件（只有 1K…512K），所以
「按片内 RAM 选」那条分支在 DDR 模式下本来就走不通——这也解释了为什么厂商要硬编码一支。

**关键问题：那支 124K 的 bootloader 一次搬多少字节？** 只能反汇编（hex 是预编译产物，没有源码）。

用本机工具链把它还原成二进制再反汇编（**实测**，命令可复现）：

```powershell
$tc="D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
& "$tc\riscv-none-elf-objcopy.exe" -I ihex -O binary `
  "D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\generator\bootloader\bootloader_124K.hex" "$env:TEMP\bl_124K.bin"
& "$tc\riscv-none-elf-objdump.exe" -D -b binary -m riscv:rv32 -M no-aliases,numeric "$env:TEMP\bl_124K.bin"
```

`bootloader_124K.hex` 的全部代码只占 `0xF9000000–0xF9000332`（818 字节）。搬运用循环：

| 地址 | 指令 | 含义 |
|---|---|---|
| `0x22c` | `lui x11,0x10` + `addi -1` | 掩码 0xFFFF |
| `0x238` | `lui x13,0x1` | **目标指针 = 0x00001000** |
| `0x240` | `addi x16,x0,512` | 写 SPI 数据寄存器的值（bit9=收/发标志） |
| `0x244` | `lui x10,0x20` | **循环结束地址 = 0x00020000** |
| `0x254 / 0x258 / 0x264 / 0x26c` | 写→等→读 SPI，`sb` 到目标 | 逐字节搬运 |
| `0x270` | `beq x15,x10,0x27c` | 目标+1 == 0x20000 就收工 |
| `0x27c-0x2a0` | 关 SPI，`jalr x0,0(x6)`，`x6=0x1000` | **跳到 0x00001000** |

即：**搬 `0x20000-0x1000 = 0x1F000 = 126,976 字节 = 124KB`，然后跳 0x1000。**

源地址也在同一段代码里——发送给 SPI 的字节序列是 `0x1AB, 0x1E9, 0x10B, 0x138, 0x100, 0x100, 0x100`
（每个值低 8 位才是真命令/数据，高位 `0x100` 是"启动这次传输"的标志 —— 这一点属**推断**）：

- `0xAB` = SPI flash「Release from Power-Down」；
- `0xE9` = 「Exit 4-Byte Address Mode」；
- `0x0B` = 「Fast Read」；
- `0x38, 0x00, 0x00` = 24 位地址 = **flash 0x00380000**。

这与官方 demo 的 bootloader 源码完全对上
（`_ddr_demo_ti60\embedded_sw\soc\software\standalone\bootloader\src\bootloaderConfig.h:17-19`）：

```c
#define USER_SOFTWARE_MEMORY 0x00001000     // 目标
#define USER_SOFTWARE_FLASH  0x00380000     // 源
#define USER_SOFTWARE_SIZE   0x01F000       // 0x1F000 = 124KB ← 与反汇编一致
```

再到 flash 布局报告 `_ddr_demo_ti60\outflow\soc_combine_hex.rpt:5-7`：

```
Flash Address  Length      Input Image File
0x00000000     0x0009e8ee  ddr_demo_ti60.hex          ← 位流
0x00380000     0x00000a2a  gpioDemo.bin               ← 用户软件
```

**结论：`bootloader_124K.hex` = 「从 flash 0x380000 搬 124KB 到 DDR 0x1000 后跳过去」。**

### 2.3 一致性判定

| 事实 | 值 | 结果 |
|---|---|---|
| 声明给链接器的应用区（LDSize） | 16380K = 16MB（0x1000 … 0x01000000） | 允许固件很大 |
| 实际 bootloader 一次能载入的量 | 124KB（0x1000 … 0x20000） | 固件只能很小 |
| **一致性** | **不一致：应用区声称 16MB，实际只有 124KB 会被载入** | ❌ |

**后果（很重要）**：如果固件按 DDR 链接（`ORIGIN=0x1000, LENGTH=16380K`）编出 300KB，
链接器**不会报错**（LENGTH 够大），烧进 flash 之后 bootloader 只搬 124KB 就跳过去——
CPU 从 `0x1000` 开始跑，跑到 124KB 之外就执行到 **DDR 里没被初始化的数据**。
这类"链接通过、上板乱飞"是最难查的故障，必须提前堵住。

### 2.4 正确做法（官方参考设计就是这么干的）

`D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\ip\SapphireSoc\settings.json`：

```json
:16  "HexFile_PathEnable": "1'b1",
:17  "HexFile_Path": "\"ref_files/bootloader_16MB/SapphireSoc/bootloader.hex\"",
:20  "LDSize": "16380",
:74  "DDR": "1'b1",
:79  "OCRSize": "4096",
```

**厂商自己的 TinyML 参考设计：`LDSize=16380` 的同时，显式指定了 16MB 的 bootloader**
（文件就在 `...\ref_files\bootloader_16MB\SapphireSoc\bootloader.hex`，4838 字节）。
我们的 `ip\sapphire_soc\settings.json:16-17` 现在是：

```json
:16  "HexFile_PathEnable": "1'b0",
:17  "HexFile_Path": "\"''\"",
```

⇒ 也就是**没覆盖**，生成器就按 `soc_gen.py:784` 塞了 124K 那支。修法见下面 §2.5。

把 16MB 那支也反汇编一遍（**实测**），确认它搬 16MB：

```
5d0: lui  x14,0x1000    → a4 = 0x01000000   （长度 = 16MiB）
5d4: lui  x13,0x1       → a3 = 0x00001000   （目标 DDR 地址）
5d8: lui  x12,0x380     → a2 = 0x00380000   （源 flash 地址）
5dc: addi x11,x0,0      → a1 = 0            （CS = 0）
5e0: lui  x10,0xf8014   → a0 = SPI0 基址 0xF8014000
5e4: jal  x1,0x530      → spiFlash_f2m(SPI, 0, 0x380000, 0x1000, 0x1000000)
5e8: lui  x15,0x1
5ec: jalr x1,0(x15)     → 跳 0x00001000
```

⇒ **16MB bootloader = 从 flash `0x380000` 搬 16MiB（0x10000000 字节）到 DDR `0x00001000`，跳 0x1000。**
搬运窗口 = `0x00001000 … 0x01000FFF`（末字节 `0x01000FFF`）。

> 这也解释了官方 TinyML 固件里那两个"奇怪"的常量为什么正好在 0x01000000 之上：
> `.../evsoc_tinyml_pdti8/src/main.cc:65` `#define BUFFER_START_ADDR 0x01100000`、
> `:67` `#define TINYML_INPUT_START_ADDR 0x01600000`，
> 并且注释写着 "BUFFER_START_ADDR should not overlap with memory space allocated for RISC-V
> program (default.ld)"。**厂商自己也是把缓冲区放在"搬运窗口之外"** —— 与本方案的 §3 内存图同思路。

### 2.5 修法（重新生成 SoC IP 时该传什么）

**做法 A（推荐，和官方一致）**：在 IP Manager 的 SoC 配置里勾选 "use custom RAM init hex"，
或者直接改 `ip\sapphire_soc\settings.json`：

```json
"HexFile_PathEnable": "1'b1",
"HexFile_Path": "\"ref_files/bootloader_16MB/SapphireSoc/bootloader.hex\"",
```

（路径可以自己放；只要 `HexFile_PathEnable=1`，`soc_gen.py:800-803` 就会用你给的文件，忽略
`:784` 的 124K 分支。）建议把厂商那份
`D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\ref_files\bootloader_16MB\SapphireSoc\bootloader.hex`
**拷贝一份到工程内**（例如 `D:\FPGA\mmt\sw\ddr\bootloader_16MB.hex`，本目录就是我的写权限范围）再引用绝对路径，
免得依赖 `D:\FPGA\tinyml\` 这个外部目录。

**做法 B（想省启动时间）**：自己编一支"搬 4.5MB"的 bootloader。
源码在厂商 BSP `.../software/standalone/bootloader/`（真正干活的就 `bootloaderConfig.h` 里
`spiFlash_f2m(SPI, SPI_CS, USER_SOFTWARE_FLASH, USER_SOFTWARE_MEMORY, USER_SOFTWARE_SIZE)`
一行），把 `USER_SOFTWARE_SIZE` 改成 `0x460000`，用 `riscv-none-elf-gcc` 编到 `0xF9000000`
（链接脚本 `.../linker/bootloader.ld:7` `ORIGIN = 0xF9000000, LENGTH = 4K`），
再用 `binGen.py -b bootloader.bin -f 0 -s 32768` 生成 4 个 ram_symbol 文件。
**注意**：本工程 IP 目录下**没有**生成 BSP（`ip\sapphire_soc\source\` 只有 `hardware\` 和 `soc_config`），
要从官方 demo 的 `embedded_sw\soc\bsp` 拷一份并按我们的 SoC 参数重新生成，工作量明显大于做法 A。

**做法 C（不改 IP，只做实验）**：不做 flash 启动，直接用调试器把 ELF 写进 DDR 再放 CPU 跑。
适合开发期（见 §5.3）。

> ⚠️ **两条路不能同时要**：`hex2soc.ps1 -Install` 会把固件 `.bin` 灌进同一批
> `ram_symbol*.bin`（`sw\hex2soc.ps1:150-157`，注意它要改**两个位置**的副本）。
> 一旦用了 bootloader，片内 RAM 里必须放 **bootloader**，不能再放固件。
> 也就是说：
> - 「固件固化在片内 RAM，上电直接跑」←→ 现有 `sw\link.ld` + `hex2soc.ps1 -Install`；
> - 「固件在 DDR 里跑」←→ RAM init 放 bootloader + flash 放固件镜像 + 新的 `sw\ddr\link_ddr.ld`。
> **二选一，别混。**

---

## 3. 建议的 DDR 内存图

### 3.1 前置约束（每一条都决定了图里的一条边）

| # | 约束 | 依据 |
|---|---|---|
| C1 | DDR 从 `0x00001000` 开始；`0x0–0xFFF` 不可用 | §1.2 |
| C2 | 所有地址 < 256MB（`0x10000000`） | §1.3（推断，但必须遵守） |
| C3 | bootloader **无条件**把 flash `0x380000` 起 16MB 覆盖写到 DDR `0x00001000–0x01000FFF` | §2.4 反汇编 |
| C4 | flash 只有 8MB；用户镜像固定从 `0x380000` 起 ⇒ 镜像 ≤ 4.5MB | `参考资料\_目录说明.md:67`、`..._DEMO板软硬件设计说明...pdf.txt:124`（GD25LQ64） |
| C5 | 视频帧缓存已搬到 `0x02000000`，3 bank 到 `0x02BDDDFF` | `rtl\mmt\mmt_top.v:661`、`协作日志.md:1927` |

C3 和 C4 合起来推出一个**很容易踩的坑**：镜像装不满 16MB 时，bootloader 会**继续读 flash**——
读到超过闪存实际容量的部分，拿到的是未定义内容，然后被写进 DDR。
所以 DDR `0x00480000–0x01000FFF`（镜像真实末尾之后到搬运窗口末尾）里是**垃圾，禁止使用**。

### 3.2 内存图（建议值）

| 区 | 起始 | 结束（含） | 大小 | 谁写 | 说明 |
|---|---|---|---|---|---|
| **R0** | `0x00000000` | `0x00000FFF` | 4KB | — | **解码空洞，禁止使用**（C1） |
| **R1 app 区** | `0x00001000` | `0x000FFFFF` | 1020KB | 16MB bootloader 从 flash `0x380000` 拷入 | 固件 `.text/.rodata/.data/.bss/heap/stack`；`sw\ddr\link_ddr.ld` 就锁在这里 |
| **R2 模型权重区** | `0x00100000` | `0x0047FFFF` | 3.5MB | 同一次拷贝（flash `0x47F000` 起） | 权重文件原样落在这里，固件直接按 `0x00100000` 读 |
| **R3 未定义残留区** | `0x00480000` | `0x01000FFF` | ≈11.5MB | bootloader 越界读 flash 的垃圾（C3/C4） | **禁止使用**（放东西会被启动过程覆盖） |
| **R4 备用区** | `0x01001000` | `0x01FFFFFF` | ≈16MB | RISC-V | 搬运窗口之外的第一段空闲区，可做调试缓冲 |
| **R5 视频帧缓存** | `0x02000000` | `0x02BDDDFF` | ≈11.9MB | `frame_buffer` 的 AXI 主口（硬件） | 现状不动（C5） |
| **R6 帧缓存余量** | `0x02BE0000` | `0x02FFFFFF` | 128KB | — | 对齐/保险；帧缓存若日后加 bank 先吃这里 |
| **R7 张量/激活区** | `0x03000000` | `0x03FFFFFF` | 16MB | RISC-V 写、加速器 DMA 读写 | TinyML 输入/输出/中间张量；**必须 8 字节对齐**（见 §4.4） |
| **R8 其余物理 DDR** | `0x04000000` | `0x0FFFFFFF` | 192MB | 备用 | 第二块张量/双缓冲、大图缓冲等 |

**逐条检查（都过）**：

- 互不重叠：R1 尾 `0x000FFFFF` < R2 头 `0x00100000` ✓；R2 尾 `0x0047FFFF` < R3 头 ✓；
  R4 尾 `0x01FFFFFF` < R5 头 `0x02000000` ✓；R5 尾 `0x02BDDDFF` < R7 头 `0x03000000` ✓；
- 都在解码窗口内：最小 `0x1000 ≥ 0x1000` ✓，最大 `0x0FFFFFFF < 0xE0001000` ✓；
- 都在物理 DDR 内（<`0x10000000`）✓；
- **关键：R5（帧缓存）和 R7（张量）都在搬运窗口 `0x01000FFF` 之上**，
  启动时不会被 bootloader 的 16MB 覆盖写碰到 ✓；
- flash 预算：R1+R2 = 1020K + 3.5MB = 4,608,000 字节 = 0x465000 ≤ 4.5MB(0x480000) ✓，
  镜像在 flash 里占 `0x380000–0x7FF000`，末地址 `0x7FEFFF < 0x800000` ✓ **刚好塞进 8MB**。

> 若以后模型大于 3.5MB：把 R1 缩到 508KB（0x1000…0x7FFFF，558KB 也够现在 3KB 的固件很多倍），
> 把 R2 扩到 `0x00080000–0x0047FFFF`（4MB）。**改了两个地方必须同步**：
> `sw\ddr\link_ddr.ld` 的 `LENGTH` 和 `sw\ddr\pack_image.ps1` 的 `-AppRegion`。
> 打包脚本会在超容量时直接报错退出（已实测，见 `sw\ddr\README.md`）。

### 3.3 和"最终目标"的对应关系

| 目标里的说法 | 对应上表 |
|---|---|
| 固件放 DDR 运行 | R1（+ 启动方式见 §5） |
| 模型（权重）放 DDR | R2 |
| 输入/输出张量放 DDR | R7（如 TFLite-Micro 的 arena 也可直接开在 R2/R7，见 §4.4） |
| 视频帧缓存 | R5（已实现） |

---

## 4. 模型进 DDR 的可执行步骤

**先说清楚一件事**：位流只能初始化**片内 RAM**，**DDR 不可能由位流预置**。
所以"模型进 DDR"只有三种机制，选一种：

| 路线 | 谁把模型搬进 DDR | 要不要写代码 | 适合 |
|---|---|---|---|
| **A（推荐）** | bootloader（和固件一起，一次搬完） | 不用 | 最终形态 |
| B | 固件自己用 SPI 驱动从 flash 另一段搬 | 要（SPI flash 驱动 + 搬运循环） | 权重不随固件重新打包时 |
| C | 调试器（JTAG/openocd）直接写 DDR | 不用 | 开发期快速验证 |

### 4.1 路线 A：权重拼在固件后面，一次搬完（推荐）

**原理**：bootloader 只会搬"一个连续镜像"，所以我们在 PC 上把
`[固件.bin][填充][权重.bin]` 拼成一个文件，烧到 flash `0x380000`。
bootloader 搬完 16MB 后，固件在 `0x1000`，权重正好在 `0x00100000`（R2）。

**步骤（外行也能照做）**：

1. **改 SoC IP 的 bootloader（一次性）**——按 §2.5 做法 A：
   `ip\sapphire_soc\settings.json` 里 `HexFile_PathEnable=1'b1`、`HexFile_Path` 指向 16MB
   bootloader，然后**重新生成 SoC IP**（这一步要跑 Efinity IP 生成，由 Lead 执行）。
   重新生成后确认 `ip\sapphire_soc\source\soc_config:1` 里的 `--ramHex` 已经**不是**
   `bootloader_124K.hex`。
2. **用 DDR 链接脚本链固件**（已实测通过，见 `sw\ddr\README.md`）：
   把 `sw\build_sw.ps1` 里的 `-T (Join-Path $sw "link.ld")` 临时换成
   `sw\ddr\link_ddr.ld`，输出仍旧 `sw\build\mmt_fw.elf/.bin`。
   （`sw\build_sw.ps1` 属于**别人**的写权限，我不改；Lead 决定是否切换。）
3. **准备权重文件**：把 TinyML 模型权重量化成 `.bin`，放到
   `sw\ddr\weights\<model>.bin`。**要求**：
   - 文件里**不能有地址信息**（是纯数据流，不是 ELF/hex）；
   - 若模型是 C 数组（厂商 TinyML demo 的做法：
     `.../evsoc_tinyml_pdti8/src/model/mobilenetv1_person_detect_model_data.cc`），
     就用 `objcopy -O binary --only-section=.rodata` 之类的方式抽出来，或者干脆在 PC 上
     用脚本把数组转成二进制。
4. **打包并自检**：

   ```powershell
   powershell -File D:\FPGA\mmt\sw\ddr\pack_image.ps1 `
       -App D:\FPGA\mmt\sw\build\mmt_fw.bin `
       -Weights D:\FPGA\mmt\sw\ddr\weights\model.bin `
       -Out D:\FPGA\mmt\sw\ddr\build\ddr_image.bin
   ```

   期望输出（格式已实测）：
   ```
   app 区    : 1044480 bytes，DDR 0x00001000 .. 0x000FFFFF
   权重落点  : DDR 0x00100000 .. 0x00161A7F
   镜像总长  : 1444480 bytes / flash 预算 4718592 bytes
   自校验    : OK
   ```
5. **烧 flash**（Efinity Programmer，两次写、两个地址）：
   - 位流 `outflow\mmt.hex` → **flash `0x000000`**（SPI Active 模式）；
   - `sw\ddr\build\ddr_image.bin` → **flash `0x380000`**。
   （与官方 demo 的说明完全一致：`07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\readme.txt:75,84`；
   也可以用 Efinity 的 soc_combine_hex 把两段合成一个文件一次烧，
   格式参照 `_ddr_demo_ti60\outflow\soc_combine_hex.rpt`。）
6. **上电**：FPGA 配置完 → SoC 从 `0xF9000000` 跑 bootloader → 搬 16MB → 跳 `0x1000` → 固件在 DDR 里跑。
7. **固件里怎么用权重**：直接引用 `sw\ddr\link_ddr.ld` 提供的符号
   `mmt_weights_base`（= `0x00100000`）和 `mmt_weights_limit`，例如：

   ```c
   extern const unsigned char mmt_weights_base[];   /* 链接脚本里 PROVIDE 的地址符号 */
   const void *w = (const void *)mmt_weights_base;
   ```

   **不要**在 C 里硬编 `0x00100000`，否则内存图一改就两边不一致。

### 4.2 路线 B：权重单独烧在 flash 另一段，固件自己搬

适用：权重更新频繁、不想每次重打整个 1MB+ 镜像。
- flash 布局改成：位流 `0x0`、固件镜像 `0x380000`（小，只放 app 1MB 区）、权重 `0x500000` 起（示例值，须与你实际镜像长度错开）。
- 固件里需要 **SPI flash 驱动**。本工程现在**没有**（`sw\` 下只有 `main.c/uart.c`）。
  可直接从厂商 BSP 移植：`_ddr_demo_ti60\embedded_sw\soc\software\standalone\driver\spiFlash.h`（36KB，纯头文件实现），
  SPI 控制器基址 `0xF8014000`（`soc_config:34` `--spi address=0x014000` + `--apbBridgeAddress 0xf8000000`）。
- 搬完必须刷 D-cache（§4.4）。
- **代价**：多几十 KB 固件 + 一个新的驱动风险点。除非有明确需求，否则选 A。

### 4.3 路线 C：调试器直接写 DDR（开发期）

- 用 `openocd` + gdb 把 `mmt_ddr.elf` 的段直接 load 到 DDR（`0x1000` 起），并把权重 `load` 到 `0x00100000`，
  然后把 PC 设到 `0x1000` 放跑。厂商 BSP 里有现成的 openocd 配置
  （`_ddr_demo_ti60\embedded_sw\soc\bsp\efinix\EfxSapphireSoc\openocd\*.cfg`）。
- **前提**：片内 RAM 里得先有一支能被调试器中断的 bootloader（或者直接用 `binGen.py` 生成的
  RAM 初始化内容），并且 SoC 的 debug 端口接上了。**这一条我没有实测条件，属"可行路径"而非已验证步骤**，
  列出来是因为它是验证 DDR 链接脚本/启动流程最快的手段。

### 4.4 两条"必踩"的坑（提前写在这里）

1. **D-cache 一致性**：DDR 在 Sapphire 里是**可缓存**的。
   `ip\sapphire_soc\sapphire_soc.v:17905`
   `DBusCachedPlugin_mmuBus_rsp_isIoAccess = ((addr & ~0x00ffffff)==0xf8000000) || (==0xe1000000)`
   —— **只有 `0xf8000000`/`0xe1000000` 两个 16MB 区被当作非缓存 IO**，DDR 不在其中。
   所以：**CPU 写完权重/输入张量后、硬件加速器（或 DMA）去读之前，必须刷新 D-cache**；
   反向（硬件写完、CPU 去读）要先失效/刷新。
   厂商 TinyML 固件的做法是自定义指令：
   `asm(".word(0x500F)")`（`.../evsoc_tinyml_pdti8/src/main.cc:156-158`；
   调用点 `:176`、`:196`、`:371`）。我们 SoC 的 `--customInstruction true`
   （`ip\sapphire_soc\source\soc_config:15`）已开，同一条指令可用。
   **待验证**：VexRiscv 的这条自定义指令在我们的配置（`iCacheWays=1/dCacheWays=1` 都是 1 路）
   下的确切语义要实测确认（见 §7）。
2. **DMA/加速器的地址对齐**：厂商 TinyML 固件注释明确写了
   "Start address to be divided evenly by 8. Otherwise DMA tkeep might be shifted"
   （`main.cc:63-64`）。我们的 R7 张量区取 `0x03000000`（8 字节对齐 ✓），
   里面每个张量起始也要按 8 字节（更保险 128 字节）对齐。

### 4.5 关于 TFLite-Micro 的 tensor arena

厂商 TinyML demo 把 136KB 的 arena 直接开成 C 全局变量
（`main.cc:86-87`），也就是**跟着固件一起进了 app 区**，没有单独占一块 DDR 区。
我们的方案里 R7 是给"硬件加速器版"的 TinyML 用的；如果最终走的是 **CPU 上跑 TFLite-Micro**
（跟厂商一样），那么 arena 放 app 区的 `.bss` 即可，R7 可空着。
**两条路线不要同时占 R7**，否则会出现"arena 和张量互相踩"的鬼故事。

---

## 5. 落地顺序（分三阶段，每阶段都有可验收点）

> 遵守硬性规矩：**Efinity 流程（efx_map/efx_pnr/build.ps1）由 Lead 独占**，
> 下面凡涉及"重新生成 IP / 综合 / 布线 / 生成位流"的步骤都由 Lead 执行；
> 我只产出改什么、怎么验。

### 阶段 1：不改硬件，先把软件侧能验的验掉（**已在本轮完成**）

| 项 | 状态 | 产物 |
|---|---|---|
| DDR 版链接脚本能链出固件、符号全在 `0x1000–0x100000` | ✅ 已实测（LINK EXIT 0，`_start=0x1000`） | `sw\ddr\link_ddr.ld`、`sw\ddr\_test_build\mmt_ddr.{elf,map,bin}` |
| 镜像打包脚本 + 容量红线 + 自校验 | ✅ 已实测（3 个分支） | `sw\ddr\pack_image.ps1` |
| 内存图与帧缓存不重叠 | ✅ 纸面校验（§3.2） | 本文档 |

### 阶段 2：换 bootloader + 确认位流能塞进 flash 前半段（**Lead**）

1. 拷 16MB bootloader 进工程，改 `ip\sapphire_soc\settings.json` 的
   `HexFile_PathEnable/HexFile_Path`（§2.5），重新生成 SoC IP；
   验收：`ip\sapphire_soc\source\soc_config:1` 的 `--ramHex` 不再是 `bootloader_124K.hex`，
   且 `ip\sapphire_soc\*.bin` 四个 ram_symbol 文件里含 bootloader（818/1698 字节级的镜像）。
2. **量一下位流大小**：本工程 `outflow\` 目前**只有 map/pnr 报告，还没有 `.bit`/`.hex`**
   （我查过：`D:\FPGA\mmt\outflow` 里没有 `.bit`/`.hex`）。位流必须 < `0x380000`（3.5MB），
   否则 flash 布局要重排（改用 JTAG 加载位流，flash 只放固件）。
   验收：`Get-Item outflow\mmt.hex` 的 Length < 0x380000。
3. 重跑 Efinity 流程，确认 IP 替换后时序/资源没有意外变化。

### 阶段 3：上板（Lead + 硬件）

1. 先用 `pack_image.ps1` **只装固件**（`-Weights` 留空）烧一次，
   验证："bootloader 能起来 + 固件能在 DDR 里跑 + UART 有输出"。
   最省事的验收方法：在固件里打印一个只有 DDR 版本才会打印的标记，
   并读一次 `0x00100000`（此时是填充值 0x00）自证在 DDR。
2. 再加权重，验证固件能从 `0x00100000` 读出正确的权重头（例如比对前 16 字节）。
3. 最后接 TinyML 加速器通路，验证 DMA 能从 R2/R7 读数据（注意 §4.4 的 flush）。

---

## 6. 链接脚本草案与校验方法

### 6.1 草案

文件：`D:\FPGA\mmt\sw\ddr\link_ddr.ld`（**新建，没有动 `sw\link.ld`**）。

要点：

- `MEMORY { APP (rwx) : ORIGIN = 0x00001000, LENGTH = 1020K }`
  —— 与 §3.2 的 R1 一致；`ORIGIN` 取 `0x1000` 是因为基址就是 `0x1000`（§1.2）；
- 保持 `sw\startup.S` 需要的三个符号：`_stack_top`、`_bss_start`、`_bss_end`
  （`sw\startup.S:23/26/27`），并保留 `KEEP(*(.text.start))` 在最前面；
- 用 `PROVIDE()` 导出内存图里的 DDR 绝对地址
  （`mmt_fb_base / mmt_fb_end / mmt_weights_base / mmt_weights_limit / mmt_tensor_base / mmt_tensor_limit`），
  C 代码 `extern` 引用即可，**避免各文件里散落 magic number**；
- 4 条 `ASSERT` 守卫：`_start ≥ 0x1000`（防止落进解码空洞）、
  `_bss_end / _stack_top / _end ≤ 0x00100000`（防止越过 1MB app 区踩到权重区）。
  **ASSERT 失败会直接让链接报错**，这是把 §2.3 那种"链接通过但上板乱飞"提前暴露的关键。

### 6.2 校验方法（三条，全都要做）

**（a）链接期**：不能有 `region APP overflowed`，且 4 条 ASSERT 全过。已实测通过。

**（b）符号落点**（实测输出）：

```
$tc\riscv-none-elf-nm.exe -n mmt_ddr.elf | Select-String "_start|_stack_top|_end"
00001000 T _start
000042a0 B _end
000042a0 B _stack_top
```
要求：全部落在 `0x00001000 ≤ x < 0x00100000`。

**（c）段表**（实测输出，`objdump -h`）：

```
Idx Name    Size      VMA       LMA
 0  .text   00000ae4  00001000  00001000
 1  .rodata 0000012d  00001ae4  00001ae4
 2  .bss    00000680  00001c14  00001c14
 3  .stack  00002000  000022a0  000022a0
```
要求：**没有任何一段的 VMA < 0x1000**（小于就是踩进了解码空洞）。

**（d）上板/仿真确认**（阶段 3 才有条件做，列在这里备查）：

| 要确认的事 | 怎么确认 |
|---|---|
| 真的在 DDR 里执行 | 固件读 `0x00100000`（权重区）应为填充值/权重头；读 `0xF9000000` 应为 bootloader 代码而不是自己 |
| bootloader 真的搬了 | 上电后用调试器读 DDR `0x1000` 前 4 字节，应等于 `objcopy` 出来的 `mmt_fw.bin` 前 4 字节 |
| 权重真的到位 | 固件把 `0x00100000` 起 16 字节经 UART 打印，与 PC 上 `Get-Content -Encoding Byte -TotalCount 16` 比对 |
| 帧缓存没被踩 | 启动后读 `0x02000000` 附近，确认不是 bootloader 搬进来的 flash 镜像内容 |
| D-cache 语义 | 写 `0x03000000` → 执行 `asm(".word(0x500F)")` → 用调试器（绕过 CPU 缓存）读同一地址，值应一致 |

---

## 7. 剩余不确定项（**没证实的一律列出，并给证实方法**）

| # | 不确定项 | 现状 | 怎么证实 |
|---|---|---|---|
| U1 | 物理 DDR 容量 256MB | **推断**（由 `ddr3_parameter.vh` 几何参数反推） | 查原理图颗粒型号（`参考资料\_zip_extract\Ti60F225A_V4_SCH.pdf.txt`）；或上板做地址位翻转测试 |
| U2 | 位流大小是否 < 3.5MB（flash `0x0–0x380000`） | **未知**，`outflow\` 尚无 `.bit/.hex` | 生成位流后量文件大小；超了就得改布局或只走 JTAG 加载 |
| U3 | 8MB flash 是否真的够装 16MB 搬运 | 会**越界读**，读到的内容未定义 | 上电后读 DDR `0x00480000–0x01000FFF` 看是不是垃圾；或干脆改小 bootloader 的搬运长度（§2.5 做法 B） |
| U4 | D-cache 自定义指令 `0x500F` 在我们配置下的语义 | 来自厂商 TinyML 固件用法，**未在我们工程实测** | 按 §6.2(d) 最后一行做一次"写→flush→旁路读" |
| U5 | `frame_buffer` 3 bank 的真实末地址 `0x02BDDDFF` | 引用 `协作日志.md:1927`，本轮**未逐位复核 RTL 例化计算** | 读 `rtl\frame_buffer\ddr_buffer.v` 里 `wr_start_addr/rd_start_addr` 的生成逻辑，或上板读 `frame_info` 寄存器换算 |
| U6 | flash 烧写是否需要把位流和镜像合成一个文件 | 厂商 demo 是合成（`soc_combine_hex.rpt`）；分开烧两段也可行 | 用 Efinity Programmer 分两次烧先试；不行再合成 |
| U7 | TinyML 加速器 DMA 从 DDR 读权重的**对齐/突发要求** | 只从厂商注释得知"起始地址要 8 字节对齐" | 读 `ip\tinyml\` 的寄存器手册/源码，或仿真里观察 `araddr/arlen` |

---

## 8. 一页速查（给"照着做"的人）

```
地址速记
  0x0-0xFFF        禁用（解码空洞）
  0x1000           固件入口（bootloader 跳这里）
  0x100000         模型权重起始
  0x480000         权重区结束（含）——之后到 0x1000FFF 是启动垃圾区，禁用
  0x2000000        视频帧缓存（RTL，硬件写）
  0x3000000        TinyML 张量区
  上限 0x10000000  物理 DDR 边界（256MB）

flash 速记
  0x000000         位流 mmt.hex（必须 < 0x380000）
  0x380000         用户镜像 ddr_image.bin（= 固件 + 填充 + 权重，≤ 4.5MB）

要改的（按顺序）
  1) ip\sapphire_soc\settings.json : HexFile_PathEnable=1'b1, HexFile_Path=<16MB bootloader>   → Lead 重新生成 IP
  2) sw\build_sw.ps1 : -T 换成 sw\ddr\link_ddr.ld                                             → Lead 决定
  3) 权重 .bin 放 sw\ddr\weights\，跑 sw\ddr\pack_image.ps1 打包（含自校验）
  4) Efinity Programmer：位流→0x0，ddr_image.bin→0x380000
  5) 上电，UART 应打印固件标记；读 0x100000 校验权重

两个必记的坑
  · DDR 可缓存：CPU 写完 → 刷 D-cache（.word(0x500F)）→ 硬件才能读
  · 权重地址别硬编，用 link_ddr.ld 导出的 mmt_weights_base

别碰
  · 0x0-0xFFF（解码空洞）
  · 0x480000-0x1000FFF（bootloader 越界搬进来的垃圾）
```

---

## 附：本文档引用到的证据文件清单

| 文件 | 关键行 | 证明什么 |
|---|---|---|
| `D:\FPGA\mmt\ip\sapphire_soc\sapphire_soc.v` | `:11628` | DDR 基址 0x1000、窗口 0xE0000000 |
| 同上 | `:17905` | 只有 `0xf8000000`/`0xe1000000` 是非缓存 IO；DDR 可缓存 |
| 同上 | `:11673/11677/11693` | 未命中地址走 no-hit 错误响应 |
| 同上 | `:3582 / :3634-3690 / :11403` | `io_outputs_2` 确实接到 DDR |
| `D:\FPGA\mmt\ip\sapphire_soc\source\soc_config` | `:1` | 现在用的是 `bootloader_124K.hex` |
| 同上 | `:3 / :15 / :20 / :26 / :29 / :31` | ddrASize / customInstruction / axiAAddress / onChipRamSize / axiASize / onChipRamAddress |
| `D:\FPGA\mmt\ip\sapphire_soc\settings.json` | `:16-17 / :20 / :79-80` | 未覆盖 ramHex；LDSize=16380；DDRSize；OCRSize=32768 |
| `D:\FPGA\mmt\rtl\mmt\mmt_top.v` | `:661` | 帧缓存 START_ADDR = 0x02000000 |
| `D:\FPGA\mmt\rtl\ddr3_controller\ddr3_parameter.vh` | `:6-15` | 256MB 的几何依据 |
| `D:\FPGA\mmt\sw\link.ld` | `:39` | 现状：固件在片内 RAM 0xF9000000 |
| `D:\FPGA\mmt\sw\hex2soc.ps1` | `:150-157` | 固件灌进 ram_symbol（两个副本都要换） |
| `D:\FPGA\mmt\sw\startup.S` | `:23/26/27` | 新链接脚本必须提供的符号 |
| `D:\FPGA\mmt\sw\build_sw.ps1` | `:45` | 现在用 `-T sw\link.ld` |
| `D:\FPGA\易灵思\协作日志.md` | `:1927` | 帧缓存 3 bank 到 0x02BDDDFF 的搬迁记录 |
| `...\07_官方demo工程\_ddr_demo_ti60\ip\soc\soc.v` | `:11586` | 厂商同款解码（交叉验证） |
| `...\_ddr_demo_ti60\...\include\soc.h` | `:68-69` | `SYSTEM_DDR_BMB 0x1000` 官方宏 |
| `...\_ddr_demo_ti60\...\bootloader\src\bootloaderConfig.h` | `:17-19` | flash 0x380000 → mem 0x1000，size 0x1F000 |
| `...\_ddr_demo_ti60\outflow\soc_combine_hex.rpt` | `:5-7` | flash 布局：位流 0x0、用户软件 0x380000 |
| `D:\Efinity\2026.1\ipm\...\generator\soc_gen.py` | `:781-792` | bootloader 选型分支（DDR+SPI → 124K） |
| 同上 | `:800-803` | `HexFile_PathEnable=1` 时改用户指定 hex |
| `D:\Efinity\2026.1\ipm\...\embedded_sw\sw_script.py` | `:602-604` | LDSize **只**改链接脚本 LENGTH |
| `D:\Efinity\2026.1\ipm\...\efx_soc\ipm\component.pickle` | LDSize 段 | LDSize = "Application Region Size"，可选值表 |
| `D:\Efinity\2026.1\ipm\...\generator\bootloader\bootloader_*.hex` | — | 可用的 bootloader 变体（1K…512K）+ 124K 那支 |
| `...\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\ip\SapphireSoc\settings.json` | `:16-17/:20` | **官方正确做法**：LDSize=16380 + 指定 16MB bootloader |
| 同上 `ref_files\bootloader_16MB\SapphireSoc\bootloader.hex` | 反汇编 `0x5d0-0x5ec` | 16MB bootloader 的源/目的/长度 |
| 同上 `...\evsoc_tinyml_pdti8\src\main.cc` | `:63-70 / :86-87 / :156-158` | 缓冲区放在搬运窗口之外；arena 在 .bss；D-cache flush 指令 |
| `D:\FPGA\易灵思\参考资料\_目录说明.md` | `:67` | 板载 flash 8MB（GD25LQ64） |
| `...\参考资料\_zip_extract\TI60F225I3-V4 DEMO板软硬件设计说明-260813-1.pdf.txt` | `:124` | "板上的 flash 是 8MB，采用的是 GD25LQ64" |
| `...\07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\readme.txt` | `:75 / :84` | flash 烧写地址 0x0 / 0x380000 |
