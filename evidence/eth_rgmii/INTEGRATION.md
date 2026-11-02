# GE（RGMII）并入主设计：进展与卡点（2026-11-03 01:30）

工作副本：`D:\eth_build\m17_ge`（主设计的完整拷贝，不动 `D:\v30_build\m17`）

## 已经做通
- 厂商 GE 逻辑（MAC/UDP/ARP + `util_gmii_to_rgmii`）作为 25 个文件并入工程，**综合 PASS**
  （`efx_run -f map` PASS，见 `outflow/ti60f225_oob.map.rpt`）。
  也就是说：这套 RTL 在**我们的 SoC 工程里**能综合，不依赖任何 Quartus IP。
- 顶层加了 15 个 GE 端口（14 根 RGMII + `phy_rst_n`）+ PLL 的 `RSTN/LOCKED`，
  并实例化 `udp_test_top`（源 169.254.47.62 → 目的 169.254.47.61:8080）。

## 过程中踩到的 5 个坑（都已解决）
1. **工程 XML 的 schema 顺序**：`<efx:design_file>` 必须排在 `<efx:top_vhdl_arch>` **之前**，
   否则 efx_map 报 "Failed to parse the project XML file"。手工插文件时最容易踩。
2. 原始工程文件表里残留 12 个 Quartus 侧文件（`ip/pll.v`、`ip/*_fifo.v`、`mdio/*`、
   `rgmii2gmii_altera/ddio_*`），指向的磁盘文件已被删/从没拷 → 全部从表里剔除。
3. **模块重名**：厂商 `mac/DC_FIFO.v` 定义 `DC_FIFO / FifoAddrCnt / GrayCnt / GrayDecode`，
   与主设计 `rtl/frame_buffer_V4/DC_FIFO.v` 冲突 → 厂商侧统一加 `GE_` 前缀。
4. **SV 兼容**：`parameter TCo_C` 在 sv_09 模式下报 VERI-1199 → 改 `localparam`。
5. 主设计依赖的初始化文件（`EfxSapphireSoc*.bin`、`font8x16.hex`、`Panel_1080p_reg.mem` 等）
   必须一起拷，否则 `$readmemh` 报警。

## 当前卡点
`efx_run -f compile` 卡在 **Interface Designer**：
```
ERROR: Design file has error : ti60f225_oob.peri.xml
ERROR: Fail to load design from ti60f225_oob.peri.xml
interface : FAIL
```
即：peri（引脚/PLL 定义）手工拼接后不被接受。已验证：
- 只加引脚、不加 PLL → 仍然 FAIL（PLL 不是唯一原因）；
- 工程 XML 与 peri 的分节结构与厂商工程一致（差异只有厂商的 `osc_info`，本设计没有振荡器）。

## 下一步（按性价比排序）
1. **在 Efinity GUI 的 Peri 里手工加这 15 个引脚 + 1 个 PLL**，让工具自己生成合法 XML，
   然后把这部分 peri 段落提出来对照我拼的版本，找出差异（最稳，但要 GUI 操作）。
2. 把主设计 `ti60f225_oob.peri.xml` 的 `iobank/clkmux` 段与厂商 peri 逐段对比，
   重点看 `ge0_tx_clk / ge0_tx_clk_90 / rxc` 这些时钟名是否需要先在 `gclk` 里声明。
3. 若 peri 始终过不去：退一步做**独立 GE 子设计**（厂商 demo 位流）+ 主设计两套位流切换，
   先把 HTTP 跑起来，再回头合并。

## 已恢复
板子仍是 MERGE17 + v3.8 固件，监控页正常。
