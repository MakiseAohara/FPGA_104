# GE（千兆网口）并入主设计：今晚做到哪儿（2026-11-03 05:30）

## 一、已经确定成立的事

### 1) 硬件链路完全没问题（双向验证过）
用厂商 GE 例程编出的位流（Efinity 2026.1，本机）实测：
- 板子 → PC：`169.254.47.62:8080 → 169.254.47.61:8080`，载荷 `Hello From Ti60F225` 持续到达；
- PC → 板子 → 回环：23 B `PING-FROM-PC-1234567890` 原样回来 7 次；
- 不需要管理员权限（169.254 链路本地）。
详见 `LINK_TEST.md`。

### 2) GE 逻辑能并进主设计（map/interface/pnr/pgm 全 PASS）
- 关键发现：**Ti60F225 只有 4 个 PLL**（TR0/TL0/BL0/BR0），主设计全占了；
  `PLL_TR1/TL1/BR1/BL1` 一律报 "not a valid PLL device instance"。
  → GE 不要 PLL，TX 侧 DDIO 直接用 PHY 送来的 `rxc`（125 MHz）。
- 并进门清掉的坑：工程 XML 的 `design_file` 必须排在 `top_vhdl_arch` 之前；
  `DC_FIFO` 模块重名 → `GE_` 前缀；`parameter TCo_C` → `localparam`；
  必须一起拷 `ti60f225_oob.sdc`（否则 PnR 用默认 1 ns 约束，时序结论是假的）、
  `source/`、`EfxSapphireSoc*.bin/font8x16.hex/Panel_1080p_reg.mem`。
- 位流 `E1883570…`（2,923,770 B）上板：**SoC 固件、相机、缩略图、MOT、低功耗都正常**，
  同时板子在发 UDP。这一步已经证明"GE 和主设计可以共存"。

### 3) 板子 → PC 的"事件上报"链路已经能从固件驱动
- RTL：`rtl/ge/ge_eth_apb.v`（APB 0x6C..0x7C 窗口，512 B 收发缓冲）、
  `rtl/ge/ge_top_user.v`、`rtl/ge/ge_raw_tx.v`（自写帧发送器）。
- 固件：`ge_send()` 自己组整帧（广播 MAC + IPv4 + UDP + JSON + FCS），
  每 2 s 发心跳 `{"ev":"hb","t":…,"x":…,"y":…,"c":…,"nd":…,"ob":…,"al":…}`，
  报警开始/结束发 `as`/`ae`。
- 实测：MAC 路径下 NIC 能收到**帧**（`rx_unicast` 上涨、大小 106 B、无错误），
  但 Windows 不把 UDP 交给应用（抓不到），说明 L3/L4 头有问题；
  自写 raw TX 路径下 NIC 报 `rx_errors`（FCS 错），帧本身不合格。

## 二、当前状态（重要）

板子已**刷回** `v7_MERGE17.bit` + v3.8 固件（CRC `ACB03D7F`），
监控页 http://127.0.0.1:8090 正常（`f` 递增、`fw_lp=1`）。
今天所有 GE 实验位流都在 `D:\eth_build\m17_ge\`，没有覆盖 `D:\v30_build\m17`。

## 三、还没打通的最后一环（下次接着干）

现象：板子发的帧到 NIC 了，但应用收不到 / FCS 错。按优先级排查：

1. **raw TX 的 GMII 时序**：自写发送器现在只保证"字节序列对"，没有验证
   `gmii_tx_en` 与 `txc` 的相位。厂商 mac_tx 能发好帧、我的不能，差别就在这里。
   最省事的做法：**不要自写发送器**，回到 `mac_top`（已验证能发），
   把"payload 从哪来"接到 APB 上，而不是自己驱动 GMII。
2. **UDP/IP 头**：MAC 路径下帧能到 NIC 但应用收不到，重点查 IP 总长度字段
   （`udp_tx` 用 `udp_send_data_length` 推长度，它可能按 4 字节字算而不是字节）。
3. **TX 时钟 0° 相位**：没有 PLL 就没有 2 ns skew。如果第 1 条修好仍偶发错帧，
   就在 peri 里给 `txc` 输出加 `delay`（`output_config delay="…"`），或在固件侧
   让 `udp_tx` 的数据在 `mac_tx` 里多打一拍。

## 四、对"图里任务"的覆盖情况
| 要求 | 状态 |
|---|---|
| RISC-V 软核决策（MOT/预测/协议处理） | ✅ 已在跑（固件 v3.8） |
| 多目标跟踪（IOU Tracker） | ✅ `mot_core.h`，实测 |
| 行为预测（速度向量外推） | ✅ 有实现，但回测显示 2 帧外推比"不动"差 1.5–1.8 倍（见 `verify_prediction2.py`） |
| 低功耗管理 | ✅ 固件进入/退出 + 保留温度；RTL `low_pwr` 有抖动（历史问题） |
| 千兆以太网事件上报 | ⚠️ 链路通、帧能发，应用层还没收到；事件 JSON 已能组帧 |
| Web 远程监控（RISC-V 里的 HTTP） | ❌ 未开始；需要先解决上面的 TX，再做 TCP+HTTP（页面用 `tools/page.html` 同一份文件） |
