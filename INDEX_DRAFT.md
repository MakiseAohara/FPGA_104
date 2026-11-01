# INDEX_DRAFT — 仓库内容索引（整理前）

> 本文件是整理前的目录盘点：每个目录是什么、属于哪个项目、是否含原始日志。
> 整理后的正式索引见根目录 `README.md` 与 `submission/` 各子目录 README。

仓库根：`D:\FPGA\易灵思\工作区\_外部仓库\FPGA_104`（相对路径以下均相对仓库根）。

## 1 顶层目录

| 目录 | 内容 | 归属 |
|---|---|---|
| `evidence/` | 逐版本实验证据（构建报告、采集日志、截图、RTL 快照） | 全部项目，按版本号 |
| `out/` | 采集输出（`lp7/`、`mot_check/`） | 低功耗、v30 MOT |
| `comms/` | 各协作者交接说明（`claude/`、`codex/`、`dsh/`） | 协作记录，非数据 |
| `docs/` | 技术文档、设计文档、提交材料、阶段分析 | 文档 |
| `project/` | `v7_camera_ai/`（早期工程骨架） | 早期 |
| `sw/` | 固件（`main.c`、`tinyml_live/`、`build_tinyml_firmware.py`） | 固件源码 |
| `rtl/mmt/` | 自研 RTL（sensors/algo/osd/alarm/soc/video） | RTL 源码 |
| `sim/` | RTL 仿真（i2c/红外/SHT30/debayer/frame_wr） | 仿真 |
| `tools/` | 采集、评估、构建、烧录脚本 | 工具 |
| `constr/` | `ti60f225_oob.peri.xml` / `.sdc` / `.interface.csv` | 约束 |
| `patches/` | `0001-cut-tinyml-for-ice0.patch` 等 | 补丁 |

## 2 evidence/ 各版本目录（按项目）

### 2.1 早期迭代（v7 工程打通、颜色/帧缓存/白平衡）

| 目录 | 内容 | 项目 |
|---|---|---|
| `ab_v16/` | v16 版 A/B 测试帧与统计 | 早期 AI 判决 |
| `merge12_v17/` `merge14_v18/` `merge14_v18_dump/` | MERGE12/14 构建与回放 | 早期 |
| `v19/` `v19_board/` `v20/` `v20_ae/` `v21_sweep/` `v22_gate/` `v23_offline/` `v24_wb/` | 各版本上板/离线记录 | 早期（v19–v24） |

### 2.2 带标签采集（gate 系列，含缩略图与人工标注）

| 目录 | 内容 | 项目 |
|---|---|---|
| `v25_gate/` | 84 帧缩略图 + 标注 | 第一轮 gate |
| `v26_gate/` | 28 帧 + 固件 | 第二轮 gate |
| `v27_gate/` | 15 帧 + 回滚日志 | 第三轮 gate |
| `v28_gate/` | 16.3 MB，缩略图 + CSV | 第四轮 gate |
| `v22_gate/` | 早期 gate | 早期 |
| `v26_ir/` | 红外对照 | 红外 |
| `v27_rtl_ir/` | **MERGE15** 源码 diff + 位流 + tb | 红外 RTL |

### 2.3 v28 固件与预处理

| 目录 | 内容 | 项目 |
|---|---|---|
| `v28_fw/` | v28 固件源码、构建日志、`preprocess_core.h` | 固件 |
| `v29_gap/` | 预处理样本 | 预处理 |

### 2.4 v29 定版与三轮采集（本轮提交核心）

| 目录 | 内容 | 项目 |
|---|---|---|
| `v29_1/` | 11.4 MB，v29.1 采集 | v29 早期 |
| `v29_2/` | 20 MB，含 `long30/`（30 分钟自由行走采集，serial.log 5.9 MB + 767 缩略图） | **低功耗/自由行走** |
| `v29_3/` | 18.3 MB，含 `proto7/`（七阶段 340 s，serial.log 1.86 MB + 196 缩略图）、`empty30/`（30 分钟空场，serial.log 9.78 MB + 1043 缩略图）、`short5_fp/`（300 s） | **带标签采集 / 空场** |
| `v29_bright/` | 亮度闭环实验 | 亮度 |
| `v29_day_scene/` | 白天场景采集 | 场景 |
| `v29_gate/` | 23.7 MB，gate 采集（含 226 ms/invoke 记录） | 推理性能 |
| `v29_scene/` | 22.4 MB，六段场景（A–F）+ 原始串口日志 8.2 MB | 场景模型 |
| `v29_wb_photo/` | 白平衡实物对照照片 | 白平衡 |
| `v29_fw/` | 18 MB，v29.2 定版源码、构建脚本、`FINAL.md`、bin/elf | **v29 固件定版** |
| `v29_model/` | 模型训练/量化/评估记录、tflite、generator 产物 | **AI 模型** |
| `v29_rtl_display/` | **MERGE16** 位流 + 时序/资源 + APB 寄存器表 | RTL 显示 |
| `v29_rtl_ir_rot/` | **MERGE17** 位流 + 时序/资源 + 转置仿真 | **RTL 定版** |

### 2.5 v30 多目标跟踪（离线）

| 目录 | 内容 | 项目 |
|---|---|---|
| `v30_mot/` | 12.3 MB，`mot_core.h`、`main_live30.cc`、`test_mot.c`、`replay_mot.c`、`FIX_REPORT.md`、`R3_BOARD_CHECK.md`、`fw_v30_final.bin`、`board_v30f/`、`accept_20261031/`、`replay_reid/` | v30 MOT |

## 3 out/

| 目录 | 内容 | 项目 |
|---|---|---|
| `out/lp7/` | 低功耗 lp7 采集（1.24 MB，含 report.md、serial.log） | **低功耗 lp7** |
| `out/mot_check/` | MOT 离线评估数据：`serial_A-E_v30q.log`、`serial_DE_v30s.log`、`r3_offline/`（本轮离线输出） | **v30 MOT 离线** |

## 4 原始串口日志清单（必须完整保留）

| 日志 | 位置 | 大小 |
|---|---|---|
| proto7 | `evidence/v29_3/proto7/serial.log` | 1.86 MB |
| empty30 | `evidence/v29_3/empty30/serial.log` | 9.78 MB |
| short5_fp | `evidence/v29_3/short5_fp/serial.log` | 1.60 MB |
| long30 | `evidence/v29_2/long30/serial.log` | 5.90 MB |
| long30（旧固件） | `evidence/v29_2/long30/serial_v292_ae1_overexposed.log` | 5.44 MB |
| long30（中止） | `evidence/v29_2/long30/serial_b0x1C4_aborted.log` | 0.95 MB |
| lp7 | `out/lp7/serial.log` | （见目录） |
| MOT A–E | `out/mot_check/serial_A-E_v30q.log` | 2.31 MB |
| MOT D/E | `out/mot_check/serial_DE_v30s.log` | 0.39 MB |
| board_v30f | `evidence/v30_mot/board_v30f/serial.log` | 1.59 MB |
| accept run1–3 | `evidence/v30_mot/accept_20261031/run{1,2,3}_v30*.log` | 2.2/1.9/2.1 MB |

## 5 文档

| 目录 | 内容 |
|---|---|
| `docs/`（48 个文件） | 工程分析、交接、设计说明、`②⑤设计说明.md`、`工程全貌与学习地图.md`、`代码学习地图.md` 等 |
| `docs/提交材料/` | `任务书对照表.md`、`待补清单.md`、`视频分镜脚本.md`、`设计文档-初稿.md`、`数据出处核对表.md`、`数据出处查证.md`、`设计文档.docx/pdf/md` |
| `docs/evidence/` | 早期 evidence 副本 |
| `docs/patches/` | `ALL_FIXES.diff` |

## 6 代码

| 目录 | 内容 |
|---|---|
| `sw/` | 固件 `main.c`、`tinyml_live/`（`build_tinyml_firmware.py`、`main_live*.cc` 历史版本）、`mmt_regs.h` |
| `rtl/mmt/` | 自研 RTL：`sensors/`（I2C/SHT30/MLX90640）、`algo/`（帧差/融合）、`osd/`、`alarm/`、`soc/`、`video/` |
| `sim/` | I2C 从机模型、MLX90640 模型、debayer/frame_wr 测试台 |
| `constr/` | 引脚约束（peri.xml）、SDC、interface.csv |
| `tools/` | 采集（`capture_mot.py`）、评估（`pred_eval.py`、`align_eval.py`、`diag_two_target.py`）、构建（`v7_flow.ps1`、`build_mmt.ps1`）、烧录（`load_v30.ps1`、`flash_vendor.ps1`） |

## 7 协作记录

| 目录 | 内容 |
|---|---|
| `comms/` | `claude/`、`codex/`、`dsh/` 交接说明、`STATUS.md`、`URGENT.md`、`MERGE16_ir_display.md` |

---

## 8 整理迁移映射（整理后）

| 原位置 | 新位置（`submission/`） |
|---|---|
| `evidence/v29_3/proto7/` | `data/proto7/` |
| `evidence/v29_3/empty30/` | `data/empty30/` |
| `evidence/v29_3/short5_fp/` | `data/short5_fp/` |
| `evidence/v29_2/long30/` | `data/long30/` |
| `out/lp7/` | `data/lp7/` |
| `out/mot_check/` | `data/mot_offline/` |
| `evidence/v30_mot/board_v30f/`、`accept_20261031/` | `data/mot_board/` |
| `evidence/v29_fw/` | `firmware/v29_2/` |
| `evidence/v30_mot/`（源码部分） | `firmware/v30_mot/` |
| `evidence/v29_rtl_ir_rot/`、`v29_rtl_display/` | `rtl/` |
| `evidence/v29_model/` | `model/` |
| `tools/`（采集/评估） | `tools/` |

> 注：`evidence/` 其余早期版本目录原样保留在 `archive/`，不删除。
