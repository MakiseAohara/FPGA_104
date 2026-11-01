# T4 低功耗（v29.2 定版）

> 固件：v29.2 DAY，306,194 B，CRC32 `C15D47FD`
> 位流：`v7_MERGE17.bit`，SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`
> 采集：`tools/capture_session.py`，日志 `out/session_20261101/serial.log`（12.3 MB，主机时间戳）

**做什么**：空场静置 ≥90 s，看 LP 进入与 VTS 拉长；人走入看恢复；3 次。

**日志实测（17:14–18:00）**：
- `MMT_LP_ENTER` **6 次**；
- `lowpwr=1` 累计 **40.4 分钟**（窗口 46 分钟，占 87%）；
- `MMT_LPCAM enter vts=0x5dc->0x1194 mult=3` 与 `exit vts restored=0x5dc` 反复出现（30 次事件）；
- 该窗口仅 2 次报警、AI 判人帧 3。

**已知限制**：VTS 写入读回一致，但 `camfps` 全程 59–60，**帧率未实际下降**（与 `out/lp7/report.md` 一致）。

**结论**：进入/退出逻辑正常；"降帧"与屏幕 `EVT=LOWPWR` 需人工确认。
