# sw/tinyml_live —— 实时 TinyML 推理（已验证可用的一套文件）

这一组文件是**板上实测跑通**的组合，配合位流 `p2d_ci.bit` 使用。

## 文件说明

| 文件 | 说明 |
|---|---|
| `tinyml_pdti8.bin` | **已验证的固件镜像**（v9），467,754 字节，CRC32 `D281242E` |
| `load_and_run.py` | 通过片上 UART loader 把镜像灌进 DDR 并跑起来 |
| `build_tinyml_firmware.py` | 从 TinyML 官方工程 + `main_live9.cc` 重新构建固件 |
| `main_live9.cc` | 固件源码（区块平均采样 + 硬件推理 + OSD 输出） |

## 快速使用

### 1. 烧位流

用 `p2d_ci.bit`（SHA256 `04946BC2AE0EA1A4C9BF2F40A95BFCA07B621F27A46C55CC580709FBC2C1D3E3`）。

### 2. 灌固件

**顺序很重要**：先起加载器（它在等 `MMT_BOOT`），再烧位流触发复位。

```powershell
# 窗口 A：加载器
python load_and_run.py --port COM15 --image tinyml_pdti8.bin ^
    --out .\capture --boot-timeout 45 --run-timeout 110

# 窗口 B：烧位流（触发复位，加载器随即开始灌）
```

正常应看到：

```
MMT_BOOT ONCHIP_UART DDR3_WAIT
MMT_DDR_CAL_PASS
MMT_DDR_PASS 256_SCATTERED_WORDS BUS aw=00000100 ar=00000100
MMT_LOADER_READY
MMT_LOAD_PASS DDR_CRC
MMT_LIVE_BOOT v9_osd
MMT_LIVE_HW_READY uuid=0x4923687a
MMT_OSD f=0 chk=... p=... a=... v=... osd=... ci=813352 ms=416
```

> UART 上传超过约 65 KB 后偶发中断（block ~1000 处），**重试即可**，不是镜像问题。

### 3. 重新构建固件

**必须走短路径**，否则 Windows 260 字符路径上限会让 112 个源文件全部报
"No such file or directory"（而文件其实存在）。

```powershell
python build_tinyml_firmware.py ^
  --project   D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world ^
  --toolchain D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin ^
  --out       D:\FPGA\codex20\fw_out ^
  --main-source D:\FPGA\codex20\fw_src\main_live9.cc
```

## 关键实现点（main_live9.cc）

1. **帧缓冲地址**：`0x01000000` + `bank × (960×1080×4 + 0x200)`，读 `bank2`
2. **亮度通道**：32 位字的 **byte0**（低字节）；RGB565 的解释已被 A/B 实验排除
3. **下采样必须用区块平均**：每个输出像素取对应 10×11 区块内 5×5 共 25 点求均值。
   **点采样会让分类逐帧乱跳**（人的竖直结构被切碎）。
4. **输入写入方式**：`(int8_t)byte`，纯位重解释 —— 与 TinyML 官方静态示例一致，
   **不要减 128**。
5. **OSD**：每帧把判决写到 APB `0xF8100024` bit0，驱动红框。

## 相关文档

- `docs/交接-实时TinyML推理-2026-10-20.md` —— 完整交接（帧格式、坑、寄存器表）
- `project/README.md` —— 完整工程与重建步骤
