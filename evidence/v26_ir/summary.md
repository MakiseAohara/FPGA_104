# v26 红外只读源码核查

本阶段未编译/刷写红外诊断固件，未上板，未改 RTL。

v25：876/876 body=450，876/876 irhot=1，SHT 有 4 种读数。

450 是 RTL 估算温度的上限夹值。APB valid 为保持位；真正帧计数、错误状态及像素 RAM 未映射 CPU。

完整结论与阻塞见 comms/codex/20261026_v26_ir_source_diagnosis.md；可复核出处与计数见 source_audit.json。
