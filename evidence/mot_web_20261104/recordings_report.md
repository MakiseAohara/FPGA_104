# 历史实拍素材审计与回归方法

本轮只运行本机 C 算法与离线素材；没有烧录 FPGA、修改网卡或重新采集现场数据。

## 可用实拍素材

| 回放 ID | 图像来源 | 帧数 | 设备时间间隔中位数 | 原始 IR |
|---|---|---:|---:|---|
| recorded_scene | v29 场景导出的完整 96×96 PNG | 329 | 3260 ms | 未保存 |
| recorded_walk | 旧单人操作日志的 48×48 缩略图，最近邻放大到 96×96 | 79 | 1777.5 ms | 未保存 |
| recorded_two_person | 旧双人操作日志的 48×48 缩略图，最近邻放大到 96×96 | 93 | 1659.5 ms | 未保存 |

三组共 501 帧。审计脚本逐像素比较 `frames.bin` 与原始 PNG ZIP/串口缩略图，全部一致，随后提取设备时间戳和同帧 AI 输出。索引为 `recordings_index.json`，含原文件位置、像素 SHA256 和逐帧元数据。

其中 AI `p` 是模型输出，不是人工人体标签。`p=-128` 可能是暂停推理的占位，不能据此认定画面中无人。IR 没有与这些像素一同保存，因此索引记为 `null`，算法回归输入保守使用 0，不补造人体温度证据。

旧目录中的 `ai.txt=90`、`ir.txt=3` 是素材生成脚本固定写入的数值，**不是实测记录**。本轮评估没有使用它们。

## 能说明什么

`recordings_report.json` 是当前优化版与保留基线的离线回归，记录：

- 有观测且已确认轨迹的输出覆盖率；
- 确认过的 ID 总数及两条确认轨迹同时存在的步数；
- 恰好两个回放样本后的同 ID 后续观测一致性，以及保持当前位置的对照。

这些指标用于发现回退，不能直接解释成人体检测召回率、ID switch、MOTA、IDF1 或真人预测精度。减少 ID 数也可能只是漏掉目标，因此必须同时查看输出覆盖率。

默认回归刻意把相同像素序列按每步 200ms 输入两版算法，便于比较代码变化。这是 **统一节拍的回归条件**，不能把原素材改称 5fps 实拍。`--recorded-time` 可再按原始稀疏设备时戳运行；脚本仍不会生成物理 400ms 预测精度结论。

因为三组实拍中没有相邻间隔小于 500ms 的图像，也没有人工标注的人体框/身份轨迹，无法验证未来 400ms 的实际落点。短期预测与交叉遮挡的定量验收应使用另外生成的、有完整位置真值的合成场景，并明确标注合成来源。

## 已发现并保留的回退

首轮新代码在负向移动时出现异常的大正速度，离线实拍回归看到了沿图像边缘外推与 ID 碎裂。独立检查发现时间参数为 unsigned，和负 signed 速度/位移混算，在 MSVC 和 RV32 的 32 位 long 上会无符号提升。问题已反馈给算法协作者修复，不用调阈值掩盖。

首轮原始差结果保留在 `recordings_report_first_pass.json` 与 `recording_evaluation_first_pass/`，最新结果以 `recordings_report.json` 中记录的源码 SHA256 为准。

## 复现

使用带 Pillow 的 Python 运行（本机 Codex 附带 Python 可用），原生 C 编译器为本机 MSVC：

```powershell
& 'C:\Users\Makise Aohara\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -X utf8 D:\FPGA\motweb04\evidence\mot_web_20261104\evaluate_recordings.py
```

只重建并验证素材索引：增加 `--index-only`。使用原始设备时戳：增加 `--recorded-time --out D:\FPGA\motweb04\evidence\mot_web_20261104\recording_evaluation_recorded_time`。

`recording_replay.c` 是独立可执行回归驱动，不使用网页测试 DLL，不会访问串口或网络设备。
