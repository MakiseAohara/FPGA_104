# DDR 执行路径决策（"模型与固件放 DDR 运行"）

> 任务：task-7。写权限：`sw\ddr\` 与本文档。**没有碰** `rtl\`、`ip\`、`mmt.xml`、`constr\`、`sim\`、
> `docs\` 下已有文件、`sw\` 下已有文件。**没有跑 Efinity 流程**（efx_map / efx_pnr / build.ps1）。
>
> 全文约定：
> - **【实测】**= 本轮在本机真跑过命令/真读过网表，并给出 `文件:行` 或可复现命令与原始输出；
> - **【推算】**= 由实测数据算出来的（给出算式）；
> - **【推断】**= 有依据但没有直接证据，明确写出"怎么证实"；
> - 没有把握的一律写"**无法确认**"。

---

## 0. 一页结论

1. **推荐路线乙′：把"搬运器"当成一段普通 C 代码写在片内 RAM 里（自建 loader），由它把 flash 里的
   app+权重搬进 DDR，然后跳到 DDR 执行。** 本文档 §4 给出实现，§4.6 给出编译与验证实测结果。
   它不是"厂商 bootloader（甲）"，也不等于"固件留在片内 RAM（原路线乙）"——它同时做到了
   **固件在 DDR 跑** 和 **模型在 DDR**。
2. **8MB flash 下的 bootloader 结论：厂商现有 22 支 bootloader **没有一支匹配**。**
   【实测】只有两支会把数据搬进 **DDR**：`bootloader_124K.hex`（只搬 124 KiB，装不下我们 293.5 KiB 的模型）
   和官方 TinyML 参考设计那支 **16 MiB** 版（本板 flash 只有 8MB，源地址 `0x380000`+16MiB = `0x10380000`
   ⇒ **越界读约 12 MiB**）。其余 20 支 `bootloader_<N>K.hex` 全是**往片内 RAM 搬**的，而且 N≥48 的那些
   代码被链到 `0xF901xxxx` 以上、**超出我们 32KB 的片内 RAM，根本跑不起来**。详见 §2。
3. **重大发现（两条路线的共同前置条件）：本工程的 SoC SPI0 根本没接到 flash 引脚。**
   `rtl\mmt\soc\mmt_soc_subsystem.v:376-391` 把 SPI 的读输入接 0、写输出悬空；顶层没有 SPI 端口；
   Interface Designer 里没有这 4 根脚；**Efinity 自己的日志**打出
   `WARNING : No ports matched 'system_spi_0_io_sclk_write' / 'system_spi_0_io_ss'`
   （`out\efx_pnr.log:645/650/655/660`、`out\mmt.place.out:643-658`）。
   **不论走甲还是走乙′，都必须先补这一步（Lead 执行，RTL + 引脚 + 重跑流程）。** 改法见 §3。
4. 【实测】编译与尺寸：`loader.bin` **5896 字节**（片内 RAM 32768，余 26872）、`ddr_app.bin` **4148 字节**、
   带**真实模型**（`mobilenetv1_person_detect_model_data.bin`，300,568 B = 293.5 KiB）的 flash 镜像
   `ddr_image.bin` **304,780 字节** = 4.5MB 预算的 **6.5%**。两段都用真工具链
   `riscv-none-elf-gcc 15.2.0` 链接通过，地址守卫（`_start`、`_end`、段表）全过。
5. 【实测】镜像格式在 PC 上验过：`sw\ddr\verify_image.py` 复现 loader 的解析与边界检查 +
   CRC32 三重比对 + 模拟搬运，**18 项 PASS / 0 FAIL**。
6. 【推算】启动时间：SPI 16.67MHz 逐字节 Fast Read ⇒ 搬 304,780 字节 ≈ **0.146 s**；
   厂商 16MB bootloader 同样速率搬 16MiB ≈ **8.05 s**（差 55 倍）。

---

## 1. 现状与硬约束

| # | 事实 | 性质 | 证据 |
|---|---|---|---|
| C1 | 给 CPU 的 DDR 从 **`0x00001000`** 起，窗口 `0x1000 ≤ addr < 0xE0001000` | **实测** | `ip\sapphire_soc\sapphire_soc.v:11628` `assign logic_hitsS0_2 = ((32'h00001000 <= ...address) && (... < 32'he0001000));` |
| C2 | `0x0–0xFFF` 是**解码空洞**（no-hit 走错误响应），禁止放任何东西 | 实测 | `sapphire_soc.v:11673/11677/11693`（task-3 已查，本轮沿用） |
| C3 | 片内 RAM **`0xF9000000` / `0x8000` = 32KB**，复位向量 = `0xF9000000` | **实测** | `ip\sapphire_soc\source\soc_config:26`（`--onChipRamSize 0x8000`）、`:31`（`--onChipRamAddress 0xf9000000`）；窗口解码 `sapphire_soc.v:11594`（掩码 `~0x7fff`）；复位向量 `sapphire_soc.v:19462` `IBusCachedPlugin_fetchPc_pcReg <= 32'hf9000000;` |
| C4 | 板上 flash **8MB**（GD25LQ64） | **实测**（资料原文） | `D:\FPGA\易灵思\参考资料\_目录说明.md:67`「板载 flash 仅 **8 MB**（GD25LQ64）」；`参考资料\_zip_extract\TI60F225I3-V4 DEMO板软硬件设计说明-260813-1.pdf.txt:124`「板上的 flash是8MB，采用的是 GD25LQ64」、`:640` |
| C5 | FPGA 配置方式 = **SPI Active ×1**（位流从 flash 读），位流**开着压缩** | **实测** | `mmt.xml:204` `<efx:param name="mode" value="active" .../>`、`:205` `width=1`、`:213` `bitstream_compression=on`、`:220` `generate_hex=on` |
| C6 | 位流在 flash 里占的长度**远小于 `.hex` 文件大小**：同类 Ti60 设计，厂商工具报告 654,335 / 992,864 字节 | **实测** | `_ddr_demo_ti60\outflow\soc_combine_hex.rpt:6`（位流 `0x00000000` 长度 **`0x0009e8ee` = 649,454**，而 `ddr_demo_ti60.hex` 磁盘 1,963,005 字节）；tinyml demo `.hex` 3,971,456 字节 → 逐行解析出载荷 **992,864 字节** |
| C7 | SoC 的 DDR AXI4 主口**已经接进互联**（`s1`），互联下游是 `u_ddr3_top` | **实测** | `rtl\mmt\mmt_top.v:758`（`.s_axi_awvalid ({tml_awvalid, soc_ddr_awvalid, fb_awvalid})`）、`:1470`（`.ddrm_awvalid (soc_ddr_awvalid)`）；网表 `out\mmt.hier_util.rpt:165`（`+u_ddr3_top`）、`:362`（`+u_ddr_axi_ic`） |
| C8 | 视频帧缓存占 DDR `0x02000000`–`0x02BDDDFF` | **实测** | `rtl\mmt\mmt_top.v:661` `.START_ADDR (32'h02000000)`；`:321` 注释 |
| C9 | 目标模型（mobilenetv1 person detect int8）二进制 **300,568 字节 = 293.5 KiB** | **实测** | 从厂商 demo 的 `...\evsoc_tinyml_pdti8\src\model\mobilenetv1_person_detect_model_data.cc:25-23147` 逐字节还原（`sw\ddr\extract_model_bin.ps1`，输出 `sw\ddr\weights\mobilenetv1_person_detect_model_data.bin`） |

> **flash 布局的由来**：C5 说明 FPGA 从 flash 头开始配置，所以位流必须放 `0x0`；
> 厂商（bootloader 与 readme）把**用户镜像**固定放在 `0x380000`，于是"用户镜像预算"=
> `0x800000 - 0x380000` = **4,718,592 字节 = 4.5 MB**。
> 但请特别注意：**在路线乙′里 `0x380000` 不是硬件约束，只是我们沿用厂商习惯的选择**——
> 读 flash 的地址是我们自己代码里的常量（`mmt_ddr.h` 的 `MMT_FLASH_IMG_BASE`），想改就改两处。

---

## 2. 路线甲评估：厂商 bootloader 在 8MB flash 下能不能用？——**没有一支匹配**

### 2.1 怎么测的（可复现）

`bootloader_*.hex` 是**预编译产物**（源码里只有 `bootloaderConfig.h` 一处 `spiFlash_f2m(...)` 调用），
所以只能反汇编 + 解析 Intel HEX 的地址记录：

```powershell
$tc = "D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$src = "D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\generator\bootloader\bootloader_124K.hex"
& "$tc\riscv-none-elf-objcopy.exe" -I ihex -O binary $src "$env:TEMP\bl.bin"
& "$tc\riscv-none-elf-objdump.exe" -D -b binary -m riscv:rv32 -M no-aliases,numeric --adjust-vma=0xF9000000 "$env:TEMP\bl.bin"
```

另外用一个十几行的 Intel HEX 解析脚本（本轮写在命令行里，未落盘）读出每支的 `Min/Max` 地址与数据字节数——
**这一步很关键**：`bootloader_512K.hex` 用 `objcopy` 出来是 524,034 字节的大文件，但那是因为 hex 记录
中间有大段地址跳变，**真正的代码只有 858 字节**，且**不在 0xF9000000 附近**。

### 2.2 22 支 bootloader 的实测表

`generator\bootloader\` 共 20 支（1K…512K），另有 `generator\bootloader_mc\` 20 支（多核版，本工程
`--cpuCount 1` 用不上），再加官方 TinyML 参考设计的
`...\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\ref_files\bootloader_16MB\SapphireSoc\bootloader.hex`。

| 文件 | hex 数据字节 | 代码地址范围（**实测**） | 落在我们 32KB 片内 RAM（`0xF9000000–0xF9007FFF`）内？ | 搬运目标 |
|---|---|---|---|---|
| `bootloader_1K.hex` | 850 | `0xF9000000–0xF90003F9` | ✅ | 片内 RAM（同族，**推断**） |
| `bootloader_2K.hex` | 850 | `0xF9000000–0xF90006F9` | ✅ | 片内 RAM（**推断**） |
| `bootloader_4K.hex` | 858 | `0xF9000000–0xF9000F01` | ✅ | 片内 RAM（**推断**） |
| `bootloader_8K.hex` | 858 | `0xF9000000–0xF9001F01` | ✅ | 片内 RAM（**推断**） |
| `bootloader_16K.hex` | 858 | `0xF9003C00–0xF9003E6F` | ✅（贴 16KB RAM 顶部） | **片内 RAM `0xF9000000`（实测）** |
| `bootloader_24K.hex` | 858 | `0xF9000000–0xF9005F01` | ✅ | 片内 RAM（**推断**） |
| `bootloader_32K.hex` | 858 | `0xF9007C00–0xF9007E6F` | ✅（正好贴我们 RAM 顶） | **片内 RAM `0xF9000000`（实测）** |
| `bootloader_48K.hex` | 858 | `0xF9000000–0xF900BF01` | ❌ 超出 | 片内 RAM（**推断**） |
| `bootloader_64K.hex` | 858 | `0xF9000000–0xF900FF01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_80K.hex` | 858 | `0xF9000000–0xF9013F01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_96K.hex` | 858 | `0xF9000000–0xF9017F01` | ❌ | 片内 RAM（**推断**） |
| **`bootloader_124K.hex`** | 818 | `0xF9000000–0xF9000331` | ✅（连续，任何 ≥1KB RAM 都能跑） | **DDR `0x1000`，长度 `0x1F000`（实测）** |
| `bootloader_128K.hex` | 858 | `0xF9000000–0xF901FF01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_144K.hex` | 858 | `–0xF9023F01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_160K.hex` | 858 | `–0xF9027F01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_192K.hex` | 858 | `–0xF902FF01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_224K.hex` | 858 | `–0xF9037F01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_256K.hex` | 858 | `–0xF903FF01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_384K.hex` | 858 | `–0xF905FF01` | ❌ | 片内 RAM（**推断**） |
| `bootloader_512K.hex` | 858 | `0xF907FC00–0xF907FEFE` | ❌（**在 512KB RAM 的顶部**） | 片内 RAM（**推断**） |
| `ref_files\bootloader_16MB\...\bootloader.hex` | 1698 | `0xF9000000–0xF90006A1` | ✅ | **DDR `0x1000`，长度 `0x01000000` = 16 MiB（实测）** |

**"代码地址范围"就是判定能不能在我们 SoC 上跑的第一道闸门**：`bootloader_<N>K.hex` 这一族的代码
被链到"N KiB 片内 RAM 的顶部"，我们只有 32KB ⇒ **N ≥ 48 的全部出局**（哪怕它们本来也不往 DDR 搬）。

### 2.3 只有两支往 DDR 搬，参数如下（都是**实测**反汇编）

**（a）`bootloader_124K.hex`（= 本工程当前默认塞进片内 RAM 的那支）**

| 反汇编地址 | 指令 | 含义 |
|---|---|---|
| `0xF90000D8` | `addi x15,x0,427` → `0x1AB` | SPI flash 释放掉电 |
| `0xF900011C` | `addi x15,x0,489` → `0x1E9` | 退出 4 字节地址模式 |
| `0xF90001A8` | `addi x15,x0,267` → `0x10B` | Fast Read |
| `0xF90001C8` | `addi x15,x0,312` → `0x138` | 地址首字节 `0x38`（带 `0x100` "发起"标志）⇒ 源 **flash `0x00380000`** |
| `0xF9000238` | `lui x13,0x1` | 目标指针 = **DDR `0x00001000`** |
| `0xF9000244` | `lui x10,0x20` | 循环结束 = `0x00020000` ⇒ 长度 `0x1F000` = **126,976 B = 124 KiB** |
| `0xF9000294/0xF90002A0` | `lui x6,0x1` + `jalr x0,0(x6)` | 跳 **`0x00001000`** |

与厂商源码完全对上：`_ddr_demo_ti60\...\bootloader\src\bootloaderConfig.h:17-19`
（`USER_SOFTWARE_MEMORY 0x00001000` / `USER_SOFTWARE_FLASH 0x00380000` / `USER_SOFTWARE_SIZE 0x01F000`）。
⇒ 这正是 task-3 的结论，本轮**独立复现**。

**（b）官方 TinyML 参考设计的 16 MiB 版**

| 反汇编地址 | 指令 | 含义 |
|---|---|---|
| `0xF90005D0` | `lui x14,0x1000` | 长度 `0x01000000` = **16 MiB** |
| `0xF90005D4` | `lui x13,0x1` | 目标 = DDR `0x00001000` |
| `0xF90005D8` | `lui x12,0x380` | 源 = flash `0x00380000` |

**8MB flash 下的后果**：读窗口 = `0x380000 … 0x380000+0x1000000-1 = 0x1037FFFF`，
而 flash 只有 `0x000000–0x7FFFFF` ⇒ **越界 12 MiB**。
【推断】GD25LQ64 是 24 位地址器件，越界地址的高位被忽略 ⇒ 读回的是 flash 开头的**回绕内容**
（不是随机数），所以**功能上"能用"**（我们的镜像落在 `0x380000–0x7FFFFF` 这一段是读对的），
但代价是：**多搬 12 MiB 垃圾 + 启动慢 55 倍 + DDR `0x00480000–0x01000FFF` 被垃圾覆盖（该区永久禁用）**。
**怎么证实回绕**：上板后读 DDR `0x00480000` 附近，与 flash 开头（位流区）内容比对；或读 GD25LQ64 数据手册的地址位定义。

### 2.4 结论

> **8MB flash 下，没有任何一支现成 bootloader 匹配"app+权重 ≈ 304,780 字节放进 DDR"这个需求。**
> - 唯一"尺寸合适且能跑在我们 32KB RAM 上"的那支是 124 KiB —— **装不下 293.5 KiB 的模型**（差 2.4 倍）；
> - 唯一"搬得多"的那支要搬 16 MiB —— **比 flash 还大 2 倍**，虽然能跑但脏且慢（§2.3b）；
> - 其余 20 支要么往片内 RAM 搬（不是 DDR），要么代码本身超出我们 32KB RAM。

**甲仍然可用的三个边界条件**（将来若要回去走甲，照这个判据选）：

| 条件 | 走哪支 | 还需不需要重新生成 IP |
|---|---|---|
| app+权重 ≤ **124 KiB** | `bootloader_124K.hex`（**就是现在默认那支**，`ip\sapphire_soc\source\soc_config:1`） | **不需要**（生成器已经选了它）——只需接 SPI + 用 `sw\ddr\link_ddr.ld` 链 app + 镜像 ≤124KB |
| app+权重 ≤ **4.5 MB** 且能忍 ~8 s 启动 | 官方 16 MiB 版 | **需要**（`ip\sapphire_soc\settings.json:16-17` 的 `HexFile_PathEnable=1'b1` + `HexFile_Path` 指向它，再重新生成 SoC） |
| 想要正好 4.5MB 一次搬完、启动快 | **自建 bootloader** | 不需要改 IP，但要有 BSP —— 本工程 `ip\sapphire_soc\source\` 下**没有** `embedded_sw`/BSP（只有 `hardware\` 与 `soc_config`），得先从官方 demo 拷一份再按我们的参数重生成 |

> **我们选择第三条的"自己写"版本，但不依赖厂商 BSP**：直接写一个不依赖 BSP 的裸机 C 程序
> （只用 UART + SPI 两个寄存器窗口，都是本工程网表里核实过的），就是 §4 的路线乙′。
> 理由：**它同时绕开了"重新生成 IP"和"越界读 flash"两件事**，而代价只是几百行 C。

---

## 3. 两条路线的**共同前置条件**：SPI0 必须接到 flash 的 4 根引脚（Lead 执行）

这是本轮最重要的发现：**任务背景里"SoC 有一个 SPI 主口（bootloader 就是靠它读 flash 的）"这句话，
在本工程里目前是不成立的——SPI 控制器存在，但从没接到引脚上。**

### 3.1 四处独立证据（**全部实测**）

| # | 证据 | 说明 |
|---|---|---|
| 1 | `rtl\mmt\soc\mmt_soc_subsystem.v:376-391` | SoC 例化时 SPI0 **被端接**：`.system_spi_0_io_data_0_read (1'b0)` … `.system_spi_0_io_sclk_write ()`、`.system_spi_0_io_data_*_write ()`、`_writeEnable ()` 全悬空；`:391` 只把 `ss` 接到一个内部信号，而那个信号仅用于 `:476` 的"避免未用信号告警" |
| 2 | `rtl\mmt\mmt_top.v` 全文 grep `spi` | **0 处匹配** ⇒ 顶层没有 SPI 端口 |
| 3 | `constr\ti60f225_oob.peri.xml` / `ti60f225_oob.interface.csv` grep `spi` | **0 处匹配** ⇒ Interface Designer 里没有这 4 根脚 |
| 4 | **工具日志**：`out\efx_pnr.log:645/650/655/660`、`out\mmt.place.out:643-658` | `WARNING : No ports matched 'system_spi_0_io_sclk_write'`、`WARNING : No ports matched 'system_spi_0_io_ss'` —— 来自 `constr\ti60f225_oob.sdc:147-150` 的 4 条 `set_output_delay`。**这是工具亲口确认"这些端口不存在"** |

> 顺带发现（不属本任务，但会误导人）：`out\efx_pnr.log:641/644` 还有
> `No ports matched 'sdram_clk~CLKOUT~218~94'`、`No ports matched 'i_soc_clk~CLKOUT~1~31'`，
> 说明 `constr\ti60f225_oob.sdc:146-150` 这几条是从 OOB 参考设计继承来的**失效约束**
> （`i_soc_clk` 这个时钟名在本工程也不存在）。**建议 Lead 顺手清理**，否则接线之后这几条仍然不会生效。

### 3.2 需要怎么改（照抄厂商能跑通的设计）

**（a）RTL：把 SPI 引到顶层。** 需要引出的信号（`sapphire_soc` 的端口名，见
`ip\sapphire_soc\sapphire_soc.v:139-151,223`）：单线模式只用 data_0/data_1，data_2/data_3 可以继续端接。
最小集合 8 根：

```
system_spi_0_io_data_0_read / _write / _writeEnable      (data_0 是 MOSI，双向)
system_spi_0_io_data_1_read / _write / _writeEnable      (data_1 是 MISO，单线读时只用 _read)
system_spi_0_io_sclk_write
system_spi_0_io_ss
```

**（b）Interface Designer：加 4 个 GPIO 块。** 与厂商 TinyML 参考设计
`...\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.peri.xml:236-250` **逐字一致**
（该设计能过时序、能跑）：

| GPIO 块名 | `gpio_def` | 模式 | 引脚号（实测） |
|---|---|---|---|
| `system_spi_0_io_data_0` | `GPIOL_P_03` | inout | **M1**（`GPIOL_P_03_CDI0`） |
| `system_spi_0_io_data_1` | `GPIOL_N_03` | inout | **L1**（`GPIOL_N_03_CDI1`） |
| `system_spi_0_io_sclk_write` | `GPIOL_N_01` | output | **N1**（`GPIOL_N_01_CCK`） |
| `system_spi_0_io_ss` | `GPIOL_P_01` | output | **P1**（`GPIOL_P_01_SSL_N`） |

引脚号实测来源：`_ddr_demo_ti60\outflow\ddr_demo_ti60.pinout.csv:164/179/194/209`
（同一批 `gpio_def` 名字）。IO 标准 `1.8 V LVCMOS`，输出 `drive_strength=4`，寄存器时钟用我们的
`core_clk`（厂商 demo 用的是 `i_mipi_rx_pclk`，那是它自己的视频时钟，与我们无关）。

> **为什么这 4 根脚"既是配置脚又能当用户 IO"**：`mmt.xml:204` 的配置模式是
> **`active`（SPI Active ×1）**，即 FPGA 上电由这 4 根脚（CDI0/CDI1/CCK/SSL_N）从 flash 读位流；
> 配置完成后这 4 根脚交还给用户逻辑 —— 厂商的 SoC bootloader 方案就是这么做的
> （`per:236-250` 把 `system_spi_0_io_*` 直接绑到这批 `gpio_def` 上）。这一步能不能成，
> **必须以"重新跑完流程 + 上板"为准**（列在 §7）。

**（c）SDC：把 `constr\ti60f225_oob.sdc:146-150` 修好或删掉。** 这几条现在指向不存在的
`i_soc_clk~CLKOUT~1~31` / `sdram_clk~CLKOUT~218~94`。SPI 只有 16.67MHz（60ns 周期），
`set_output_delay` 不是关键路径；接上端口后要么改成真实参考时钟，要么直接换成
`set_max_delay`/删掉。**这是 Lead 的写权限范围**（我不改 `constr\`）。

**（d）`rtl\mmt\soc\mmt_soc_subsystem.v` 的注释与顶层注释也该同步更新**：
`:12`、`:376` 现在写着"SPI0 本方案不用"。接线后就不对了。

---

## 4. 路线乙′：自建 loader（推荐，**已实现**）

### 4.1 原理

```
上电
 ├─ FPGA 用 SPI Active 从 flash 0x0 读压缩位流，配置完成
 ├─ CPU 从片内 RAM 0xF9000000 开始跑 loader（我们在 sw\ddr\loader.c，由 hex2soc.ps1 预置进 RAM 初值）
 │    ├─ [0] 配 SPI 控制器 → 0xAB 唤醒 flash → 0xE9 退出 4 字节地址模式
 │    ├─ [1] DDR 写-读探测（顺带等 DDR3 校准完成；地址用 app 区头 4 字节，随即被覆盖）
 │    ├─ [2] 从 flash 0x380000 读 48 字节**镜像头**，做 9 条边界检查
 │    ├─ [3] 按头里的长度，把 app 搬到 DDR 0x00001000（4 字节一写）
 │    ├─ [4] 按头里的长度，把权重搬到 DDR 0x00100000
 │    ├─ [5] 从 DDR 读回，重算 CRC32 与头里的值比对（不一致就**不跳**）
 │    └─ [6] `.word(0x500F)` 失效 D-cache → 跳到 DDR 0x00001000
 └─ CPU 在 DDR 里执行 app（sw\ddr\ddr_app.c；将来换成 sw\main.c）
```

### 4.2 与另外两条路的区别（别混）

| | 固件在哪跑 | 模型在哪 | 谁搬 | 要改 IP？ | flash 越界读？ |
|---|---|---|---|---|---|
| **甲** 厂商 bootloader | DDR | DDR | 厂商 bootloader | 16MB 那支要；124K 那支不要 | **16MB 那支会越界 12MiB** |
| **乙**（任务书里的原版）| **片内 RAM（现状）** | DDR | 固件自己 | 不要 | 不会 |
| **乙′（推荐）** | **DDR** | DDR | 自建 loader（也跑在片内 RAM，但只当搬运工） | **不要** | **不会**（只读头里声明的长度） |

乙′ 相对原版乙的额外价值：**"固件也真的在 DDR 里跑"**（项目目标原文），而不是"固件留在 RAM、只把权重放进 DDR"。

### 4.3 DDR 缓存一致性：实测到的机制 + 该发什么指令

| 项 | 实测结论 | 证据 |
|---|---|---|
| DDR 是否可缓存 | **是**。只有 `0xf8000000`/`0xe1000000` 两个 16MB 区被视为非缓存 IO，DDR 不在其中 | `sapphire_soc.v:17905` `DBusCachedPlugin_mmuBus_rsp_isIoAccess = (((addr & ~0x00ffffff)==0xf8000000) \|\| (==0xe1000000))` |
| D-cache 写策略 | **写直达（write-through）**：整个 `DataCache_...` 模块（`sapphire_soc.v:25041` 起）里 grep **`dirty` 零匹配** ⇒ 没有脏位跟踪 | 实测 grep |
| 有没有写缓冲 | **没有**。CPU 的 DBus 桥在网表里就叫 `dBus_Bridge_withoutWriteBuffer_...` | `sapphire_soc.v:1155` `wire dBus_Bridge_withoutWriteBuffer_busCmdContext_isWrite;` |
| 失效 D-cache 的指令 | `.word(0x500F)`（rs1=x0 ⇒ 全失效；rs1≠0 ⇒ 只失效该地址所在行） | 网表 `sapphire_soc.v:16289`（`mask 0x01f0707f == 0x0000500F`）、`:18186`（`dataCache_1_io_cpu_flush_valid = execute_arbitration_isValid && execute_MEMORY_MANAGMENT`）、`:18187`（`payload_singleLine = (INSTRUCTION[19:15] != 0)`）；厂商 BSP `driver\vexriscv.h:26` |
| `fence.i` 能不能用 | **本方案不使用**。原因：① 本工程用 `-march=rv32im`，GCC 拒绝汇编 `fence.i`（需 `rv32im_zifencei`）；② 网表里只找到 opcode `0x0f` 的**合法性**判定（`sapphire_soc.v:16288`），**没有找到 `fence.i` 的功能解码** ⇒ "这颗配置出来的 VexRiscv 到底支不支持 Zifencei" **无法确认**；③ loader 从不从 DDR 取指，I-cache 不可能有 app 地址范围的旧行，**本来就不需要**。留了编译开关 `MMT_USE_ZIFENCEI`（默认 0） | 见 `sw\ddr\loader.c` 的注释 |

⇒ 因此 loader 在跳转前只做一件事：**`.word(0x500F)`**（把搬运/校验阶段留在 D-cache 里的行失效）。
写侧因为"写直达 + 无写缓冲"，字节写完就出去了，不需要额外 flush。
【推断，必须上板确认】AXI 写响应是否已被 CPU 等到 —— 万一 DDR3 控制器还在校准、写被丢弃，
CRC 校验会立刻抓到（它会读回 DDR 重算）⇒ **这就是为什么 CRC 校验不是装饰，而是必须的**。

### 4.4 DDR 就绪

DDR3 控制器上电要校准几百微秒。loader 的 `[1]` 步骤对 `MMT_APP_BASE` 写 3 组花样、每组写完
`.word(0x500F)` 再回读，最多重试 3 轮 —— 既探测可写性，又顺带把"控制器没就绪"的时间等掉。
失败时**不跳转**，在 stage 1 打印 `!! DDR not usable` 并停住（留在看得见的阶段，别飞）。

### 4.5 交付物（全部在 `sw\ddr\`，本轮新建/更新）

| 文件 | 作用 |
|---|---|
| `mmt_ddr.h` | 内存图 + flash 布局 + `mmt_img_hdr_t`（48B 头，loader/app/打包脚本三方共用一份定义） |
| `spi_flash.h` | 最小 SPI flash 读驱动：寄存器偏移、位定义、片选 0x880/0x800、0xAB/0xE9/0x0B、带超时的轮询、自校准的"命令 FIFO 排空"等待、`spi_flash_to_mem`（4 字节一写）、`mmt_crc32` |
| `loader.c` | 阶段 1（见 §4.1 流程；含 9 条边界检查、UART 全程报告、失败不跳转） |
| `link_loader.ld` | `ORIGIN = 0xF9000000, LENGTH = 32K`；4K 栈；3 条 ASSERT（`_start` 必须正好 0xF9000000、`_end`/`_stack_top` 不得越过 0xF9008000） |
| `ddr_app.c` | 阶段 2 演示/自检：打印自己的执行地址（自证在 DDR）、打印权重区头 8 个字、**重读 flash 头再算一遍 CRC**（从"被搬运方"角度复核）、张量区 64 字写-读回环 |
| `link_ddr.ld` | 沿用 task-3 的草案（`0x1000`/1020K + 4 条 ASSERT + `PROVIDE` 导出 `mmt_weights_base` 等地址符号） |
| `build_ddr.ps1` | 两条流水线一次编完 + 地址守卫自检 + 调打包；**不跑 Efinity** |
| `mkimage.ps1` | 打包 48B 头 + 载荷；CRC32 自带标准向量自检（`'123456789' → 0xCBF43926`）；容量/空洞/重叠/物理边界四类硬检查；输出 `.rpt` 地址表 |
| `verify_image.py` | PC 上"当一次 loader"：解析头、复现 9 条边界检查、CRC 三重比对（位运算实现 vs zlib vs 头字段）、模拟搬运并与原文件逐字节比对 |
| `extract_model_bin.ps1` | 把厂商 demo 的 C 数组模型还原成 `.bin`（可复现，脚本自带字节数复核） |
| `README.md` | 目录使用说明 |
| `weights\mobilenetv1_person_detect_model_data.bin` | 抽出来的真实模型（300,568 B） |
| `pack_image.ps1` | **甲**（厂商 bootloader）用的旧打包器，保留作退路/参考 |

### 4.6 编译与验证：实测结果

命令（可复现）：

```powershell
powershell -File D:\FPGA\mmt\sw\ddr\extract_model_bin.ps1
powershell -File D:\FPGA\mmt\sw\ddr\build_ddr.ps1 -Weights D:\FPGA\mmt\sw\ddr\weights\mobilenetv1_person_detect_model_data.bin
& "<python>"  D:\FPGA\mmt\sw\ddr\verify_image.py
```

**（a）编译/链接——通过**（工具链 `riscv-none-elf-gcc 15.2.0`，`-march=rv32im -mabi=ilp32 -Os`）：

```
  loader _start = 0xF9000000  OK（片内 RAM / 复位向量）
  app    _start = 0x00001000  OK（DDR app 区）
  loader.bin = 5896 bytes（片内 RAM 预算 32768，余 26872）
  loader _end   = 0xF9002710  OK（片内 RAM 末尾 0xF9008000 之内）
```

| 目标 | text | rodata | data | bss | stack | `.bin` | 关键符号 |
|---|---|---|---|---|---|---|---|
| `loader.elf` | 2988 | 2908 | 0 | 4 | 4096 | **5896 B** | `_start=0xF9000000`、`_end=0xF9002710` |
| `ddr_app.elf` | 2124 | 2024 | 0 | 4 | 8192 | **4148 B** | `_start=0x00001000`、`_end=0x00004040`、`mmt_weights_base=0x00100000`、`mmt_tensor_base=0x03000000` |

唯一的链接告警是 `has a LOAD segment with RWX permissions` —— 单 MEMORY 区裸机脚本必然如此（task-3 也遇到过），无害。

**（b）打包——通过**：

```
flash 起始    : 0x00380000   预算 4718592 bytes（= 8.00 MB - 0x00380000）
app           : ddr_app.bin  4148 bytes
权重          : mobilenetv1_person_detect_model_data.bin  300568 bytes（293.5 KiB）
载荷          : 304716 bytes
镜像总长      : 304780 bytes / 预算 4718592 bytes      ← 占 6.5%
DDR 落点      : app 0x00001000 .. 0x00002033   权重 0x00100000 .. 0x00149617
载荷 CRC32    : 0xCFCF5E87
自校验        : OK（载荷可复现、CRC 一致）
```

**（c）PC 侧镜像验证——18 项 PASS / 0 FAIL**：

```
[1] 解析 48 字节镜像头            → 4 项 PASS
[2] 复现 loader.c 的边界检查      → 9 项 PASS
[3] CRC32 三重比对                → 2 项 PASS（位运算实现 == zlib.crc32 == 头字段）
[4] 模拟搬运并与原文件比对        → 3 项 PASS（app 与权重逐字节一致）
[5] 启动时间推算（非实测）
=== 结果：18 项通过，0 项失败 ===
```

**（d）反汇编人工核对**（把 `.word(0x500F)` 与跳转指令都找出来了）：
`loader.elf` 里 `f900096c: 0000500f`（DDR 探测里）、`f9000b34: 0000500f`（跳转前）、
`f9000b60: jalr s0`（跳到镜像头里的 `app_ddr_addr`）。

> **诚实边界**：以上是"编译通过 + 链接地址正确 + 镜像格式自洽 + 算法在 PC 上复现"。
> **loader.c 的机器码没有在真实 CPU 上执行过**（本机没有 RISC-V 仿真器；Efinity 流程由 Lead 独占）。
> `spi_flash.h` 里每一个寄存器偏移/位定义都对着本工程网表与厂商驱动核对过（见 §9 证据表），
> 但**"读 flash 真的能读出正确数据"只有上板才能证明**（列在 §7）。

### 4.7 启动时间与容量的**推算**

- SPI 时钟 = `FCLK / ((clkDivider+1)×2)`，我们用厂商同款 `clkDivider=2`、`FCLK=100MHz`
  ⇒ **16.67 MHz**，逐字节 Fast Read 每字节 8 bit ⇒ **480 ns/字节**。
  （依据：`driver\spi.h:66` 的公式与 `spiFlash.h:390` 的 `clkDivider=2`）
- 搬 304,780 字节 ⇒ **0.146 s**；厂商 16 MiB 那支 ⇒ **8.05 s**。
  实际还要加上 CRC 校验（软算 304,716 字节，量级几十毫秒）和 DDR 探测。
  **这是推算，不是实测**；上板后以 UART 横幅之间的时间戳为准。
- 容量：镜像 304,780 B / 4,718,592 B = 6.5%。**就算把模型换大 15 倍还有余量**。
  改 flash 起始地址（例如位流长大到超过 0x380000）只需 `build_ddr.ps1 -FlashBase`。

---

## 5. 两条路线对比与推荐（结论）

| 维度 | 甲（厂商 bootloader） | **乙′（自建 loader，推荐）** |
|---|---|---|
| 8MB flash 下有没有现成可用的 | **没有**（§2.4） | 不适用（本来就自己写） |
| 越界读 flash | 16MB 那支**越界 12MiB**（能跑但脏） | **不会**，只读头里声明的长度 |
| 要不要重新生成 SoC IP | 16MB 那支要；124K 那支不要但装不下模型 | **不要** |
| 要不要厂商 BSP/embedded_sw | 想自己编 bootloader 才要，本工程 IP 目录没有 | **不要**（只用两个寄存器窗口） |
| 启动时间（**推算**） | ~8.05 s | ~0.15 s（+CRC 几十 ms） |
| 镜像尺寸上限 | 硬顶 4.5MB（还受"垃圾区禁用"约束） | 4.5MB（默认起始地址；可改），**无垃圾区** |
| 调试手段 | 只有 bootloader 本身，几乎不可观测 | UART 分 7 步打印 + CRC + "失败不跳转"，上板问题直接定位 |
| 换成真业务固件 | 重打镜像 | 重打镜像（`sw\main.c` 换成 `ddr_app.c` 即可，构建方式不变） |
| 给评委讲 | "用了厂商 bootloader" | "**自己实现了 flash→DDR 的两级启动 + CRC 校验**"，可讲性更强 |
| 前置条件 | 都必须先接 SPI 引脚（§3） | 同左 |
| 风险 | 越界读依赖 flash 地址回绕（**推断**未证实） | 自研代码有 bug 风险 —— 用 CRC + 不跳转兜住 |

⇒ **推荐路线乙′**。它把"甲"的唯一优势（不用写代码）换成了"不用改 IP + 快 55 倍 + 可观测"，
而写代码的代价已经被压到"400 行左右的裸机 C，且已经编译/验证过"。

---

## 6. 实施清单（谁做、做什么、怎么验）

### 阶段 0 —— **本轮已完成**（不需要板子，不需要 Efinity）

| 项 | 状态 | 产物 |
|---|---|---|
| 路线决策 + bootloader 实测表 + SPI 前置条件查清 | ✅ | 本文档 |
| loader / app 源码 + 两级链接脚本 | ✅ 编译通过 | `loader.c`、`ddr_app.c`、`link_loader.ld`、`link_ddr.ld` |
| SPI flash 驱动（寄存器映射对过网表） | ✅ 编译通过 | `spi_flash.h` |
| 带头的镜像格式 + 打包器 + 容量/边界红线 | ✅ 实测 3 类分支 | `mkimage.ps1`、`mmt_ddr.h` |
| 真实模型抽成 `.bin`（可复现） | ✅ 300,568 B | `extract_model_bin.ps1`、`weights\*.bin` |
| PC 侧镜像验证（格式/边界/CRC/模拟搬运） | ✅ 18/18 PASS | `verify_image.py` |
| 尺寸报告 | ✅ | §4.6 |

### 阶段 1 —— **Lead**（RTL + 引脚 + 重跑流程，必须做，否则 loader 读不到 flash）

1. 按 §3.2(a) 把 SoC 的 8 根 SPI 信号引到 `mmt_soc_subsystem` → `mmt_top` 的顶层端口；
2. 按 §3.2(b) 在 Interface Designer 里加 4 个 GPIO 块（`gpio_def` 与模式照抄；引脚 M1/L1/N1/P1）；
3. 按 §3.2(c) 修/删 `constr\ti60f225_oob.sdc:146-150` 那几条失效约束；
4. 重跑 `efx_map` + `efx_pnr`；
   **不需要板子的验收**：
   - `out\efx_pnr.log` 里**不再**出现 `No ports matched 'system_spi_0_io_*'`；
   - `constr\*_oob.interface.csv` / pinout 报告里出现这 4 根脚（M1/L1/N1/P1）；
   - 时序 setup/hold 仍全正（新增的 SPI 是 16.67MHz，不该成为关键路径）。

### 阶段 2 —— **Lead**（装 loader + 生成位流 + 烧 flash）

1. `powershell -File D:\FPGA\mmt\sw\hex2soc.ps1 -Bin D:\FPGA\mmt\sw\ddr\build\loader.bin -Install`
   （会写 `ip\sapphire_soc\**` 的 4 个 `ram_symbol*.bin`，**这一步之后就不要再指望片内 RAM 跑 sw\main.c**）；
2. **重新综合布线**（BRAM 初值变了，必须重跑）+ 生成位流（`efx_pgm`）；
   **验收**：`outflow\mmt.hex` 的**实际 flash 占用**（不是文件大小）必须 < `0x380000`。
   参考：同类 Ti60 设计实测为 649,454（ddr demo）/ 992,864 字节（tinyml demo），**3.5MB 余量很宽松**；
3. 烧 flash：位流 → `0x000000`，`sw\ddr\build\ddr_image.bin` → `0x00380000`
   （分两次烧，或用 `soc_combine_hex` 合成一个文件烧）。

### 阶段 3 —— 上板（**需要板子**）

| 步骤 | 期望看到 |
|---|---|
| 1. 先只装固件（`mkimage.ps1` 不带 `-Weights`），烧 flash，上电 | UART 115200：stage-1 横幅 → `[0] SPI … OK` → `[1] DDR write/read : OK` → `[2] image header … boundary checks : all pass` → `[3]/[4] copy` → `[5] CRC32 OK` → `[6] … jump` → stage-2 横幅 + `&main = 0x00001xxx` |
| 2. 再加权重（把真模型打进镜像） | stage-2 打印 `mmt_weights_base = 0x00100000` 与头 8 个字；`[3] ==> CRC32 MATCH` |
| 3. 把 `ddr_app.c` 换成 `sw\main.c`（业务固件） | 与现状相同的 UART 输出，但执行地址在 DDR |
| 4. 接加速器 / DMA 读权重 | 加速器能读到 `0x00100000` 的正确数据（**注意 §4.3 的 D-cache 指令**） |

---

## 7. 必须在真机上才能确认的项（没有一项能靠读文档解决）

| # | 项 | 现状 | 怎么确认 |
|---|---|---|---|
| V1 | **SPI 接线后能不能真的读到 flash** | **无法确认**（本工程从未接过；只验证了寄存器映射与厂商同款设计可行） | 阶段 3 步骤 1：loader 会打印 SPI 超时或 CRC 不匹配；再用逻辑分析仪看 N1/L1/M1/P1 上的波形 |
| V2 | SPI 时钟能否提高（16.67 → 25/50MHz） | 未验证；默认用厂商同款 `clkDivider=2` | 改 `spi_flash.h` 的 `MMT_SPI_CLK_DIV`，上板看 CRC 是否仍 OK、再逐步试 |
| V3 | GD25LQ64 越界地址是否**回绕**（决定"甲+16MB"是否真的能跑） | **推断** | 读 flash 数据手册的地址位定义；或上板读 DDR `0x00480000` 与 flash 开头比对 |
| V4 | 本设计位流的**flash 实际占用** < 3.5MB | 未知（同类设计实测 0.65–0.95MB） | 生成位流后看 Programmer/`soc_combine_hex.rpt` 的 Length（**不是** `.hex` 文件大小） |
| V5 | DDR3 校准期间 CPU 访问 DDR 的行为（挂起还是丢写） | 未知 | 阶段 3 步骤 1：`[1] DDR probe` 打印 OK/mismatch；若失败看是否需要更长的等待 |
| V6 | AXI 写响应与 CRC 校验的一致性（写直达缓存是否真的把字节送达 DDR） | 推断（网表里无 dirty 位、无写缓冲） | `[5] CRC32 OK` 通过即证明；不通过则说明需要额外等待/fence |
| V7 | `.word(0x500F)` 在本配置下的确切语义（全失效 vs 带写回） | 网表证据充分（`:16289/:18186/:18187`），但**未在硬件上验证过** | 写 `0x03000000` → 执行 `.word(0x500F)` → 用调试器（绕过 CPU 缓存）读同一地址 |
| V8 | `fence.i`/Zifencei 是否被这颗 VexRiscv 支持 | **无法确认**（网表只找到合法性判定，`-march=rv32im` 也汇编不了） | 若将来需要，先用 `-march=rv32im_zifencei` 编一段只执行 `fence.i` 的代码上板试（本方案不用它） |
| V9 | 物理 DDR 是否真有 256MB | **推断**（由 `rtl\ddr3_controller\ddr3_parameter.vh:6-15` 几何参数反推；task-3 的 U1） | 地址位翻转测试；或查板卡原理图颗粒型号 |
| V10 | `0x00480000–0x01000FFF` 在**甲**方案下被垃圾覆盖 | **推断**（依赖 V3） | 只在回去走甲时才需要确认；乙′ 没有这个问题 |

---

## 8. 需要 Lead 应用到既有文件的改动（**我不改，按规矩写在这里**）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `rtl\mmt\soc\mmt_soc_subsystem.v` | `:376-391` 的 SPI 端接 → 改成引出到新端口；`:12`/`:376` 的"SPI0 不用"注释同步更新 | §3.1 证据 1；不接就搬不动 |
| `rtl\mmt\mmt_top.v` | 增加 4 个顶层端口（2 个 inout + 2 个 output）并透过 `u_soc` 连接 | §3.2(b) |
| `constr\ti60f225_oob.peri.xml`（或走 Interface Designer GUI） | 加 4 个 GPIO 块，`gpio_def`/模式照抄 `edge_vision_soc.peri.xml:236-250` | §3.2(b)，引脚表在 §3.2 |
| `constr\ti60f225_oob.sdc` | `:146-150` 的失效约束修好或删除（现在指向不存在的 `i_soc_clk~CLKOUT~1~31`/`sdram_clk~CLKOUT~218~94`） | `out\efx_pnr.log:641-663` |
| （可选）`sw\build_sw.ps1` | 若将来要把业务固件也放进 DDR：把 `-T sw\link.ld` 换成 `sw\ddr\link_ddr.ld`（第 45 行） | §5 阶段 3 步骤 3 |
| （可选）`sw\link.ld` | 保持不动。**两条启动路线二选一**，不要混 | `hex2soc.ps1 -Install` 会用 loader 覆盖片内 RAM |

---

## 9. 证据清单（本文档每一条结论的出处）

| 文件 | 关键行 | 证明什么 |
|---|---|---|
| `ip\sapphire_soc\sapphire_soc.v` | `:11628` | DDR 给 CPU 的基址 = `0x1000` |
| 同上 | `:11594` | 片内 RAM 窗口 `(addr & ~0x7fff) == 0xf9000000`（32KB） |
| 同上 | `:19462` | 复位向量 = `0xF9000000` |
| 同上 | `:139-151`、`:223` | SPI0 端口清单与位宽 |
| 同上 | `:9433/9437/9441/9448/9473/9486/9626/9633/9638/9643/9648` | SPI 控制器寄存器地址解码（0x00/0x04/0x0C/0x58/0x50/0x54/0x08/0x20/0x24/0x28/0x2C） |
| 同上 | `:9497-9500` | bit8=写、bit9=读、bit11=片选、数据在 [7:0] |
| 同上 | `:17905` | DDR 可缓存；只有 `0xf8000000`/`0xe1000000` 是非缓存 IO |
| 同上 | `:1155` | CPU 的 DBus 桥没有写缓冲（`withoutWriteBuffer`） |
| 同上 | `:25041` 起（`DataCache_...` 模块） | grep `dirty` 零匹配 ⇒ 写直达 |
| 同上 | `:16288/16289`、`:18186/18187` | `.word(0x500F)` 是合法且驱动 D-cache 失效；rs1≠0 时只失效单行 |
| `ip\sapphire_soc\source\soc_config` | `:1` | 当前默认 ramHex = `bootloader_124K.hex` |
| 同上 | `:21/26/31/34` | APB 桥 `0xf8000000`、RAM `0x8000@0xf9000000`、SPI `0x014000` |
| `rtl\mmt\soc\mmt_soc_subsystem.v` | `:376-391`、`:476` | **SPI0 被端接**（读接 0、写悬空） |
| `rtl\mmt\mmt_top.v` | `:661` | 帧缓存 `0x02000000` |
| 同上 | `:758/768/1470` | SoC 的 DDR AXI4 主口 = 互联 `s1` |
| `mmt.xml` | `:204/205/213/220` | 配置模式 SPI Active ×1、位流压缩开、生成 hex |
| `constr\ti60f225_oob.sdc` | `:146-150` | 指向 SPI/不存在端口的失效约束 |
| `out\efx_pnr.log` | `:641/644/645/650/655/660` | 工具确认 `system_spi_0_io_*`、`i_soc_clk~CLKOUT~1~31`、`sdram_clk~CLKOUT~218~94` 都无匹配 |
| `out\mmt.place.out` | `:643-658` | 同上（place 阶段） |
| `out\mmt.hier_util.rpt` | `:165`、`:362`、`:446` | `u_ddr3_top`、`u_ddr_axi_ic` 已实例化；SPI 控制器存在但白占资源 |
| `D:\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\generator\bootloader\bootloader_*.hex` | 全部 20 支 | §2.2 地址范围表（本轮解析 + 反汇编） |
| `D:\FPGA\tinyml\...\Ti60F225_mobilenetv1_person_detect_demo\ref_files\bootloader_16MB\SapphireSoc\bootloader.hex` | 反汇编 `0xF90005D0-0xF90005EC` | 源 `0x380000` → 目标 `0x1000`、长度 `0x01000000` |
| `_ddr_demo_ti60\embedded_sw\soc\software\standalone\bootloader\src\bootloaderConfig.h` | `:17-33` | 厂商 bootloader 的调用序列（init→wake→exit4B→f2m→跳转）与 124KB 参数 |
| `_ddr_demo_ti60\...\driver\spi.h` | `:29-58`、`:100-238`、`:264-281` | SPI 寄存器偏移/位定义/片选/排空等待（与我们的网表逐条对上） |
| `_ddr_demo_ti60\...\driver\spiFlash.h` | `:385-396`、`:362-376`、`:710-721` | SPI 初始化参数、片选、`spiFlash_f2m_` 的 0x0B 时序 |
| `_ddr_demo_ti60\...\driver\vexriscv.h` | `:26`、`:39`、`:42-53` | `data_cache_invalidate_all()`=`0x500F`、`instruction_cache_invalidate()`=`fence.i`、写缓冲 flush 宏 |
| `tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.peri.xml` | `:236-250` | SPI 4 根脚的 `gpio_def` 与模式（照抄对象） |
| `_ddr_demo_ti60\outflow\ddr_demo_ti60.pinout.csv` | `:164/179/194/209` | 引脚号 M1/L1/N1/P1 |
| `_ddr_demo_ti60\outflow\soc_combine_hex.rpt` | `:6-7` | 位流在 flash 里的真实长度 `0x9e8ee`；用户软件固定放 `0x380000` |
| `D:\FPGA\易灵思\参考资料\_目录说明.md` | `:67` | 板载 flash 8MB / GD25LQ64 |
| `...\TI60F225I3-V4 DEMO板软硬件设计说明-260813-1.pdf.txt` | `:124`、`:640` | 同上 |
| `sw\ddr\*`（本轮产物） | — | §4.6 的编译/打包/验证实测输出 |

---

## 10. 一页速查

```
DDR 地址（给 CPU）
  0x00000000-0x00000FFF  解码空洞，禁用
  0x00001000  app 入口（也是 loader 跳转目标）
  0x00100000  模型权重起始（mmt_weights_base）
  0x00480000  权重预算末尾（4.5MB 镜像）
  0x02000000  视频帧缓存（RTL 硬件写）
  0x03000000  张量/激活区
  0x10000000  物理 DDR 边界（256MB，推断）

flash 布局
  0x000000    位流（SPI Active 配置用；压缩后的实际长度必须 < 0x380000）
  0x380000    我们的镜像 ddr_image.bin（48B 头 + app + 权重，≤ 4.5MB）
              ★ 这个地址是我们自己定的，不是硬件约束

启动链
  片内 RAM 0xF9000000（32KB）= loader.bin（5896 B）
  → SPI flash 0x380000 读头 → 搬 app/权重进 DDR → CRC32 校验 → .word(0x500F) → 跳 0x1000

要做的三步（缺一步都不动）
  1) Lead：接 SPI 到 M1/L1/N1/P1 + 加 4 个 GPIO 块 + 重跑流程
  2) Lead：hex2soc.ps1 -Bin ...\loader.bin -Install + 重跑 + 生成位流
  3) Lead/硬件：烧 flash（位流→0x0，镜像→0x380000），上电看 UART

别踩
  · hex2soc -Install 装了 loader 之后，片内 RAM 里就没有 sw\main.c 了（二选一）
  · 0x0-0xFFF 永远不许放东西
  · 改 flash 起始地址要同时改 build_ddr.ps1 与 mkimage.ps1 的 -FlashBase
  · CPU 写 DDR 之前/之后要记得 .word(0x500F)（DDR 可缓存）
```
