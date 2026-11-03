# ① 千兆以太网（RGMII）—— 结论更正：**本板硬件具备，可行**

日期：2026-11-02（更正 2026-11-01 的旧结论）

## 0. 旧结论作废

旧版本文件写"本板无 PHY / 无 RJ45，RGMII 不可行，且 IO 不够"。**这三条全错**，来源是只看了仓库文档、没看原理图。

## 1. 实物与原理图证据

- 原理图 `Ti60F225A_V4_SCH.pdf` 第 1 页框图：**YT8531SH → FPGA**（双向箭头）。
  `YT8531SH` 是 **Motorcomm 的千兆以太网 PHY**，不是 HDMI 座型号的一部分。
- 第 9 页（Sheet 8/13）给出 FPGA 侧完整 RGMII 连接。
- 实测：网线插上电脑，链路 **Up / 1 Gbps / 全双工**（`Get-NetAdapter`），
  IP 拿到 `169.254.x.x`（无 DHCP）⇒ PHY 已工作、自动协商成功。

## 2. 本板 RGMII 引脚（原理图 Sheet 8 实读）

见 `board_pins.tsv`。要点：

| 组 | 引脚 |
|---|---|
| TX | TX_CLK=`GPIOL_P_07`, TXD0..3=`GPIOL_P_06/P_05/N_09/N_10`, TX_CTL=`GPIOL_N_00` |
| RX | RX_CLK=`GPIOL_P_09`, RXD0..3=`GPIOL_N_07/N_06/P_00/N_05`, RX_CTL=`GPIOL_N_08` |
| 管理 | MDIO=`GPIOL_P_11`, MDC=`GPIOL_N_11` |

**这 14 根在当前设计里全部空闲**（已核对 `ti60f225_oob.peri.xml` 的 72 个 IO）。

注意 `GPIOL_P_08`（CLK_25M）与 `GPIOL_P_10`（CLK_27M）已被设计占用为**时钟输入**，
但以太网用的是同对的**另一半** `GPIOL_N_08`（RX_CTL）与 `GPIOL_N_10`（TXD3），**不冲突**。

## 3. 与 devkit / 厂商 demo 的关系

- Efinity 自带的 `efx_tsemac/fpga/Ti60F225_devkit/temac_ex.peri.xml` 用的是 `GPIOR_*` 一组；
- 厂商 GE demo（`vendor_demo_pins.tsv`）用的是 `GPIOL_N_11/P_11/GPIOL_01...` 另一组；
- **本板既不是 devkit 也不是厂商 demo 板**（UART 也不同：本板 `GPIOL_02`/`GPIOR_28`）。
  ⇒ 引脚约束**必须**用本文件的表，不能照抄上面两份。

## 4. 下一步

1. 用 `board_pins.tsv` 写 peri 约束；
2. 把已并入 `D:\v30_build\m17\rtl\ge\heijin_test` 的 GE MAC/UDP RTL 接到顶层；
3. 出位流 → 上板 → PC 侧配 `192.168.0.3/24`，监听 UDP 8080。

PC 侧配地址需要管理员权限（当前会话被拒：`Access is denied`）。
