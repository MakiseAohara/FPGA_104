# lp7 — 低功耗专项实测

- 测试内容：A 空场 240 s / B 有人 60 s / C 离开 120 s，验证低功耗状态机与摄像头降帧。
- 固件：v29.2 DAY 定版 `C15D47FD`；位流 MERGE17（未改任何代码）。
- 时间：见 `manifest.json`。
- 结论：状态机走通（`fw_lp=1`@17.0 s、`MMT_LPCAM enter`@24.6 s，VTS 0x5dc→0x1194×3）；**camfps 仍 59–60**（未真正降帧）；A 段 2 次报警。
- 原始日志：`serial.log`（1.29 MB）；`report.md`；`lp7.png`；`capture_lp7.py`。
- 对应技术文档：低功耗机制与"VTS 写入但 camfps 不变"的解释。
