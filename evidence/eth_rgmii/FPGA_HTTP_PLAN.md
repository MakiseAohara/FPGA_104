# FPGA 内部 HTTP：当前进展与下一步（2026-11-03）

## 目标确认
网页必须由 **RISC-V 固件里的 HTTP 服务**提供，浏览器直连板子 IP；
PC 上的 `tools/web_monitor.py` 只是调试替身，最终两者返回同一份 `tools/page.html`。

## 今晚的关键结论

### 1) 厂商 MAC/UDP 栈只能发 20 字节负载
把 demo 的 `UDP_DEPTH` 5→24（20 B→96 B）重编重烧，PC 一条都收不到。
⇒ 用它做 HTTP（响应 1 KB 级）不可能，必须走自己的收发。

### 2) 自己写的发送器已经能发"任意长度"的合法帧
在厂商小工程里用"ROM 固定帧 + 自写 FSM"实测：
```
PKT 2940 169.254.47.62:8080 len=64 MMT-RAW-TEST-...END
rx_bcast=1418 err=0
```
帧内容、IP/UDP 头、FCS 全部由软件算好后原样发出去，PC 收得到。
⇒ 组帧算法、FCS、RGMII 时序都对。

### 3) 主设计里的收发还没跑通
主设计（SoC + 相机 + HDMI + MOT）里加了 `ge_raw_tx`/`ge_raw_rx` + APB 窗口，实测：
- **RX 有数据**：word30 读到 `valid=1, 18 字（72 B）`，说明抓帧在动；
- **TX 卡住**：word29 读到 `busy=1`，`pkt_cnt` 不增长，PC 收不到任何帧。

已排除：`gmii_txd/tx_en` 声明成 reg（已改 wire）、GO 电平触发（已改为 0→1）、
`busy` 未清零（已补）。剩余怀疑点按概率：
1. APB 写 word27/28 **没落到** TX 模块（0x6C 超出 SoC APB 译码窗口？）
   —— 验证办法：把 TXLEN 做成可读，固件写 0x1234 读回来比对；
2. RAM 预取管线仍差一拍（第 2 字重复）→ 帧内容错但长度对；
3. 主设计里 `gmii_tx_clk` 与 `go` 的跨时钟域。

## 现有资产
- `rtl/ge/ge_raw_tx.v`（2 KB 发送缓冲 + APB）、`ge_raw_rx.v`（2 KB 收帧）、
  `ge_top_user.v`（util + tx + rx）、`ge_eth_apb.v`（旧版，含 vendor MAC 路径）；
- 固件 v4.x：`ge_send_raw()`、`ge_send()`（整帧组包 + FCS）、`ge_rx_poll()`、
  `ge_rx_service()`（收到 8080 的 UDP 回 MMT-ECH，用于闭环验证）；
- `D:\eth_build\ge`：**2 分钟一次编译**的小工程，带已证可用的 ROM 发送器，
  最快的调试环境。
- 生成器：`evidence/eth_rgmii/gen_frame.py`（Python 组帧+FCS）、`gen_c_frame.py`（转 C 数组）。

## 建议的下一步（按顺序）
1. 在小工程里把"APB 写入的 RAM 发送"跑通（没有 SoC，用计数器自己触发）；
   这一步能把 RAM/预取问题单独隔离出来，10 分钟一轮；
2. 回到主设计，加 TXLEN/TXDATA 读回寄存器验证 APB 窗口；
3. 打通后：固件实现 ARP 应答 + ICMP + UDP，再上最小 TCP；
   HTTP 直接返回 `tools/page.html` 的同一份字节。
