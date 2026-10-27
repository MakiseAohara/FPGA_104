# 错误与派生处理记录

- 采集期间出现 `SerialException("ClearCommError failed (PermissionError(13, '拒绝访问。', None, 5))")`，主机持续自动重连，不重新刷写或复位；最终4个GAP、20次重连，原文和未完成的字节片段在原始日志/uart_bytes.bin。
- 首次重连后的完整缩略图缺少同帧DEC，实时预览曾触发 `AssertionError: Thumb must match same-frame decision clock`；解析器已改为保留该缩略图自己的 t/f/alarm/p，并将 dec_status 标为 missing，没有补造DEC或改写头部。
- 最终完整缩略图649张，格式错误行0；其中1张缺DEC、0张头部与DEC不一致，3个带MMT_THUMB头的未完成片段只保留原始字节，没有生成缺像素图像。
- 全部接收字节与连续时间戳日志一致，649张PNG均与对应MMT_THUMB像素一致，53张还有同帧96×96原图可逐像素核对2×2均值；所有这些核对通过不表示检测效果通过。
- run_metadata_as_recorded.json 保留采集器原始计数；run_metadata.json 的 dec_records/v28_dec_records 是离线排除加载前旧v26行后的数量，原内部计数另记为 capture_internal_dec_counter。
