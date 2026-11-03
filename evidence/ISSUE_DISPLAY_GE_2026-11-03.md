# 【显示】GE 位流 HDMI 黑屏 / 冻结 —— 已排除项、时序证据与下一步计划

> 立此 issue 是为了把"显示 + 千兆网口能不能共存"这件事的**全部事实**固定下来，避免再重复试错。
> 当前状态：**网口通、显示不通**；显示只在无网口的 `v7_MERGE17.bit` 上正常。

---

## 1. 现象（按位流列出，全部实板验证）

| 位流 | SHA256 前 8 | 固件 | HDMI 显示 | 千兆网口 | 串口/loader |
|---|---|---|---|---|---|
| `v7_MERGE17.bit` | `3A69AAFB` | v3.8 `ACB03D7F` | ✅ **正常**（画面在动、OSD 刷新） | ❌ 无 GE 模块 | ✅ |
| GE 位流 v1 | `9A62F22A` | e15 `0987B11B` | ⚠️ **画面冻结**（最后一帧） | ✅ 心跳/事件/缩略图都到 | ✅ |
| GE 位流 v2（本次） | `86D10972` | e15 `0987B11B` | ❌ **黑屏** | ✅ 心跳 `type=2` + 实时画面 `type=3` 正常 | ✅ |
| `v7_MERGE21_WB.bit` | `D165EDCA` | v3.8 | ❌ 板子完全不启动（COM15 零字节，loader 不应答） | — | ❌ |

v1 → v2 只改了 SDC 约束（见第 3 节），显示从"冻结"变成"黑屏"，说明约束改动**确实影响了 HDMI 数据通路**。

## 2. 已排除项（都有实测依据）

1. **相机没坏**：从网口抓连续实时帧，相邻帧 **74.6% 像素在变**，画面是正常房间场景；
   `sht_upd/ir_upd` 计数在涨，`camfps=59`、`vts_ok=1`。
2. **固件没挂**：`MMT_LOAD_PASS DDR_CRC`、`MMT_MOT/MMT_DEC/MMT_OSD` 持续输出，
   `MMT_OSD chk` 每帧都变（说明 CPU→APB→视频寄存器的写是通的）。
3. **APB 地址不冲突**：GE 挂在 `soc_apb_*` 上，读数据 mux 明确覆盖 27..31，
   其它字（9=OSD、10=AI、11..13=融合、19..21=WB）各自独立，没有重叠：

```verilog
// rtl/ti60f225_oob_top.v:955
case(soc_apb_paddr[6:2])
   5'd9:  soc_apb_prdata = {31'd0, osd_alarm_core};
   5'd11: soc_apb_prdata = apb_ext_prdata;
   5'd27, 5'd28, 5'd29, 5'd30, 5'd31: soc_apb_prdata = ge_apb_prdata;  // GE
   default: soc_apb_prdata = 32'd0;
endcase
```

4. **不是"没编上"**：每次烧录都有 `Device ID PASS` + `烧录成功`，且烧完网口立刻有流量。

## 3. 时序证据（Efinity 2026.1.132，Ti60F225 I3）

### v1 报出的两条跨时钟域违例

```text
Launch Clock      Capture Clock      Constraint(ns)  Slack(ns)   Edge
hdmi_tx_slow_clk  core_clk           -0.124          -0.650      (R-R)   ← 约束本身为负=异步被当同步
core_clk          rxc                 2.000          -0.875      (R-R)   ← RGMII 收时钟域
```

`rxc` 那条正好解释"RX 从头到尾收不到包"（本次不修 RX，事件上报只用发送方向）。

### v2 加的约束（`ti60f225_oob.sdc` 末尾）

```tcl
# 原 MERGE3 只有这一个方向：
set_false_path -from [get_clocks {core_clk}] -to [get_clocks {hdmi_tx_slow_clk}]

# 本次补：
set_false_path -from [get_clocks {hdmi_tx_slow_clk}] -to [get_clocks {core_clk}]
set_clock_groups -asynchronous -group {core_clk} -group {rxc}
```

v2 编译日志里这两条 `may not meet` **已消失**，但画面由"冻结"变"黑屏"。

## 4. GE 模块接入方式（供定位用）

```verilog
// rtl/ti60f225_oob_top.v:1616
ge_top_user u0_ge (
    .clk(core_clk), .paddr(soc_apb_paddr), .psel(soc_apb_psel),
    .penable(soc_apb_penable), .pwrite(soc_apb_pwrite),
    .pwdata(soc_apb_pwdata), .prdata(ge_apb_prdata),
    .rxc(rxc),
    .rxd_hi_i(rxd_hi_i), .rxd_lo_i(rxd_lo_i), .rx_dv_HI(rx_dv_HI), .rx_dv_LO(rx_dv_LO),
    .tx_en_o_HI(tx_en_o_HI), .tx_en_o_LO(tx_en_o_LO),
    .txc_hi_o(txc_hi_o), .txc_lo_o(txc_lo_o),
    .txd_hi_o(txd_hi_o), .txd_lo_o(txd_lo_o), .phy_rst_n(phy_rst_n));
```

内部：`ge_raw_tx`（BRAM 512×32，`clk` 域写、`gmii_tx_clk` 域读）、`util_gmii_to_rgmii`、
厂商 `gmii_arbi`（`.clk(gmii_tx_clk)`）+ `mac_top`（RX，未用）、`ge_eth_apb`。

## 5. 假设（按可能性排序）

1. **H1：GE 模块与视频链路共享了同一批物理资源/时钟网络，导致视频输出停摆**
   —— v1 冻结、v2 黑屏说明不是"完全没接"，而是"起不来或停在半路"。
2. **H2：`hdmi_tx_slow_clk → core_clk` 那条是真实数据而非同步器**
   —— 直接 false path 会把时序检查去掉但不解决亚稳态，行为可能更糟（本次现象吻合）。
3. **H3：`m17_ge` 工程源码与产出 MERGE17 的那一版有漂移**
   —— 同为 `D:\v30_build\m17` 工程的 `MERGE21` 根本不启动，说明源码状态已经不一致。

## 6. 计划（按性价比）

- **P1（最快，25 min）**：在 `m17_ge` 工程里把 `u0_ge` 的 `prdata` 接 0、**不实例化 GE**，
  其余不动，重编 → 若显示正常 ⇒ 问题钉在 GE 模块本身（资源/时钟/扇出），而不是 SDC。
- **P2**：若 P1 正常，把 GE 模块**降频/换域**接入（`clk` 用 `core_clk` 分频，或把 APB 侧加一级流水），
  同时保留 v2 的两条约束，重编验证。
- **P3**：回退到产出 MERGE17 的源码快照（用 `evidence/` 里存的 RTL 或 git 历史对齐），
  只在其上**新增** GE，避免夹带 WB/audio 的未知改动。
- **P4**：把 `hdmi_tx_slow_clk → core_clk` 的真实跨域寄存器找出来（timing 报告里有 launch/capture 寄存器名），
  在 RTL 里补 2-FF 同步器，而不是靠 false path 糊住。

## 7. 目标与验收标准

一个位流同时满足：

| # | 验收项 | 判据 |
|---|---|---|
| 1 | HDMI 画面 | 相机画面连续（相邻帧变化 >50% 像素），OSD 数字每秒刷新 |
| 2 | 千兆网口 | `py -3 tools/acceptance.py --secs 30` **6/6 PASS** |
| 3 | 帧率/低功耗 | `camfps` 59~60；空场自动进 LP、有人恢复 |
| 4 | 事件链路 | 报警时收到 `type=1` + 10 片 `type=3`；空场每 500 ms 一帧实时画面 |
| 5 | 时序 | 编译日志无 `may not meet`（或所有跨域都有明确约束与理由） |

## 8. 复现命令

```powershell
# 编译
cd D:\eth_build\m17_ge
& D:\Efinity\2026.1\bin\efx_run.bat ti60f225_oob.xml -f compile

# 烧录 + 载固件（板子必须先重配位流才会进 loader）
& D:\v30_build\flash_vendor_utf8.ps1 -Bit D:\eth_build\m17_ge\outflow\ti60f225_oob.bit `
    -Sha256 <64位哈希> -Force
py -3 D:\v30_build\load_v30.py --image D:\v30_build\out_v30_e15\tinyml_pdti8.bin --out D:\v30_build\out_load_x

# 网口验收（不需要人）
py -3 tools\acceptance.py --secs 30
# 相机是否活的（抓相邻实时帧比像素）
py -3 evidence\eth_rgmii\frame_alive2.py
```

## 9. 相关文件

- 约束：`D:\eth_build\m17_ge\ti60f225_oob.sdc`（末尾 `MERGE17_GE_CDC` 段；备份 `.bak_cdc`）
- 顶层：`rtl/ti60f225_oob_top.v`（GE 实例化 1616 行、APB mux 955 行）
- GE：`rtl/ge/ge_top_user.v`、`ge_raw_tx.v`、`ge_eth_apb.v`、`ge_raw_rx.v`、`ge_udp_rx_bridge.v`
- 证据：`evidence/eth_rgmii/UDP_EVENT_2026-11-03.md`、`evidence/v30_mot/MOT_PRED_2026-11-03.md`


---

# 后续记录（2026-11-03 19:10）

## 已逐项排除

1. **网口引脚 IO 标准/银行电压**：14 根脚全部已分配（peri.xml 里 `comp_gpio name="rxd[0..3]"` / `txd[0..3]` 等，
   `rxc=GPIOL_P_09`、`rx_dv=GPIOL_N_08`、`txc=GPIOL_P_07`、`tx_en=GPIOL_N_00`、`phy_rst_n=GPIOL_01`(3.3 V)）。
   1A/1B 全 1.8 V，BL/BR/TL/TR 全 3.3 V，**没有同 bank 混压**；HDMI/TMDS 在 bank 3A（1.8 V），与网口不同 bank。
2. **全局时钟**：GE 版 `place.rpt` 为 **GBUF 19/32、RBUF 1/32**，没到上限；XLR 71.5%、BRAM 77.3%，资源不紧张。
3. **`hdmi_tx_slow_clk -> core_clk`**：发起/捕获是 `u_apb_ext` 的 `evt_q -> evt_c` / `env_q -> env_c`
   （视频域采样、CPU 回读证据字），不是像素通路；MERGE17 自己 slack 更差（-0.984 ns）仍显示正常
   —— **不是黑屏原因，不加同步器**。
4. **v2/P1 的黑屏**：唯一变量是本次在 SDC 里加的 `set_false_path hdmi_tx_slow_clk -> core_clk`，已还原；
   v2/P1 的黑屏不能用来判定"GE 破坏视频"。

## 新发现（待验证）

- GE_A（`3B8A2EAB`，GE + 原始 SDC）的 place.rpt 里有 **Missing Interface Pin: `rx_dv_HI`**
  （peri 里该脚定义为 `comp_gpio name="rx_dv"`，与顶层端口名不一致）→ 只影响 RX，不影响 TX，但说明引脚表有瑕疵。
- GE_A 上固件跑起来了（`MMT_GE ctrl=0x009E0001`，已发 158 帧），但 **网口收不到包、传感器 I2C 全灭**
  （`sht=0 rh=0 body=0 sht_upd=0 ir_upd=0`、`infer=0`、`camfps=0`）。
  这一组症状指向**板级状态被反复重配打坏**（I2C/PHY 停在半截），而不是 RTL：同一套输入在 14:33(v1) 与 18:47(GE_A)
  两次构建，v1 网口正常、GE_A 全灭。
- 需要一次**断电重启**再做同条件对照，避免把板级状态误判成设计问题。

## 下一步

1. 断电 10 s 重启 → 烧 `3B8A2EAB` + e15 → 看 HDMI 与网口心跳；
2. 若显示仍不正常：编"GE 在但 `txd/txc/tx_en` 输出置 0、`rxc` 不接"的版本，切分"PHY/RGMII 活动"与"GE 逻辑"；
3. 每步把位流名/哈希/固件/HDMI/网口/结论追加到本文件。


---

# 追加：黑屏与固件强相关（2026-11-03 19:35）

同一颗位流 `3B8A2EAB`（GE + 原始 SDC），只换固件：

| 固件 | camfps | sht/rh/body | ir_upd | infer | HDMI |
|---|---|---|---|---|---|
| e15 `0987B11B` | 0（LP） | **0 / 0 / 0** | **0** | **0** | 黑屏 |
| v29.2 `C15D47FD` | **60** | 243 / 544 / 244 | 288→298 | 递增 | 待确认 |

- e15 版：I2C 全灭 → 相机没被配置 → 没有视频源 → 黑屏；
- v29.2 版：传感器和相机都在跑。

e15 相比 e7 新增了 **每 500 ms 推 10 片实时画面**（每次 `ge_send` 都会忙等 `GE_BUSY`），
最可疑的是主循环被 GE 发送占满 → I2C 服务被饿死 → 相机配置/温湿度读取超时。

⇒ 结论修正：**"GE 位流导致黑屏"至少有一半是固件问题**，不能只改 RTL。
下一步优先级：① 用 v29.2 确认 GE_A 的 HDMI 是否正常；② 若正常，在 e15 里把实时画面改成
非阻塞（每圈只发一片、且不忙等），再复测。

现场串口日志：`evidence/eth_rgmii/field_logs/`；版本对照表：`evidence/eth_rgmii/HDMI_VERSIONS_2026-11-03.md`。
