# GE 并入主设计：位流已上板跑通（2026-11-03 01:45）

## 结论
**千兆网口已经并进主设计**（SoC + 相机 + HDMI/OSD + TinyML + MOT 全都在），板子一边跑固件一边在发 UDP。

## 位流
- 文件：`D:\eth_build\m17_ge\outflow\ti60f225_oob.bit`，2,923,770 B
- SHA256 `E188357032616655C8C62D0D97361D527430B67B974266361667579AD258FADC`
- flow：map / interface / pnr / pgm 全 PASS，SDC 用的是主设计的 `ti60f225_oob.sdc`（+1 条 rxc 8 ns）
- 时序：rxc 125 MHz，setup 最差 rxc→rxc **+3.409 ns**，hold **+0.028 ns**

## 关键突破：Ti60F225 只有 4 个 PLL
- 厂商 GE 例程的 `ge_0_gclk_pll` 用 `PLL_TR0`，主设计已经占用 TR0/TL0/BL0/BR0 四个 PLL；
- 试过 `PLL_TR1/TL1/BR1/BL1` 全部报
  **"Resource is not a valid PLL device instance"**（`outflow/design_issue.xml`）⇒ 这颗芯片就 4 个 PLL，没有第五个；
- 解决：**GE 不要 PLL**，TX 侧 DDIO 直接用 PHY 送来的 `rxc`（本身就是 125 MHz）。
  peri 里把 `ge0_tx_clk / ge0_tx_clk_90` 换成 `rxc`，RTL 里 `rst_n` 接 1。
  代价：RGMII TX 时钟没有 90° 相位（0 ns skew），实测链路仍然通。

## 上板结果
- `MMT_LOAD_PASS DDR_CRC` + `LOAD_OK`，固件 v3.8（CRC `ACB03D7F`）正常启动；
- PC 侧 8080 端口持续收到 `169.254.47.62:8080 → 169.254.47.61:8080` 的 20 B 载荷
  `48656c6c6f2046726f6d2054693630463232350a`（"Hello From Ti60F225"）；
- 相机/缩略图/低功耗/MOT 都还在跑（`MMT_MOT` 持续、camfps 59、thumb 0.6 s 新鲜）。

## 过程中修掉的其它坑
1. 主设计 `ti60f225_oob.sdc` 必须一起拷，否则 Efinity 用默认 1 ns 约束跑 PnR（会得到假的时序通过）；
2. `source/`、`*.bin/*.hex/*.mem` 初始化文件、`debug_top.v` 都要拷；
3. 厂商 `DC_FIFO.v` 模块重名 → `GE_` 前缀；`parameter TCo_C` → `localparam`；
4. 工程 XML 的 `<efx:design_file>` 必须排在 `<efx:top_vhdl_arch>` 之前；
5. peri 的 `comp_gpio` 必须排在 `global_unused_config`/`bus` 之前。
