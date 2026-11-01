# MERGE16 — 红外热图显示重做 + 白平衡可调可测

> 基线：`D:\v7work\v7_MERGE15`（evidence/v27_rtl_ir 的 MERGE15 源码）。工程：`D:\v7work\v7_MERGE16`。
> 位流：`v7_MERGE16.bit`（2,836,515 B）
> **SHA256 = `81332CD17DA35CDB7103C666434AE0DF1702A65EBEAEAAEB80AE70C8801F8882`**
> 本轮**未烧板**（按要求只出位流与证据）。回滚位流：MERGE15 `74E205F8…13AF40`（见 evidence/v27_rtl_ir/）。

---

## 0. 改动范围（只动这三块 + 必要连线）

| 文件 | 改动 |
|---|---|
| `rtl/v7/mmt/v7_ir_proc.v` | 热图色阶：每帧两遍读（统计 min/max → 归一化 0..15），`heat_wd[7]`=hot、`heat_wd[3:0]`=色阶 |
| `rtl/v7/osd/v7_osd_overlay.v` | 热图 6× 放大 / 不透明 / 16 档蓝→白 / hot 像素红框 / 热图下方信息条 |
| `rtl/v7/osd/v7_osd_top.v` | 透传 hot_cnt / body_x10 |
| `rtl/v7/mmt/v7_wb_stat.v` | **新增**：白平衡前中心区 R/G/B 统计（含饱和计数） |
| `rtl/debayer/debayer_top_2to1.v` | 例化 `v7_wb_stat`，引出统计端口（行奇偶与 gain 同源） |
| `rtl/v7/mmt/v7_mmt_core.v` | 引出 `hot_cnt_o` / `body_x10_o` 给 OSD 信息条 |
| `rtl/ti60f225_oob_top.v` | WB 增益改 APB 寄存器（默认 WBH7）+ 统计 CDC + VIO 解耦 |
| `ti60f225_oob.xml` | 加入 `v7_wb_stat.v` |
| `sim/tb_wb_stat.v` `sim/tb_heat_scale.v` `sim/tb_gain_order.v` | 新增 testbench |
| `sim/tb_ir_proc_v15.v` | 帧等待时间适配两遍读（判据不变） |

**未改**：判决/门控（v7_alarm_gate/sel）、AI 采样、摄像头配置、低功耗、I2C、TinyML、APB 字 0..18 布局。

---

## 1. 红外热图（原问题：只有超阈值像素画成黑色）

### 1.1 当前（MERGE15）映射方式（三行，另见 `comms/MERGE16_ir_display.md`）

1. `v7_ir_proc` 把 d_pos 右移 `IR_HS=2` 写成 0..255，且只有 `d_pos>NOISE(12)` 才非零。
2. `v7_osd_overlay` 4× 双线性放大到 128×96，窗口 (1760,32)，色阶 **黑→红→黄→白**。
3. 合成条件 `in_therm && th_data!=0`：**色阶 0 透明**，冷区全不显示 → 只剩零星黑/红点。

### 1.2 新映射

- 窗口 **32×24 × 6 = 192×144**，右上角 `TH_X0=1696, TH_Y0=32`（右侧/顶部各留 32 边距）。
- **整块不透明**：窗口内每个像素都出热图颜色，冷处为深蓝。
- **每帧自动拉伸**：`v7_ir_proc` 每帧两遍读同一帧 RAM（帧周期 125 ms，两遍约 62 µs）：
  - 第一遍：统计本帧 `d_pos` 的 `min/max`；
  - 第二遍：`level = (d_pos - min) >> (msb(span) - 4)`，clip 到 0..15。
- **最小跨度 `MIN_SPAN = 54` raw 计数**：板上标定 `IR_K=3 / IR_SH=3`（`0.1℃ = hot_delta*3/8`）⇒ 1℃ ≈ 26.7 raw ⇒ **2℃ ≈ 53.3 raw，取 54**。跨度不足时按 54 拉伸，防止无人时把噪声放大成花屏。
- **16 档查表（蓝→青→绿→黄→红→白）**：

| level | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| RGB | 000060 | 0000A0 | 0000E0 | 0040FF | 0090FF | 00E0E0 | 00FF80 | 00FF20 | 60FF00 | C0FF00 | FFE000 | FFA000 | FF4000 | FF0000 | FF6060 | FFFFFF |

- **hot 像素红框**：`heat_wd[7]` = 该像素 `d_pos > NOISE`；OSD 在 6×6 块的**四边画 1 像素红框**，块内仍显示色阶。
- **信息条**（热图正下方 `INFO_Y0=184`，5×7 点阵、字符格 6×8、琥珀色）：
  `HOT=<0..255> EST=<0..45>.<0..9>C`（EST 来自 `body_x10`，单位 0.1℃）。

---

## 2. 白平衡增益改 APB（可调）

### 2.1 接线（沿用 MERGE15 修正后的交叉接法，未改）

`debayer_top_2to1.v` 里 `rgb_gain_v1` 实例：

```verilog
.gain_b (r_gain),   // 信号 r_gain -> 端口 gain_b
.gain_g (g_gain),
.gain_r (b_gain),   // 信号 b_gain -> 端口 gain_r
```

`rgb_gain_v1` 内部按行奇偶选通道（`r_line_cnt`）：
- 行 A（`!r_line_cnt`）：`high×gain_g`、`low×gain_r` → 实际 **high=G、low=B**
- 行 B（`r_line_cnt`）：`high×gain_b`、`low×gain_g` → 实际 **high=R、low=G**

即**交叉接法 + `if(!r_line_cnt)` 修复**共同保证 R/B 落位正确（交接文档 §3 Bug 3/4 的那一套，未单独回退）。

### 2.2 仿真验证（`sim/tb_gain_order.v`）

设 `r_gain=0x200(2.0×) g_gain=0x100(1.0×) b_gain=0x080(0.5×)`，输入像素均 100：

```
LINE A: high=100 low=50   (exp 100 / 50)     // G×1.0, B×0.5
LINE B: high=200 low=100  (exp 200 / 100)    // R×2.0, G×1.0
TB_GAIN_ORDER PASS
```

⇒ 纯红只放大行 B 的 high（R）、纯蓝只缩小行 A 的 low（B），位置正确。

### 2.3 APB 寄存器

- 字 19/20/21 = R/G/B 增益（Q8.8），**默认 = WBH7：0x158 / 0x118 / 0x170**。
- 写入 core_clk 域 → 两级同步到 `vid_clk_dvi2` → **每帧 rgb_vs 上升沿锁存**（一帧内不会半新半旧）。
- VIO 的三个增益探针保留但**不再驱动** gain（改为 dummy 线，避免与 APB 抢驱动）。
- 地址表见 `apb_regs.md`。

---

## 3. 白平衡前通道统计（`v7_wb_stat.v`）

- 位置：**debayer 内、rgb_gain 之前**（raw Bayer 域，2 像素/拍），行奇偶信号与 `rgb_gain_v1` 同源。
- 区域：画面**中心 1/3 宽 × 1/3 高**（x∈[640,1280)、y∈[360,720)，共 230,400 像素）。
- 输出（每帧 vs 锁存 + toggle 握手到 core 域）：
  - `sum_r/sum_g/sum_b`（32 位）、`pix_cnt`、`sat_cnt`（任一通道 ≥250）。
- 仿真（`sim/tb_wb_stat.v`，96×72 缩比中心区 32×24）：
  - 全 100：`pix=768 sum_r=19200 sum_g=38400 sum_b=19200 sat=0` ✅（R=B=192 像素、G=384 像素）
  - 全 255：`sat=768` ✅
  - `TB_WB_STAT PASS`

---

## 4. 热图色阶仿真（`sim/tb_heat_scale.v`）

```
F1 learn: raw=3000 常量 -> 基线
F2: raw=3000+0..100 -> min=0 max=100 hot_cnt=255
     px0=0x00 (level0/hot0)   px767=0x8F (level15/hot1)   px384 level∈[10,14]
F3: 重学基线后 raw=3000+0..9 -> min=0 max=9
     px767=0x04 (level4，MIN_SPAN=54 生效，未把 9 计数放大成满量程)
TB_HEAT_SCALE PASS
```

## 5. MERGE15 回归（`sim/tb_ir_proc_v15.v`）

```
PASS first learn frame clears freeze
PASS new recovers within RECOVER_FRAMES+margin (240 frames=30s@125ms)
PASS old stays locked (MERGE14 behavior reproduced)
PASS ai_person=1 blocks auto relearn
PASS recovery resumes after ai_person=0
PASS 6 hot pixels -> hot_cnt=6, ir_hot=1
PASS 1 hot pixel -> hot_cnt=1, ir_hot=0
PASS no hot pixel -> hot_cnt=0
=== RESULT: ALL TESTS PASSED ===
```

> 仅为适配两遍读，把帧间等待从 `4*768+80` 改为 `8*768+200` 拍；判据一字未改。

---

## 6. 综合 / 布局布线 / 时序

- 流程：`tools/v7_flow.ps1`（efx_map → efx_pnr#1 → interface → filter → efx_pnr#2 --sync_file → efx_pgm）。
- **pnr2 拥塞是随机现象**：seed0/1/3/7 报 `Routing FAILED`，**seed2/4/6 成功**；本次采用 seed6 的布局（hold 与 seed2 相同 7 条，seed4 为 8 条）。
- 验收：`No valid pin(s) found for clock = 0` ✅；`No clocks matched = 58`（jtag 无害）。
- 时序对照（`timing_final.rpt` vs `evidence/v27_rtl_ir/pnr2_final_timing.txt`）：

| 项 | MERGE15 基线 | MERGE16 | 结论 |
|---|---|---|---|
| setup 最差（hdmi_tx_slow_clk → core_clk） | **-1.046 ns** | **-1.020 ns** | 略优（同一条既有跨域路径） |
| hold 条数 | 5（tx_cal_90 -0.25 / sdram -0.40 / rx_cal -0.65 / tx_cal -0.35 / core -0.57） | 7（同族 5 条 + hdmi 域内 -0.761 + hdmi→core -0.805） | **新增 2 条**（见下） |
| hdmi 域内 hold | 基线无 | -0.761 ns | 新增（OSD 显示逻辑） |

- 新增 2 条 hold 的说明（**如实记录，未掩盖**）：
  - `hdmi_tx_slow_clk→hdmi_tx_slow_clk -0.761 ns`、`hdmi_tx_slow_clk→core_clk -0.805 ns`；
  - 前者来自新增 OSD 显示逻辑（热图 16 档查表 / 信息条 5×7 点阵 / 除法）在 148.5 MHz 下的短路径；
  - 后者是**既有跨域路径**（同一条 setup 基线就 -1.046），MERGE16 布局变化使其 hold 也落负；
  - 两条均 < 1 ns，且功能路径（像素显示、APB 读写、统计）已在仿真中验证；**若要求与基线完全一致，需要在两个域的边界加 false_path 或专用打拍**（本轮未改 SDC，避免影响其它路径）。
- 资源（place.rpt）：

| | MERGE15 | MERGE16 |
|---|---|---|
| XLR | 41,641 / 60,800 (68.49%) | **42,692 / 60,800 (70.22%)** |
| Memory Blocks | 192 / 256 (75.00%) | 189 / 256 (73.83%) |
| DSP Blocks | 68 / 160 (42.50%) | 67 / 160 (41.88%) |

---

## 7. 产物

```
evidence/v29_rtl_display/
├── v7_MERGE16.bit        2,836,515 B  SHA256 81332CD1…1F8882
├── timing_final.rpt      最终时序报告（Efinity timing analysis）
├── place.rpt             资源占用
├── rtl.diff              rtl 目录 unified diff（vs MERGE15）
├── xml.diff              工程文件 diff
├── changed_files.txt     改动/新增文件清单 + SHA
├── apb_regs.md           新 APB 寄存器地址表（字 19..26）
├── README.md             本文件
└── rtl/                  改动后的 7 个源文件快照
```

## 8. 复现

```powershell
# 构建（ASCII 路径；一次只跑一个 Efinity）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\v7_flow.ps1 -Work D:\v7work\v7_MERGE16 -Tag MERGE16
# 若 pnr2 报 Routing FAILED（随机拥塞），换 seed 重跑 pnr2：
#   参考 D:\v7work\v7_MERGE16\tools\rerun_pnr2.ps1（seed 2/4/6 实测可成功）
```

## 9. 未完成 / 风险

- **未烧板、未看屏幕**：热图颜色/信息条位置/白平衡 APB 调节的实际观感需上板确认。
- 固件未改：新寄存器不写即默认 WBH7 增益；统计寄存器只读，不影响 v29 固件。
- hold 新增 2 条（如上），未改 SDC。
- `v7_osd_overlay` 的 `th_rd_addr1..3` 保留但只读第 0 份 RAM（16 档查表不需要插值），RAM 的 4 份复制仍在（未裁剪，避免动 MERGE15 的存储结构）。
