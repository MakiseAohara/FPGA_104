# code_package — 提交用代码包

> 本目录是整理后的提交代码包（脱敏版）。压缩包 `code_package.zip` / `.rar` 不入 git。

## 目录

```
code_package/
├── firmware/
│   ├── v29_2/           v29.2 DAY 定版固件源码（CRC32 C15D47FD，306,194 B）
│   └── v30_mot/         v30 多目标跟踪（第二轮 fw_v30_final E6535D37；第三轮离线改动）
├── rtl/                 MERGE17 定版 RTL 改动（rtl.diff、顶层、OSD、txt_fmt）
├── model/               v29 人体检测模型：训练/量化/Generator 脚本与指标
├── tools/               构建、烧录、采集、评估脚本
└── logs/                核心测试报告（完整原始日志在仓库 submission/data/ 下）
```

## 编译固件（v29.2）

```
python build_v292.py DAY          # 在 firmware/v29_2/ 下执行
python check_v292.py
```

前置：SoC 工程树（`Ti60F225_tinyml_hello_world`）复制到无空格短路径；模型 `v29_person_96_int8_model_data.{cc,h}` 放到 `.../tinyml_pdti8/src/model/` 与 `.../src/generator/`；RISC-V 工具链放在 `TOOLS:\riscv\...`。

产物：`tinyml_pdti8_v292_day.bin`，期望 **306,194 B / CRC32 C15D47FD**（不符即构建环境有问题）。

## 编译固件（v30 MOT）

```
python build_v30.py --project <工程树路径> --out <输出目录>
```

宏开关（改动 `MOT_V15_SPEED / MOT_V15_ENTRY / MOT_V15_MERGE / MOT_V15_GATE`，默认全 1；置 0 回到第二轮行为）。
产物 `fw_v30_final.bin`（第二轮）期望 318,322 B / CRC32 `E6535D37`；第三轮版本需自行记录 CRC32。

## 烧录

1. 位流（JTAG，只烧 .bit）：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\flash_vendor.ps1 -Bit <v7_MERGE17.bit> -Sha256 3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF
   ```
2. 固件：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools\load_v30.ps1 -Bit <bit 路径> -Fw <fw bin> -Port COM15
   ```
   成功判据：`MMT_LOAD_PASS`、`MMT_WB_INIT r=344 g=280 b=420`、`MMT_LIVE_BOOT ... AE=0`。

## 单元测试（主机侧）

```
cc -I firmware/v30_mot -o test_mot.exe firmware/v30_mot/test_mot.c
./test_mot.exe        # 期望 MOT_TESTS PASS (fails=0)，23 项
```

## 采集与评估

- `tools/capture_mot.py`：串口采集。
- `tools/pred_eval.py`、`align_eval.py`：预测误差 / ROI 预警 / 误预警统计。
- `tools/mot_view.py`：日志可视化。
