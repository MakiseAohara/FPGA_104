# 网口与网页修复交接（2026-11-04）

当前两端都已上机验证，板卡保持运行本轮新版本。

| 用途 | 地址 | 实测结果 |
|---|---|---|
| PC 监控页 | http://169.254.47.62:8090/ | HTTP 200，串口 COM15＋UDP 8080 双通道；温度、事件和画面可更新 |
| FPGA 内部网页 | http://169.254.47.63/ | 页面、状态 JSON、96×96 PNG 两轮共六项全通过 |
| 板内并发访问 | /api/state 与 /frame.png 同时请求，三轮 | 六项全通过，约 0.02–3.35 秒 |
| 网络连通 | ping 169.254.47.63，5 次 | 5/5 收到，0–1ms |
| 摄像头与显示 | 新位流 | 用户确认 HDMI 实时画面与叠加正常 |

PC 与板卡页面均来自同一份 tools/page.html，当前 12,131 字节，SHA256 `6DD4C5FACEA7F4E5E7645FB8BE8D3042A0C9D9C1F2EB984047A7C0786E1949F1`。板内页面由 RISC-V 固件直接提供，不经 PC 网页服务转发。

## 当前版本

- 对接 GitHub main：`8965c881218f5cfa5b3d24c0baf954a792d6dc32`。
- 位流：`bitstream/netfix04_rxq2_seed1.bit`，2,858,286 B；SHA256 `865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5`。
- 固件：`firmware/tinyml_pdti8.bin`，377,554 B；CRC32 `129D6E09`；SHA256 `23574C8F2997CD86AA6291A30DB52F337C830981C7A92E01E7B45E4F5815E996`。
- 已取得板端 `MMT_LOAD_PASS DDR_CRC`；启动后有持续 AI/传感器/决策日志。
- 当前 PC 进程 PID 12396，监听 8090；进程结束或电脑重启后重新启动监控。

## 修复内容

1. PC USB 网卡“以太网 3”设置为 169.254.47.62/16，板卡改为 .63。未修改 WLAN、默认网关与 DNS；对应入站规则仅用于本地链路。
2. HTTP 正文原本因长度变量被十进制转换耗尽而变为零；现已保留正文长度。
3. IPv4 总长度正确裁掉以太网填充/FCS，增加校验和与边界检查；TCP 采用一段一确认，处理 SYN/数据/FIN 重传、重复 ACK、跨连接干扰、分段 GET 和关闭。
4. RX 改为四槽队列，完整帧在 CPU 读完前保持不变；格雷码同步读写指针，消除两个时钟域共同写所有权状态的问题；帧尾不足四字节也写入，最短帧间隔不再导致帧混合。队列满时明确丢弃新帧，不覆盖未读帧。
5. 固件在空闲等待中处理网络，减少推理主循环饿死 HTTP 的情况。
6. PC 页面修正同条 LP 记录的传感器字段漏解析、MOT obs 漏解析和 16:9 缩略图；板内接口对齐温度单位与有符号分数，页面按板卡运行时间显示，避免伪造绝对时钟造成假断线。页面轮询避免重叠积压。
7. 构建脚本补齐整理后移动的四个头文件，使用无空格短路径；保留本机已在运行的相机低功耗限幅修复，没有重新调曝光/白平衡/红外阈值。

## 文件位置

完整 Efinity 工程：`D:\eth_build\netfix04_rxq2\ti60f225_oob.xml`。

完整本轮源码快照：`D:\FPGA\netfix04`，实际位于本会话的 `work\network-20261104\repo\FPGA_104-8965c881218f5cfa5b3d24c0baf954a792d6dc32`。

本交付目录：

- `code/`：本轮源码与工具的改动，保持仓库相对路径。
- `changes.patch`：相对上述 GitHub 提交的完整文本差异。
- `evidence/board_http_rxq2/result.json`：完整 HTTP 实测与响应原始字节。
- `evidence/board_http_concurrent.json`、`ping-final.txt`：并发和连通性证据。
- `evidence/board_rxq2_fw6b/serial.log`：固件下载、CRC 与运行证据。
- `evidence/net_test.log`、`rx_test.log`、`pc_parser_test.log`：协议、RTL 队列和 PC 解析测试。
- `evidence/pc_final_probe.json`：双通道 PC 页实测数据，含实际温度读数。
- `tools/set_pc_address.ps1`：管理员地址配置助手；地址已经配好，通常不需再运行。
- `tools/flash_vendor.ps1`、`tools/load_firmware.py`：临时 JTAG 加载与 UART 固件下载工具。下载前须停止占用 COM15 的监控进程。

启动 PC 页：在完整本轮源码中运行 `tools/start_network_monitor.ps1`，使用本机 Python 3 与 pyserial；或者运行：

```powershell
py -3 -X utf8 -u D:\FPGA\netfix04\tools\web_monitor.py --port COM15 --udp 8080 --http 8090 --public-host 169.254.47.62 --out D:\FPGA\netfix04\out\network_monitor
```

## 保留事项与后续边界

原 deepseek-harness 项目、AF930D9C 位流和 e23 固件均保留。没有推送 GitHub，没有写 SPI Flash。本轮是 JTAG 临时加载，板卡断电后需重新加载位流，再通过 UART 下载固件；不要只下载其中一个。

时序尚未收敛：旧 AF930D9C 的最小 setup 为 -1.073ns；本轮为 -1.103ns，hold 为 +0.017ns。当前记录证明网页、收发与显示功能通过，不代表所有条件下的时序可靠性。后续应另开时序收敛工作，保留本轮位流作为功能基线。

板内 TCP 当前只同时服务一个连接，并发请求通过重传串行完成；板内事件历史尚为空，PC 端保留事件日志。板内 `f` 是最近一次 AI 推理编号，暂停推理时可能不增长；`uptime_ms` 和其他传感器状态仍更新。尚未实现掉电自启动、板内事件持久保存和多人浏览器负载验证。
