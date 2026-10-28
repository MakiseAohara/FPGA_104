# v29 场景采集原始字节导出（10/28 更正）

MMT_IMG 的字节就是 0..255 灰度像素 u。preprocess_core.h 的 out[i]=(signed char)u 仅改变 C 类型，不改变字节。7997140 那组 int8+128 显示换算已撤回；PNG 不加 128、不翻转 int8。

固定采集参数：VTS=1500、exp20=47824（2989 半行）、gc=0x81、gf=0x3F，采集中无 AE。临时固件每 3 轮转储，正式固件恢复每 40 轮。六段开始/结束约为 2026-10-27 20:31:28–20:49:28（UTC+8），具体墙钟、设备 ms 和参数见 segment_events.csv 的 MMT_MARK START/END/STATE。

严格解析后共 329 张：A=56、B=55、C=55、D=53、E=55、F=55。原宽松解析把断线两侧残片拼成 D_t0689078_p19.png，该图已从数据集中剔除并在本地隔离；原始日志保持不变。所有完整图重新导出到 frames/，frames_v29_scene.zip 同步更新，各段每页最多 60 张。verify_frames.py 核对全部 329 张 PNG 与日志的逐字节一致性。

export_scene.py 在新图头、GAP、断线、错行处丢弃残片，不跨断线拼接。文件名带设备 ms、段号和日志 p；p 可能是低功耗无推理时的 -128 哨兵，不能作为真值。

A–F 是要求执行的场景流程，不自动转换为人员标签。场景内容、在座背景人员、入侵者、衣服和动作由 Claude 看图判断，不凭阶段或 AI 分数生成训练标签。

重新导图：python export_scene.py；完整核对：python verify_frames.py。完整 log_v29_scene.log、备用分片及 ZIP 均保留原采集内容；换行形式的差异不能代替像素比较。
