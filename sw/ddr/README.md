# `sw\ddr\` — 固件「跑在 DDR 里」的草案工具箱

> 这一目录是 **草案**，不影响现状：现有 `sw\link.ld`（固件固化进片内 RAM 0xF9000000）
> 一个字都没改，仿真/上板仍在用它。等 DDR 启动链路真正跑通、验证过，再决定是否切换。
>
> 方案正文（内存图、bootloader 疑点、flash 烧写步骤、证据文件:行）在
> [`docs\DDR固件与模型放置方案.md`](../../docs/DDR固件与模型放置方案.md)。

## 文件

| 文件 | 作用 |
|---|---|
| `link_ddr.ld` | DDR 版链接脚本草案：`ORIGIN = 0x00001000, LENGTH = 1020K`，内含 4 条 `ASSERT` 守卫 |
| `pack_image.ps1` | 把 `固件.bin` + `模型权重.bin` 拼成一个连续 flash 镜像（含自校验与容量红线） |
| `_test_build\` | 本次实测产物（用真固件源码链出来的 ELF/BIN/MAP），可随时删 |

## 已实测（2026-10-11，本机工具链 `D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1`）

### 1. 用 `link_ddr.ld` 链接真固件 —— 通过

```powershell
$tc = "D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$sw = "D:\FPGA\mmt\sw"; $o = "$sw\ddr\_test_build"
$CF = @("-march=rv32im","-mabi=ilp32","-Os","-ffunction-sections","-fdata-sections","-I",$sw)
& "$tc\riscv-none-elf-gcc.exe" @CF -c "$sw\startup.S" -o "$o\startup.o"
& "$tc\riscv-none-elf-gcc.exe" @CF -c "$sw\main.c"    -o "$o\main.o"
& "$tc\riscv-none-elf-gcc.exe" @CF -c "$sw\uart.c"    -o "$o\uart.o"
$LD = @("-march=rv32im","-mabi=ilp32","-T","$sw\ddr\link_ddr.ld","-nostartfiles",
        "-Wl,--gc-sections","-Wl,-Map,$o\mmt_ddr.map")
& "$tc\riscv-none-elf-gcc.exe" @LD "$o\startup.o" "$o\main.o" "$o\uart.o" -o "$o\mmt_ddr.elf"
& "$tc\riscv-none-elf-objcopy.exe" -O binary "$o\mmt_ddr.elf" "$o\mmt_ddr.bin"
```

结果（原始输出）：

```
LINK EXIT: 0
   text	   data	    bss	    dec	    hex	filename
   3089	      0	   9856	  12945	   3291	mmt_ddr.elf

00001000 T _start
00001c14 B _bss_start
00002294 B _bss_end
000022a0 B _stack_bottom
000042a0 B _end
000042a0 B _stack_top
```

段表（`riscv-none-elf-objdump -h`）：`.text@0x1000 / .rodata@0x1ae4 / .bss@0x1c14 / .stack@0x22a0`，
**没有任何一段 VMA < 0x1000**（0x0–0xFFF 是 DDR 解码空洞，见方案文档 §1）。
`mmt_ddr.bin` = 3089 字节（与片内 RAM 版一样大，`.bss`/`.stack` 不进 bin）。

唯一的告警是 `has a LOAD segment with RWX permissions`——单一 MEMORY 区的裸机脚本必然如此，无害。

### 2. `pack_image.ps1` —— 三个分支都实测过

```powershell
# a) 只有固件（先用这一步验证 DDR 能起来）
powershell -File sw\ddr\pack_image.ps1          # -> build\ddr_image.bin, 1,044,480 字节, 自校验 OK

# b) 固件 + 400KB 假权重
powershell -File sw\ddr\pack_image.ps1 -Weights <weights.bin>   # 自校验 OK

# c) 权重 4MB（故意超容量）→ 必须拒绝
powershell -File sw\ddr\pack_image.ps1 -Weights big.bin
#   → 报错 "app+权重 = 5238784 字节，超过可用 4718592 字节（= flash 8MB - 0x380000）"，
#     退出码 1，且**不产生**输出文件（已确认文件不存在）
```

## 切换前必须注意的三件事

1. **先改 SoC IP 的 bootloader，再谈 DDR 启动。**
   `ip\sapphire_soc\source\soc_config:1` 现在是 `bootloader_124K.hex`，它只从 flash 搬
   **124KB**。必须换成 16MB 版本（官方 TinyML 参考设计的做法：
   `settings.json` 里 `HexFile_PathEnable=1'b1` + `HexFile_Path` 指到
   `ref_files/bootloader_16MB/SapphireSoc/bootloader.hex`）。重新生成 IP 之后，
   `hex2soc.ps1 -Install` 灌进去的固件会被**生成器的 bootloader 覆盖**，
   两者只能选一个（见方案文档 §5「两条启动路线」）。
2. **物理 DDR 只有 256MB，不是 3.5GB。**
   3.5GB 是 SoC 的解码窗口；`rtl\ddr3_controller\ddr3_parameter.vh` 的
   `BANK_WIDTH=3 / ROW_WIDTH=14 / COL_WIDTH=10 / DRQ_WIDTH=16 / DRAM_WIDTH=8`
   推出 2 颗 x8 的 1Gb 颗粒 = 256MB（0x00000000–0x0FFFFFFF）。所有地址都必须落在这个范围内。
3. **CPU 写完 DDR 要刷 D-cache。**
   DDR 在 Sapphire 里是**可缓存**的（`sapphire_soc.v:17905` 只把 `0xf8000000`/`0xe1000000`
   标成 IO/非缓存）。固件写完权重/输入张量、硬件加速器要读之前，必须执行缓存刷新；
   官方 TinyML 固件用的是自定义指令：`asm(".word(0x500F)")`
   （`.../evsoc_tinyml_pdti8/src/main.cc:156-158`，调用点 :176 / :196 / :371）。
   我们 SoC 的 `CustomInstruction=1` 已开，同一条指令可用。
