# v26 分段采集与离线候选

现成候选 tinyml_pdti8_v26.bin 的 CRC32 为 B7CCB8D0，477,722 字节。本次未重编译、未修改固件源、RTL、位流或曝光；只重新加载原 MERGE14 位流及该候选。上传后未复位，断线处理仅重连、不重刷。

正式记录：2026-10-26 19:42:45.726–19:52:45.739（Asia/Shanghai），600.013 秒。

## 文件

- log_v26_gate.log：带墙钟的连续原始串口行与主机记录；加载前旧固件数据也保留。
- uart_bytes.bin：行读取器收到的原始字节；上传时另行消费的块 ACK 不包含在内。
- ticks.csv、ai_samples.csv：仅新候选启动后的 DEC 和实际 AI 采样；加载前旧固件数据不混入。
- frames/、frames.csv、contact_sheet_p*.png：完整 96×96 原始转储、设备 ms/帧号/p 索引；每页最多 40 张。
- script_prompts.csv：脚本计划提示及实际发出墙钟，不是人体动作真值。
- manual_events_raw.csv：仅人工按钮点击原始时刻；manual_timetable.csv 另列最近 DEC、插值设备 ms 和窗口内外标志，不改原时刻。
- MANUAL_ANNOTATIONS_PENDING.md、annotation_status.json：当前人工记录缺口；没有用脚本计划、运动或 AI 结果补造。
- summary.md：开机/配置行、全部报警和低功耗事件、每 60 秒亮度及运动/AI 事实、采集计数、人工记录状态；不作有效性或效果判定。
- offline/：上板前的离线说明和清单。replay/、replay_results.json、release_prolongation.json 属于此前针对 v25 的离线反事实回放，不是本次现场记录。
- manifest.json：保留候选及函数哈希，并列出本目录文件 SHA256/字节数。启动文本保留 v19，按 CRC/SHA 与 AREA=[200,20000] 区分候选；IMG_DUMP_EVERY 保留 40。

## 当前状态

串口采集完成，GAP 0、重连 0。测试期间人工标注仍缺失；现有两条点击都在结束后。本次人工时间表要求尚未满足，未据此计算实际在场覆盖率或释放延迟。

离线重建需要 Pillow：

```text
python evidence/v26_gate/build_v26_board.py --evidence evidence/v26_gate
python evidence/v26_gate/verify_v26_board.py
```

capture_v26.py 会加载候选并执行分段提示；本次已运行一次，未再次启动。manual_label_panel.ps1 记录点击当时，不能用于回填已经发生的动作。
