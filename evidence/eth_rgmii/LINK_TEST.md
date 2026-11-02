# 千兆网口链路实测通过（2026-11-03 01:00）

## 结论
本板 RGMII + YT8531SH 的**收发双向都通了**，用厂商 GE 例程直接在本机 Efinity 2026.1 编译出的位流验证。
PC 侧不需要管理员权限（走 169.254.x.x 链路本地地址）。

## 位流
| 用途 | 文件 | 大小 | SHA256 |
|---|---|---|---|
| 原样（192.168.0.2→.3） | `evidence/eth_rgmii/build/led_test_vendor_ge.bit` | 1,710,924 | `EF9E53BB…9AB7` |
| 改链路本地（169.254.47.62→.61） | `D:\eth_build\ge\outflow\led_test.bit` | 1,712,268 | `33C976BD86F4F39B703A8950FF784E3181B6F00434313F66F45A058170E20A35` |

第二次只改了 `rtl/top.v` 里两行 IP 参数（`32'hA9FE2F3E` / `32'hA9FE2F3D`），编译 ~100 s、烧录 ~40 s。

## 测试 1：板子 → PC（TX 通路）
监听 `0.0.0.0:8080`（`evidence/eth_rgmii/udp_listen.py`）：
```
PKT 1..60  from 169.254.47.62:8080  len=20  48656c6c6f2046726f6d205469363046...
```
载荷 = `"Hello From Ti60F..."`，持续到达（~7 包/s）。
同时网卡计数：`rx_unicast` 由 0 变正、`rx_errors=0`、链路 `Up / 1 Gbps`。

未改 IP 之前只能收到 ARP 请求（`rx_bytes` +360/6 s，`rx_bcast=6`，`rx_unicast=0`）——
说明 PHY/线序/延时补偿都对，只是目标 IP 不在同一子网、ARP 解不出来。改成链路本地后立刻出 UDP。

## 测试 2：PC → 板子 → 回环（RX 通路）
`evidence/eth_rgmii/udp_echo_test.py` 发 23 字节 `PING-FROM-PC-1234567890` 到 `169.254.47.62:8080`：
```
ECHO len=23  50494e472d46524f4d2d50432d31323334353637383930   ×7
echo received: True
```
载荷原样回来 ⇒ 接收链（RX DDIO → GMII → MAC → UDP RX → 回环 → UDP TX → MAC → TX DDIO）全部打通。

## 已恢复
测试完刷回 `v7_MERGE17.bit`（SHA `3A69AAFB…87CF`）+ v3.8 固件（322,874 B / CRC `ACB03D7F`），
`MMT_LOAD_PASS DDR_CRC` + `LOAD_OK`，监控页数据恢复（`f` 递增，`obs=0`）。

## 复现命令
```powershell
# 编译
cd D:\eth_build\ge; & D:\Efinity\2026.1\bin\efx_run.bat led_demo.xml -f compile
# 烧录（JTAG 临时加载，不写 SPI）
powershell -File D:\v30_build\flash_vendor_utf8.ps1 -Bit <bit> -Sha256 <sha> -Force
# 收包
py -3 evidence\eth_rgmii\udp_listen.py
# 回环
py -3 evidence\eth_rgmii\udp_echo_test.py
```

## 对后续集成的意义
- peri 的 GE 外设（`rxc/txc` DDR + `ge_0_gclk_pll`）可原样搬进 `ti60f225_oob.peri.xml`；
- MAC/UDP 的 RTL 已验证可用，接口是 GMII（8 bit @125 MHz）；
- 板子 IP/MAC 都是 RTL 常量，集成时改成可配置（APB 寄存器）即可。
