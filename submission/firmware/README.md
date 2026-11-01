# firmware — 固件源码与构建

## v29_2（定版）

- 源码：`main_live292.cc`（板子最终跑的那一份：`AUTOEXP_ON=0`、`GAIN_AUTO_ON=1`、`GA_TARGET=100`、`GA_GMAX=8176`、WB 0x158/0x118/0x1A4、IR 确认与安静释放三处改动）。
- 构建：`build_v292.py`（`python build_v292.py DAY`），自检 `check_v292.py`。
- 产物：`tinyml_pdti8_v292_day.bin` **306,194 B / CRC32 `C15D47FD`**；`FINAL.md` 记录全部宏值。
- 构建前置：SoC 工程树复制到无空格短路径；`WORK` 指向英文路径（中文路径会导致 ld 写 elf 失败）。

## v30_mot（v30 多目标跟踪，离线）

- 源码：`mot_core.h`、`main_live30.cc`、`test_mot.c`、`replay_mot.c`。
- 构建：`build_v30.py --project <工程树> --out <输出>`（需要 RISC-V 工具链）。
- 产物：`fw_v30_final.bin` **318,322 B / CRC32 `E6535D37`**（第二轮）；第三轮改动在 `v30-r3-offline` 分支，未编译新固件。
- 报告：`FIX_REPORT.md`（含第九节）、`R3_BOARD_CHECK.md`（上板清单）。
