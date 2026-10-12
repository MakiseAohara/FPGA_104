# `sw\ddr\` — 「模型与固件放 DDR 运行」的实现目录（路线乙′）

> **决策全文在 [`docs\DDR执行路径决策.md`](../../docs/DDR执行路径决策.md)**（为什么不用厂商 bootloader、
> 8MB flash 下的实测结论、SPI 未接线这个前置条件、真机确认清单）。
> 本文件只讲"这一目录里有什么、怎么用"。

## 30 秒版本

目标「模型与固件放 DDR 运行」的实现方式：

```
上电 → FPGA 从 flash 配置 → CPU 从片内 RAM 0xF9000000 跑 ~~loader~~(我们写的)
     → loader 用 SPI 从 flash 0x380000 读镜像头，按头里的长度把 app/权重搬进 DDR
     → 刷 D-cache → 跳 DDR 0x00001000 → ~~app~~(也在 DDR 里跑)
```

- **不用**厂商 bootloader（实测没有一支匹配 8MB flash，见决策文档 §2）；
- **不用**重新生成 SoC IP（走现成的 `sw\hex2soc.ps1 -Install` 把 loader 灌进片内 RAM）；
- **flash 里镜像的起始地址是我们自己定的**（默认 `0x380000`），所以不会越界读 flash。

> ⚠️ **前置条件**：本工程当前的 SoC **SPI0 没有接到 flash 引脚**（`rtl\mmt\soc\mmt_soc_subsystem.v:376-391`
> 把它端接了，顶层也没有 SPI 端口，工具日志里有 `No ports matched 'system_spi_0_io_ss'`）。
> 不先补这个，loader 读不到 flash。改法与引脚号见决策文档 §3。

## 文件

| 文件 | 作用 |
|---|---|
| `mmt_ddr.h` | 内存图（DDR / flash 地址）+ **镜像头结构** `mmt_img_hdr_t`（loader / app / 打包脚本三方共用） |
| `spi_flash.h` | 最小 SPI flash 读驱动（寄存器映射逐条对过本工程网表；只读，够用） |
| `loader.c` | **阶段 1**：跑在片内 RAM 的搬运器（读头 → 边界检查 → DDR 探测 → 搬运 → CRC → 刷 cache → 跳转） |
| `link_loader.ld` | 阶段 1 链接脚本：`ORIGIN = 0xF9000000, LENGTH = 32K`（引脚内 RAM，带守卫 ASSERT） |
| `ddr_app.c` | **阶段 2**：跑在 DDR 的演示/自检应用（自证在 DDR、打印权重、重读 flash 复核 CRC） |
| `link_ddr.ld` | 阶段 2 链接脚本：`ORIGIN = 0x00001000, LENGTH = 1020K`（DDR app 区，带守卫 ASSERT） |
| `build_ddr.ps1` | 一条命令编两级 + 打包（+ 地址守卫自检），**不跑 Efinity** |
| `mkimage.ps1` | 打包 flash 镜像（48B 头 + 载荷），带 CRC32 自检与容量红线 |
| `extract_model_bin.ps1` | 把厂商 demo 的 C 数组模型还原成 `.bin`（**可复现**，不是手工二进制） |
| `verify_image.py` | 在 PC 上"当一次 loader"验镜像：格式/边界/CRC 三重比对/模拟搬运，18 项 PASS（可加 `--flash-base/--flash-size`） |
| `verify_flash_layout.ps1` | **烧写前必跑**：输入位流 + 镜像 → 布局表 + 重叠/越界/对齐 + 镜像头/CRC 复核 + PASS/FAIL 退出码 |
| `verify_combined_image.py` | 校验"合成一个文件烧"的产物（长度/两段内容/间隙/magic），配套 §4.1 的合并命令 |
| `weights\` | 抽出来的模型权重（`mobilenetv1_person_detect_model_data.bin`，300,568 B） |
| `build\` | 构建产物（`loader.bin` / `ddr_app.bin` / `ddr_image.bin` / `flash_combined.hex` / `.rpt`），可随时删 |
| `pack_image.ps1` | **路线甲（厂商 bootloader）**用的旧打包器（无 48B 头，layout 不同），保留作参考/退路。⚠️ 它的默认输出已改名 `build\LEGACY_routeA_image.bin`——**别**把它当 `ddr_image.bin` 烧（两种格式不兼容，loader 的 magic 检查会拒） |
| `_test_build\` | 上一轮 `link_ddr.ld` 的独立链接验证产物，可删 |

> **flash 布局与烧写步骤的完整说明**（位流真的占多少、四份脚本字段对照、两种烧法）
> 见 [`docs\Flash布局与镜像一致性.md`](../../docs/Flash布局与镜像一致性.md)。
> 一句话结论：**位流在 flash 里只占 959,901 字节（0.915 MiB）**，
> `out\mmt.hex` 磁盘上的 2,812.2 KB 是"每行一个字节的十六进制文本"的 ASCII 展开，**不是** flash 占用。

## 怎么用（四条命令）

```powershell
# 1) 抽模型（只需一次；也可用你自己的模型 .bin）
powershell -File D:\FPGA\mmt\sw\ddr\extract_model_bin.ps1

# 2) 编 loader + app + 打包镜像（不跑 Efinity）
powershell -File D:\FPGA\mmt\sw\ddr\build_ddr.ps1 `
    -Weights D:\FPGA\mmt\sw\ddr\weights\mobilenetv1_person_detect_model_data.bin

# 3) 验镜像格式（模拟 loader 搬运 + CRC 三重比对）
& "<python>" D:\FPGA\mmt\sw\ddr\verify_image.py

# 4) 烧写前验 flash 布局（位流 + 镜像是否自洽；退出码 0 才烧）
powershell -File D:\FPGA\mmt\sw\ddr\verify_flash_layout.ps1
```

## 已实测（2026-10-11，本机工具链 `D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1`）

| 项 | 值 |
|---|---|
| `loader.elf` | text 2988 + rodata 2908 + bss 4 + stack 4096 = 9996；`_start=0xF9000000`、`_end=0xF9002710` |
| `loader.bin` | **5896 字节**（片内 RAM 预算 32768，余 26872） |
| `ddr_app.elf` | text 2124 + rodata 2024 + bss 4 + stack 8192；`_start=0x00001000`、`_end=0x00004040` |
| `ddr_app.bin` | **4148 字节** |
| `ddr_image.bin` | **304,780 字节**（= 48B 头 + 16B 填充 + 4148 app + 300,568 权重）≤ 4.5MB 预算的 6.5% |
| 载荷 CRC32 | `0xCFCF5E87`（`mkimage.ps1` 与 `verify_image.py` 两处独立算出同一个值） |
| `verify_image.py` | **18 项 PASS / 0 FAIL** |
| `verify_flash_layout.ps1` | **PASS 24 / FAIL 0 / WARN 2**，退出码 0 |
| `verify_combined_image.py` | **PASS 6 / FAIL 0 / WARN 1**，退出码 0 |
| 位流 flash 占用 | **959,901 字节 = 0xEA59D = 0.915 MiB**（`out\mmt.hex` 解码后的字节数；厂商合并工具报告的也是 `0x000ea59d`） |
| flash 布局 | 位流 `0x0…0xEA59C`、镜像 `0x380000…0x3CA68B`、**不重叠**、剩余 4,310.4 KiB |
| 启动时间（**推算**，非实测） | SPI 16.67MHz 逐字节读 ≈ 0.146 s；厂商 16MB bootloader 同样速率要 ≈ 8.05 s |

## 别踩的四个坑

1. **位流"文件大小"不是"flash 占用"**：Efinity 的 `.hex`/`.bit` 是**每行一个字节的十六进制文本**，
   磁盘大小 ≈ 真实字节数 × 3。`out\mmt.hex` 磁盘 2,812.2 KB，**实际只占 959,901 字节**。
   详见 [`docs\Flash布局与镜像一致性.md`](../../docs/Flash布局与镜像一致性.md) §1。
2. **装 loader 会覆盖固件**：`hex2soc.ps1 -Bin ...\loader.bin -Install` 会把 `loader.bin` 写进
   SoC 的 4 个 `ram_symbol*.bin`；这一步之后就**不能再**指望片内 RAM 里跑 `sw\main.c`。
   两种启动方式二选一（见决策文档 §5）。
3. **改 flash 镜像起始地址要改两处**：`build_ddr.ps1 -FlashBase` + `mkimage.ps1 -FlashBase`
   （loader 里的 `MMT_FLASH_IMG_BASE` 由 `build_ddr.ps1` 用 `-D` 自动同步）。
4. **DDR 不是 "0 起始"**：给 CPU 的 DDR 从 `0x00001000` 起，`0x0-0xFFF` 是解码空洞
   （`ip\sapphire_soc\sapphire_soc.v:11628`）。链接脚本的 `ASSERT` 会在链接期拦住这种错误。
