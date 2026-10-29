# v29.2 DAY 固件（WB R/G/B = 0x158 / 0x118 / 0x1C4）

## 1. 固件

| 项 | 值 |
|---|---|
| 文件 | `tinyml_pdti8_v292_day.bin` |
| 大小 | **305,106 B** |
| **CRC32** | **D7FE2D36** |
| SHA256 | `FCC20A3ECE2C43CAA6BBB178CBE0CED20FB53A21F5784FC59A2FD990A8A759A1` |
| 模型 | v29 第二轮（day-calibrated）`v29_person_96_int8.tflite`（101,088 B，SHA256 A78BB07C…41C5） |
| 相机 | VTS=1500、EXP20=47824、GC=129、GF=42（DAY 预设） |

- 白平衡三通道（`main_live292.cc` L696/699/702）：**R=0x158，G=0x118，B=0x1C4**；其余宏未改（`GAIN_AUTO_ON` 保持 0）。
- 构建：`python build_v292.py DAY` → `FIRMWARE BUILD PASS`。
- 自检：`python check_v292.py` → **SELFCHECK PASS**（模型字节已嵌入、旧模型不在、`MMT_WB_INIT`/`IR_SOLO_ON=%d`/`cause=%s`/`v29.2`/`MMT_HOTSRC`/`hotsrc=%d`/`MMT_LPCAM enter` 全部在位）。

## 2. 本机环境适配（仅路径，不改逻辑）

- `PROJECT` 由 `D:\FPGA\codex20\...` 改为本机可构建副本 `D:\v7work\tiny_proj`（含 `bsp/efinix/EfxSapphireSoc`）。
- `WORK` 由仓库旁目录改为 **`D:\v292_build`**：原路径含中文（`易灵思`），riscv-none-elf `ld.exe` 写输出时 `No such file or directory`。
- `check_v292.py` 的旧模型路径同步指向 `D:\v7work\tiny_proj`。

## 3. 长采集（30 分钟自由走动）——**未执行，阻塞**

- 本机**没有板载 FTDI 串口**：`Get-PnpDevice` 无 `VID_0403` 设备，`Win32_SerialPort` 只有蓝牙 COM4/5/6/8/9/11（无 COM13–16）。
- 因此本轮**没有** `serial.log`、没有缩略图；采集需等板子接回本机（队友烧录 MERGE17 + 本 DAY 固件后）再跑。
- 采集脚本已就位：`evidence/v29_fw/capture_v29.py`（默认 `--port COM15`，可在有板子时改端口执行）。

## 4. 烧录顺序（队友）

1. 先烧 **MERGE17** 位流：`evidence/v29_rtl_ir_rot/v7_MERGE17.bit`（SHA256 `3A69AAFB…887CF`）。
2. 再加载本固件：`tinyml_pdti8_v292_day.bin`（CRC32 `D7FE2D36`）。
3. 跑 30 分钟：自由走动、无上位机，串口日志 + 缩略图回传本机后补进本目录。

## 5. 文件清单

```
evidence/v29_2/long30/
├── tinyml_pdti8_v292_day.bin    305,106 B  CRC32 D7FE2D36
├── tinyml_pdti8_v292_day.elf
├── day_build.log                构建日志（FIRMWARE BUILD PASS）
├── link.log / size.txt / elf-info.txt
├── firmware_identities_v292.json
├── selfcheck_v292.json          SELFCHECK PASS
└── README.md
```
