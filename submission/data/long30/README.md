# long30 — 30 分钟自由行走采集（低功耗记录）

- 测试内容：自由走动 30 分钟，记录低功耗进入/退出、推理节拍、航迹。
- 固件：B=0x1A4 的 DAY 版 `3D334E58`（306,442 B）；该目录另含 AE=1 过曝版对照日志。
- 时间：2026-10-29 16:46–18:03（多段）。
- 结论：低功耗状态机 21 次进入/恢复（`MMT_LP_ENTER` 21）；**VTS 写入 4500 但 camfps 仍 59–60**（camfps 取自 vs 计数，不随 VTS 变）；AE=1 版出现 0x802a→0x8f8c 过曝。
- 原始日志：`serial.log`（5.90 MB）、`serial_v292_ae1_overexposed.log`（5.44 MB）、`serial_b0x1C4_aborted.log`（0.95 MB）；`thumbs/` 807 张；`boot_v292_b0x1A4.log`。
- 对应技术文档：低功耗机制说明、`log_lp2.txt` 的 707 s/30 区间统计来自本目录。
