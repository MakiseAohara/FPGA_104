# RX 不通的定位结论（2026-11-03 下午，供接手人直接查）

## 结论

**发送（TX）已确认可用**；**接收（RX）在主设计里收不到任何帧**，而且**换成厂商自己的 mac_top
（在独立 demo 里能正常回 ping/echo）仍然收不到** ⇒ 问题不在 RX 逻辑，而在
**主设计的 RGMII 接收外设（peri）配置**。

## 证据链

| 实验 | 结果 |
|---|---|
| demo 工程（厂商 peri + mac_top） | ping/UDP 回环都通 |
| 主设计 + 自研 ge_raw_rx | 只抓到过 1 帧（18 字=72B 的 ARP），之后不再更新 |
| 主设计 + 自研 ge_raw_rx（帧间隔判定版） | 一帧都抓不到（rx_ready 恒 0） |
| 主设计 + **厂商 mac_top**（原样搬进来） | **ping 仍然 100% 丢包** |
| 主设计 raw TX | 帧能发出去，PC 收到 1800+ 帧、err=0 |

同一个 mac_top，换到主设计的 peri 里就不工作 ⇒ 差异在 peri。

## 最可疑的三处（按概率）

1. **RX 的 DDIO 输入寄存器没被 rxc 打拍**
   demo 的 peri 里 6 条 input_config 都带 `name_ddio_lo` + `clock_name="rxc"` +
   `is_register="true"`；合并进主设计 peri 时是**整块复制的**，但要确认：
   `comp_gpio name="rxc"` 的 input_config 是否仍是 `conn_type="gclk"`
   （若 rxc 没被当成时钟网络，DDIO 输入永不采样）。
2. **`efxpt:bus name="rxd"` 的 msb/lsb 声明**
   主 peri 里我追加过 `<efxpt:bus name="rxd" mode="input" msb="3" lsb="0"/>`，
   若与 demo 的位置/顺序不同，引脚可能没按 4 位总线绑定。
3. **`gmii_rx_clk` 与 `rxc` 的时钟域**：主设计用 `gmii_rx_clk`（=rxc）作为接收时钟，
   demo 也是，但要确认 util 的 `gmii_rx_clk` 输出在主设计里没被优化掉。

## 接手第一步（5 分钟）

```powershell
# 直接对比两份 peri 的 RX 段
$demo = 'D:\eth_build\ge\led_test.peri.xml'
$mine = 'D:\eth_build\m17_ge\ti60f225_oob.peri.xml'
Select-String -Path $demo,$mine -Pattern 'name="rxc"|name="rxd\[|name="rx_dv"|bus name="rxd"' |
  ForEach-Object { "$([IO.Path]::GetFileName($_.Path)):$($_.LineNumber): $($_.Line.Trim())" }
```

逐字段比对 `input_config` / `comp_gpio` / `bus` 三处的属性差异，改完重新出位流验证。

## 已完成、可交付的部分

- 千兆网口**发送**：主设计实测 OK（见 `TX_RX_2026-11-03.md`）；
- 板内 HTTP：协议栈/页面/PNG 全部 PC 自测通过、固件编译通过，**只等 RX**；
- 板子当前状态：`MERGE17 + v3.8`，相机/HDMI/MOT/低功耗/PC 监控页全部正常。
