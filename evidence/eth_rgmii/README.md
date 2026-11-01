# ① 千兆以太网（RGMII）可行性调查 —— 结论：本板硬件不具备

日期：2026-11-01
结论：**在本板上无法实现 RGMII 千兆网**（无 PHY、无网口、可用 IO 不足）。事件上报继续用 UART 承载，与 `tools/web_monitor.py` 配套。

## 1. 本板实测资源（厂商文档，非推测）

`docs/工程全貌与学习地图.md` §2.2 / §2.3 记录本板型号 **Ti60F225I3-V4** 的板载资源：

- DDR3 `MT41J128M16JT-125`
- HDMI Type-A 座（原理图型号 `HDMI_TXYT8531SH`），只做 TMDS TX
- 两路 MIPI FPC 座（显示屏 + 摄像头）
- 一个 **QSE-020 40 脚 0.8mm 扩展座 J7**，其中**只有 6 个 3.3V 通用 IO**：
  `GPIOL_11`(C5)、`GPIOL_09`(A4)、`GPIOL_04`、`GPIOL_10`、`GPIOL_06`、`GPIOR_13`；其余为 MIPI/LVDS 差分对
- FT4232HL（JTAG + UART + 供电）、4 LED、4 KEY、25MHz/片上 OSC

**没有以太网 PHY，没有 RJ45。** 早前材料里写的"板载 PHY = YT8531SC"是把 HDMI 座型号
`HDMI_TXYT8531SH` 中的 `YT8531` 误当成 PHY 型号，已在本文件与
`docs/赛题完成度看板.md`、`docs/提交材料/拓展项对照.md` 中更正。

## 2. RGMII 需要多少信号（对比可用 IO）

| 方向 | 信号 | 数量 |
|---|---|---|
| TX | `txd[3:0]`、`txc`、`tx_ctl` | 6 |
| RX | `rxd[3:0]`、`rxc`、`rx_ctl` | 6 |
| 管理 | `mdc`、`mdio` | 2 |
| 复位 | `phy_rst_n` | 1 |
| **合计** | | **15** |

本板空闲通用 IO = **6**。即使把 J7 的 LVDS 差分对降级当单端用，也仍缺 PHY 芯片本身。

## 3. 厂商 demo 是给另一块板准备的

`04_Ti60F225_tse_hj_demo_v5` 的工程顶层 `rtl/top.v`（模块 `top`）把 `udp_test_top` 直接接在 15 根
`GPIOL_*` 引脚上，RGMII 走 DDIO `resync`；源 MAC `00:0a:35:01:fe:c0`、源 IP `192.168.0.2`、
目的 IP `192.168.0.3`、UDP 端口 **8080**（与赛题描述一致）。

其 `led_test.peri.xml` 的以太网引脚分配见同目录 `vendor_demo_pins.tsv`（15 行，全部 `GPIOL_*`）。
这些脚在本板上分别被 UART、按键、J7 差分对/IO 占用，且本板无 PHY 接收端 → **不能直接照搬**。

## 4. 已经做到的工程工作（可复现，但不上板）

在 v7 构建树 `D:\v30_build\m17` 上做了完整可行性验证：

1. 把 GE MAC/UDP RTL（`heijin_test` 下 35 个 `.v`：mac/rx/tx、arp、crc、dpram、DC_FIFO、gmii_arbi、
   smi_config、rgmii2gmii_altera）并入工程 `ti60f225_oob.xml`。
2. 解决与既有设计的三处**模块重名**：GE 的 `DC_FIFO`/`FifoAddrCnt`/`GrayCnt`/`GrayDecode`
   与 `rtl/frame_buffer_V4/DC_FIFO.v` 重名，已统一加 `GE_` 前缀（含内部例化）；
   另移除重复的 `util_gmii_to_rgmii`、testbench `eth_test_tb.v`、模板 `ddio_out_1bit_inst.v`。
3. `efx_map` 综合**通过**：退出码 0，`ti60f225_oob.err.log` 无 `VERI-ERROR`，
   生成 `ti60f225_oob.map.rdb / .map.rpt / .res.csv`（GE 模块因未被例化被优化掉，符合预期）。

**未做**：引脚约束、位流、上板。原因是本板没有 PHY——接了也无对端，且会占掉摄像头/HDMI 已在用的引脚。

## 5. 真要上板需要什么（超出本工程范围）

1. 一块外接 PHY 子板（RTL8211 / YT8511 / KSZ9031 等 RGMII 模块 + RJ45 + 25MHz 晶振）；
2. QSE-020 → 2.54mm 转接子卡（0.8mm 间距，杜邦线插不上）；
3. 从 J7 引 12~14 根线（含 125MHz 收发时钟），新建 peri 约束，把 demo 的 `udp_test_top` 并入顶层，
   再用现成的 `tools/web_monitor.py` 当 PC 侧接收端（改为 UDP 监听 8080）。
