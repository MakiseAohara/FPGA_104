# FPGA_104 — 多模态 AI 入侵检测智能终端（整理版）

本仓库是一套基于 **Ti60F225 FPGA** 的边缘智能终端工程：摄像头采集 + 红外/温湿度多模态传感 + 轻量神经网络人体检测 + 加权融合判决 + 低功耗场景管理，并提供完整的离线评估数据与证据链。

## 1 作品简介

- **视觉通路**：MIPI 摄像头 1080p → 去马赛克 → 白平衡 → DDR3 帧缓存 → OSD 叠加 → HDMI（60 fps）。
- **传感器通路**：MLX90640（32×24 红外）+ SHT30（温湿度）挂在同一组 I2C，由 RISC-V 软核调度。
- **AI**：96×96 单通道 INT8 人体检测网络（5 卷积 + GAP + 2 FC，95,922 参数），跑在 TinyML 加速器上。
- **判决**：RTL 按 60/25/15 加权投票（Q8 定点 154/64/38，阈值 0.60），RISC-V 固件做多帧投票、红外确认与安静释放。
- **低功耗**：无人时降摄像头 VTS 并暂停推理，检出即恢复。
- **定版**：固件 CRC32 `C15D47FD`（306,194 B），位流 MERGE17 SHA256 `3A69AAFB…887CF`。

## 2 目录结构（二级）

```
FPGA_104/
├── submission/                 提交用整理目录
│   ├── data/                   原始采集数据（每项一个文件夹）
│   │   ├── proto7/             七阶段带标签采集（340 s）
│   │   ├── empty30/            30 分钟空场
│   │   ├── short5_fp/          5 分钟场景
│   │   ├── long30/             30 分钟自由行走（低功耗记录）
│   │   ├── lp7/                低功耗专项（A/B/C 三段）
│   │   ├── mot_offline/        v30 MOT 离线日志（A–E / D,E）
│   │   └── mot_board/          v30 MOT 上板日志（board_v30f、run1–3）
│   ├── firmware/               v29_2 定版、v30_mot
│   ├── rtl/                    merge17（定版）、merge16
│   ├── model/v29_model/        训练/量化/评估
│   ├── tools/                  采集/评估/查看脚本
│   ├── NUMBERS_SOURCE.md       技术文档数字出处核对表
│   └── OSD_AUDIT.md            OSD 三行调研
├── evidence/                   历史证据（早期版本 + 已迁移项留在 MOVED.md）
├── docs/                       技术文档、设计文档、提交材料
├── comms/                      协作交接记录
├── sw/ rtl/ sim/ tools/ constr/  源码与约束
├── INDEX_DRAFT.md              整理前目录盘点
└── README.md
```

## 3 如何复现

1. **烧位流**：`tools/flash_vendor.ps1 -Bit <v7_MERGE17.bit> -Sha256 3A69AAFB…887CF`（JTAG，只烧 .bit）。
2. **下载固件**：`tools/load_v30.ps1`（v30）或串口 UART 上传（v29.2，见 `submission/firmware/v29_2/FINAL.md`）。
3. **采集**：`submission/tools/capture_mot.py`（MOT）或串口直接记录（v29.2 日志带毫秒时间戳）。
4. **评估**：`submission/tools/pred_eval.py`、`align_eval.py`（MOT 预测/预警）、`submission/model/v29_model/` 内脚本（模型）。

## 4 数据索引

| 项目 | 文件夹 | 固件/位流 | 结论一句话 |
|---|---|---|---|
| 七阶段带标签采集 | `submission/data/proto7` | `C15D47FD` / MERGE17 | 空场 0 次可见报警；站定/慢走可触发；离开 4–7 s 解除 |
| 30 分钟空场 | `submission/data/empty30` | `C15D47FD` / MERGE17 | 触发 21 次（9 真人 / 11 红外强确认 / 1 未归类）；低功耗未进入 |
| 5 分钟场景 | `submission/data/short5_fp` | `3D334E58` | 170 缩略图；AE/GAIN 零异常 |
| 30 分钟自由行走 | `submission/data/long30` | `3D334E58` | 低功耗 21 次进入/恢复；camfps 仍 59–60 |
| 低功耗专项 | `submission/data/lp7` | `C15D47FD` / MERGE17 | 状态机走通（17 s 进入、VTS×3），摄像头帧率未真正下降 |
| MOT 离线 | `submission/data/mot_offline` | `E6535D37` | 基线：下一帧 3.87/23.41 px，ROI 47 进 6 中 |
| MOT 上板 | `submission/data/mot_board` | `E6535D37` | 七段验收日志（PREP…EXIT） |
| 模型 | `submission/model/v29_model` | — | 95,922 参数 INT8；F 段 98.1%、白天 94.6%、COCO 70.0% |
| 定版 RTL | `submission/rtl/merge17` | `3A69AAFB…887CF` | XLR 70.49%、setup −0.984 ns、hold 7 条 |
| v30 MOT | `submission/firmware/v30_mot` | `E6535D37` | 第二轮基线 + 第三轮离线改动（宏开关） |

## 5 说明

- 本仓库只做整理，未改动任何固件/RTL/模型逻辑与数值；`evidence/` 中早期版本目录原样保留。
- 迁移过的目录在原位置留有 `MOVED.md` 指向新位置。
