# 板内 HTTP 协议栈（net_core）实现说明

## 是什么
`net_core.h` + `net_core_impl.h`：一份**可在 PC 上和 RISC-V 固件里跑同一份代码**的极简网络栈。

- 无动态内存、无 libc 依赖（只 `<stdint.h>`）
- 支持：ARP 应答、ICMP echo、TCP 服务端（单连接）、HTTP/1.1 响应
- 帧缓冲 1536 B，MSS 1000 B，窗口 4096 B
- 上层通过回调给内容：`cfg.cb->get(user, path, &body, &blen, &ctype)`

## 接口
```c
net_t net; net_cfg_t cfg;   /* mac / ip / port / cb */
net_init(&net, &cfg);
int n = net_input(&net, frame, len, out, sizeof(out), now_ms);  /* 有回包则 n>0 */
```

## PC 上自测（无需板子）
```
cd evidence/v30_mot
build_net_sim.bat
```
输出：
```
ARP  reply len=42 [OK]
SYN  reply len=54 flags=0x12 seq=4096 ack=1001 csum=3ce1 ok=1[OK]
GET  reply len=177 [OK]
RESULT PASS
```

测试内容：ARP 请求→应答；TCP SYN→SYN/ACK（IP/TCP 校验和独立复算一致）；
GET / → 200 + 正文 + `Content-Length` + `Cache-Control: no-store`。

## 已修正的坑（都是自测抓出来的）
1. `nc_frame()` 一开始把目的 IP 写成了本机 IP（源/目的相同）→ 校验和差 1，已被自测发现；
2. TCP 校验和必须先清 checksum 字段再累加，否则复算永远差 1；
3. 序号：SYN 和 FIN 各占 1 个序号，`snd_nxt` 要加。

## 接进固件要做的三件事
1. 用 `tools/page.html` 生成 `page_html.h`（C 数组），`get()` 里 `/` 返回它；
2. `/api/status`、`/api/events` 用固件现有状态现拼 JSON（字段与 PC 版一致）；
3. `/frame.png` 用 96×96 灰度缩略图现场编 PNG（zlib stored 块，不压缩）。

## 与 RTL 的边界
- 本栈只吃"整帧字节"，不碰硬件：RTL 侧 `ge_raw_rx` 把整帧抓进 2 KB 缓冲，`ge_raw_tx` 发整帧；
- 发送时 FCS 由固件算（`ge_send` 里已实现），RTL 只加前导码。
