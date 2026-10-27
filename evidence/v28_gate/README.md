# v28 30分钟自由走动原始数据

2026-10-27T17:52:49.814+08:00–2026-10-27T18:22:49.820+08:00（UTC+08:00），持续1800.0秒。

- log_v28_gate.log / uart_bytes.bin：一份连续时间戳日志及收到的原始字节；加载阶段也保留。
- ticks.csv / ai_samples.csv：本次v28的2608条DEC、2097次实际AI采样。ticks保留irhot、ir_cnt；不生成在场真值。
- thumbs/ / thumbs.csv：649条完整MMT_THUMB导出的192×192灰度PNG，像素来自48×48，文件名含device_ms、alarm、p。缺DEC也保留缩略图自身头部。
- thumbs_sheet_XX.png：共11页，每页最多60张，逐图标注device_ms、alarm、p。
- frames/ / contact_sheet_p*.png：额外保留原每40轮96×96转储中可完整恢复的图；不是缩略图的替代品。
- summary.md / verification.json：全部报警/低功耗时刻、亮度统计、GAP/重连、接收字节及图像像素核对事实。

串口累计GAP 4、重连 20；错误原文在原始日志。自动重连没有重新刷写或复位，未补全缺失记录。采集开始前加载的是同一MERGE15位流与v28固件，身份见run_metadata.json及evidence/v28_fw/manifest.json。

本次不要求人工按键或录像，真值由Claude看缩略图判定。低功耗缩略图是新采样而非旧帧复用，但无新AI推理时p=-128。t来自同帧DEC；CPU采样、推理与UART发送存在先后，接收墙钟另存于thumbs.csv。

capture_v28.py使用单个串口接收程序，断线只重连；build_v28_gate.py、derive_thumbs.py、verify_v28_gate.py在停止后导出并核对。offline_checks.log使用临时目录的模拟协议数据，不属于实测。当前无采集进程占用COM15，数据已关闭保存。
