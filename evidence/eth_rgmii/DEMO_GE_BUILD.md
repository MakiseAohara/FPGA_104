# 厂商 GE 例程：已在本机 Efinity 2026.1 编译通过（2026-11-03）

## 结论
资料包 `Ti60F225_DemoBoard_v4完整资料包-0927更新.zip` 里的
`04_Ti60f225_GE_demo/04_Ti60F225_tse_hj_demo_v5` **是 Efinity 工程**（`led_demo.xml`，
sw_version 2025.2），不是 Quartus 工程。它自带完整的 RGMII 封装：

- `rtl/heijin_test/rgmii2gmii_altera/util_gmii_to_rgmii.v`（纯逻辑，无原语）
- `rtl/heijin_test/{mac,arbi,ip}/`（UDP/ARP/ICMP + FIFO）
- `led_test.peri.xml` —— **RGMII 的 DDR/PLL 由 Efinity peri 生成**：
  `rxc@GPIOL_P_09`、`txc@GPIOL_P_07`、`ge_0_gclk_pll`（ref=rxc 125 MHz）、
  `ge0_tx_clk_90`、rxd/rx_dv 的 hi/lo DDIO 输入。

## 之前 m17 里为什么综合崩
`D:\v30_build\m17\rtl\ge\heijin_test` 是**不完整副本**：缺整个
`rgmii2gmii_altera/`（含 `util_gmii_to_rgmii.v`）和 `ip/`，所以 elaborate 找不到模块；
再加上副本里残留 Quartus 的 `pll.v/eth_data_fifo.v/.qip`，`efx_map` 直接 access violation。
**不是这套设计不能综合。**

## 本机编译结果（Efinity 2026.1.132）
```
cd D:\eth_build\ge
efx_run.bat led_demo.xml -f compile
  map : PASS   interface : PASS   pnr : PASS   pgm : PASS
```
- 需先删掉 `led.xml` 里的 `<efx:debugger>` 段（debug profile 是 2025.2 生成的，2026.1 跑
  `efx_run_dbg.py` 会抛异常，与设计无关）。
- 位流：`outflow/led_test.bit`，1,710,924 B，
  SHA256 `EF9E53BB39236224D6A3B52CCF7CCE4E45D10E229505C517F9CE1D1EEDC49AB7`
  （存档 `evidence/eth_rgmii/build/led_test_vendor_ge.bit`）
- 时序：`rxc` 125 MHz；setup 最差 `rxc→ge0_tx_clk` slack **0.742 ns**；
  hold 最差 `rxc→rxc` slack **0.045 ns**（正，但余量很薄）。报告见 `build/led_test.timing.rpt`。

## 引脚交叉核对（编译结果 pinout vs board_pins.tsv）
| 信号 | pinout.rpt | board_pins.tsv | |
|---|---|---|---|
| txc | GPIOL_P_07_CLK0_P | GPIOL_P_07 | ✓ |
| rxc | GPIOL_P_09_CLK2_P | GPIOL_P_09 | ✓ |
| txd0..3 | P_06 / P_05 / N_09 / N_10 | 同 | ✓ |
| rxd0..3 | N_07 / N_06 / P_00 / N_05 | 同 | ✓ |
| tx_en | GPIOL_N_00 | 同 | ✓ |
| rx_dv | GPIOL_N_08_CLK1_N | 同 | ✓ |
| mdc / mdio | N_11 / P_11 | 同 | ✓ |

⇒ 例程板就是本板，peri.xml 的 GE 外设可直接复用。

## 例程行为
`rtl/top.v` → `udp_test_top`：UDP 从 **192.168.0.2:8080 → 192.168.0.3:8080**，
源 MAC `00:0a:35:01:fe:c0`。`txc` 用 DDIO（数据 hi=1/lo=0 + `ge0_tx_clk_90`）在引脚上合成时钟。

## 下一步
1. **链路实测（5 分钟）**：烧 `led_test_vendor_ge.bit`，PC 侧看网卡 RX 计数是否上涨
   （不需要管理员；包发往 192.168.0.3，Windows 会在 IP 层丢弃，但 NIC 计数照涨）。
   测完刷回 MERGE17 + v3.8 固件（`load_retry.py`，CRC `ACB03D7F`）。
2. **集成**：把 `led_test.peri.xml` 的 GE 外设块并入 `ti60f225_oob.peri.xml`，
   `heijin_test` MAC + `udp_test_top` 改造成"发真实数据"，出整体位流。
