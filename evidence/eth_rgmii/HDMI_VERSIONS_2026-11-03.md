# 含网口位流的现场记录与构建输入（2026-11-03）

> 目的：每个"HDMI 黑屏/冻结"的位流都配一份 **构建输入 + 报告 + 上板现场记录**，供独立复核。
> 位流文件本身不入库（哈希见下表）；报告按版本放在 `builds/<版本>/`，现场串口日志在 `field_logs/`。

## 1. 版本总表（同一固件对比已标注）

| 版本 | 位流 SHA256 前 8 | GE | SDC | 固件 | HDMI（人工观察） | camfps | 传感器/相机 | 串口日志 |
|---|---|---|---|---|---|---|---|---|
| MERGE17 | `3A69AAFB` | 无 | 原始 | v29.2 `C15D47FD` | ✅ **正常** | 59–60 | sht=230/611 正常，infer 递增 | `field_logs/20261103_1927_MERGE17_v292.log` |
| v1 | `9A62F22A` | 有 | 原始 | e7 `AA5188F9` | （当时未记录） | 59 | sht=236 正常 | （早期日志） |
| v1 | `9A62F22A` | 有 | 原始 | e15 `0987B11B` | ⚠️ **冻结**（最后一帧） | 59 | sht=234 正常 | `field_logs/20261103_1730_v1_GE_e15.log`、`..._1735_...log` |
| v2 | `86D10972` | 有 | 原始 + CDC 约束 | e15 `0987B11B` | ❌ **黑屏** | 59 | 相机在出帧（网口实时帧 74% 像素变化） | — |
| P1 | `8D069E0B` | 无 | 原始 + CDC 约束 | v3.8 `ACB03D7F` | ❌ **黑屏** | — | — | — |
| TEST-A | `2F28EC01` | 无 | 原始 | v3.8 | （未单独观察） | — | — | — |
| TEST-A2 | `C0DA8DB9` | 无 | 原始 | v29.2 `C15D47FD` | 待观察 | **60** | sht=242/562 正常，sht_upd 递增 | `field_logs/20261103_1931_TESTA2_v292.log` |
| GE_A | `3B8A2EAB` | 有 | 原始 | e15 `0987B11B` | ❌ **黑屏** | 0 | **sht=0 body=0、ir_upd=0、infer=0（I2C 全灭）** | `field_logs/20261103_1912_GE_A_e15.log` |
| GE_A | `3B8A2EAB` | 有 | 原始 | v29.2 `C15D47FD` | 待观察 | **60** | **ir_upd 288→298 正常、sht=243/544、body=244** | `field_logs/20261103_1934_GE_A_v292.log` |
| MERGE21_WB | `D165EDCA` | 无 | 原始 | v3.8 | ❌ 不启动（COM15 零字节） | — | — | — |

## 2. 由这张表能直接读出的两件事

1. **"黑屏"与固件强相关**：同一个 GE_A 位流，
   - 载 **e15** → 传感器 I2C 全灭（`sht=0 body=0 ir_upd=0 infer=0`）、黑屏；
   - 载 **v29.2** → 传感器正常（`ir_upd 288→298`、`sht=243/544`）、camfps 60。
   ⇒ 之前的"GE 破坏视频"结论**不成立**；至少有一半是 **e15 固件把主循环拖慢 → I2C 服务被饿死 → 相机没配置 → 黑屏**。
   e15 相比 e7 新增了"每 500 ms 推 10 片实时画面"（每次 `ge_send` 忙等 GE_BUSY），主循环被 GE 发送占满最可疑。
2. **CDC false path 造成的黑屏**：v1（冻结）→ v2（黑屏）唯一变量就是在 SDC 里加的
   `set_false_path hdmi_tx_slow_clk -> core_clk`，已全部还原。

## 3. 构建输入与报告位置

| 路径 | 内容 |
|---|---|
| `m17_ge_snapshot/` | 顶层 .v / peri.xml / sdc / map / timing / pinout / place / route / cdc / design_issue + README（TEST-A 那一版） |
| `builds/v1_GE_origsdc/` | GE + 原始 SDC（v1 同源）编译出的报告 |
| `builds/v2_GE_cdc/` | GE + CDC 约束（v2 同源）编译出的报告 |
| `sdc_cdc_fix_2026-11-03.sdc` | v2 用的约束快照 |

**注意**：Efinity 每次编译的布局布线不完全可复现（同输入两次哈希不同），所以 `builds/` 里的报告是
"同源输入重编"的结果，用于分析时序/资源，不代表当时那颗位流的逐位布局。


## 5. 同源重编结果（用于分析，不代表当时那颗位流的布局）

| 重编版本 | 位流 SHA256 前 8 | 大小 | GBUF | 时序问题 | 报告目录 |
|---|---|---|---|---|---|
| v1 同源（GE + 原始 SDC） | `1E1F2928` | 2,857,086 B | 19/32 | 只有 hdmi→core 与 core→rxc 两条已知跨域告警 | `builds/v1_GE_origsdc/` |
| v2 同源（GE + CDC 约束） | `70ABBA90` | 2,858,427 B | 19/32 | 两条 `may not meet` 消失 | `builds/v2_GE_cdc/` |

> Efinity 同输入两次编译哈希不同（1E1F2928 ≠ 9A62F22A），但资源/时序结论可复现。

## 4. 复现某一版

```powershell
# 例：v2（GE + CDC 约束）
copy D:\eth_build\m17_ge\ti60f225_oob.sdc.bak_cdc D:\eth_build\m17_ge\ti60f225_oob.sdc
copy "C:\...\evidence\eth_rgmii\sdc_cdc_fix_2026-11-03.sdc" D:\eth_build\m17_ge\ti60f225_oob.sdc
cd D:\eth_build\m17_ge
& D:\Efinity\2026.1\bin\efx_run.bat ti60f225_oob.xml -f compile
```

---

# 板内网络打通记录（2026-11-04 00:15）

## 结论：RX 通了，ping 已经由 FPGA 回包

| 项 | 结果 |
|---|---|
| 位流 | EB5C9D43...(E52B)，MERGE17 源码 + GE + 自研 raw RX，2,851,020 B |
| 固件 | e23 0490EDD4（非阻塞发送 / RX STATUS 位解析 / 广播目的 IP / 整帧补 FCS / 关掉大 dump） |
| ARP | 通：板子回 ARP（rn=42），PC 缓存能解析 |
| ICMP | 通：ping 169.254.47.62 有回包（2/4，138-425 ms） |
| HTTP | 未通：curl 仍 000（TCP 握手没完成） |

## 这一轮修掉的四个真问题（板内网页的必要条件）

1. rx_dv 引脚被 DDIO 规则卡掉：GPIOL_N_08 是 EXT_CONFIG_CLK 复用脚，工具报 gpio_rule_cfg_input_ddio，
   该脚从来没被分配（Missing Interface Pin rx_dv_HI）。改成普通输入（ddio_type=none、上升沿采样）后消失。
2. RX 数据源接错模块：原设计把厂商 ge_udp_rx_bridge 接到 APB，它只搬 UDP 负载，帧头/ARP/TCP 全丢。
   改成自研 ge_raw_rx（整帧进 BRAM）后，固件立刻收到 356 B 的帧。
3. 收包带前导码且首字节常错：RGMII 采到 0x55 x7 + 0xD5 开头，固件按 0xD5 定位帧首（ge_rx_align）。
4. 回包没有 FCS/没补最小帧：ge_send_raw 直接推原始帧，PC 当坏帧丢 —— 这就是"固件回了 42 B ARP
   而 PC 侧 ARP 仍 Incomplete"的原因。补 60 B 与 CRC32 后 ping 立刻通。

## HTTP 仍不通的原因

主循环每圈要做一次 TFLite 推理（150-300 ms），期间不收包；1 Gbps 下 1 KB 帧只有 8 us，
多数包在轮询空档被覆盖，丢包约 50%（与 ping 2/4 吻合）。TCP 需三方向都成功，握手成功率约 12%。

下一步：RX 加多帧队列（RTL）或在推理等待里插 ge_http_service()（固件）。
