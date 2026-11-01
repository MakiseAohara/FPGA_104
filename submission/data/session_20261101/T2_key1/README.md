# T2 KEY1（日/夜）

> 固件：v29.2 DAY，306,194 B，CRC32 `C15D47FD`
> 位流：`v7_MERGE17.bit`，SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`
> 采集：`tools/capture_session.py`，日志 `out/session_20261101/serial.log`（12.3 MB，主机时间戳）

**做什么**：夜→人进（应报警）→KEY1→昼→人进（不应报警）→KEY1 回夜，3 轮。

**日志能证明**：窗口内报警 21 次、有人帧 335。

**日志证明不了**：RTL 的 day/night 状态不进串口（只在开机打印 `MMT_CAM_PRESET name=DAY`），切换后的报警差异需现场确认。

**结论**：未确认。
