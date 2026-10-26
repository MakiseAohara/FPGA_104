# v25 自由进出采集

用户最终选择自由进出，不要求 ENTER/LEAVE 提示或事件标记；动作有效性及报警判定由 Claude / 操作者事后分析。

- `log_v25_gate.log`：同一份追加日志，包含最初零字节接入、USB 断开/重连、主机读进程重启、后续获准的原始位流/固件加载及正式记录窗口。串口行带北京时间；`###` 为主机记录。
- `uart_bytes.bin`：行读取器收到的原始字节，保留 LF/CR。固件上传期间直接消费的块 ACK 不在此文件内；它不是 UART 总线的双向抓包。初始被动阶段接收字节数为零。
- `ticks.csv`：device_ms,motion,area,p,person,alarm,lp。p 按同分段同帧匹配；不把上一帧分数填入下一帧。lp 优先使用固件 fw_lp。
- `ai_samples.csv`：实际 MMT_AI 行与同帧设备 ms；与 MMT_OSD 中出现 p 的行区分。
- `frames/`、`frames.csv`：完整原始 96×96 灰度转储及设备 ms/帧号/p 索引。
- `contact_sheet_p*.png`：每页最多 40 张完整转储图。
- `summary.md`：开机原始行、MMT_ALARM 原始事件与区间、低功耗事件、每 60 秒亮度中位数及运动/AI 采样统计、GAP/重连数。没有动作有效性或检测效果判定。
- `history/`：最初零字节阶段的执行脚本与元数据，保留主机读进程重启前的快照。
- `manifest.json`：文件 SHA256 与字节数；不包含 manifest 自身。

`capture_v25.py` 是默认被动采集脚本，只打开和读取串口，不调用刷写、复位、串口写入或动作提示。启动后无数据时最多三轮被动打开；已有运行中日志时不要求重新出现开机行。

本次最初被动接入持续零字节；用户随后报告显示屏无显示并指示尝试重烧。因此实际恢复阶段使用 `capture_after_flash.py`：先校验原始 v19 dump CRC/SHA 和原位流 SHA，再执行既有加载流程，随后沿用同一串口读缓冲立即观察 600 秒。没有重新编译、修改曝光/AE，或上传后复位；捕获中的断线只重连，不重刷。未修改或增加 MMT_CAM 固件打印。

离线重建（需要 Pillow）：

```text
python evidence/v25_gate/build_v25.py --evidence evidence/v25_gate
```

`test_capture_v25.py` 的四项离线检查使用模拟串口和合成图像，不接触设备；实际结果见 `offline_checks.log`。`verify_v25.py` 对本次产物做完整性核对，不评估检测效果。
