# MERGE17 — 红外热图小窗转置 + 白平衡 B 增益默认值

> 基线：MERGE16（`evidence/v29_rtl_display/`，位流 `v7_MERGE16.bit`，SHA256 `81332CD1…1F8882`）
> 工程：`D:\v7work\v7_MERGE17`（由 MERGE16 完整复制后只改两个文件）
> 位流：`v7_MERGE17.bit` **2,845,704 B**，**SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`**（pnr2 seed 6）
> 本轮**未烧板**。

---

## 1. 改动一：热图小窗转置（`rtl/v7/osd/v7_osd_overlay.v`）

### 映射

- 红外数据：`(col 0..31, row 0..23)`，RAM 地址 = `row*32 + col`（`v7_ir_proc` 的 `heat_wd` 写入顺序不变）。
- MERGE16：显示 x→col、y→row（32×24 → 192×144）。
- MERGE17（转置，= 顺时针 90° 再沿纵轴镜像）：**显示 x→row、显示 y→col**（24×32 → **144×192**）。
  - 数据 (col=0,row=0) → 显示左上；col=31,row=0 → 左下；col=0,row=23 → 右上；col=31,row=23 → 右下。

### 改了哪几行（改后文件行号）

| 行 | 内容 |
|---|---|
| L6 | 头注释更新为转置说明 |
| **L25** | `TH_X0 = 1744`（原 1696，1920−144−32） |
| **L38** | `INFO_Y0 = 232`（原 184，32+192+8；文字行跟着窗口走，仍在小窗正下方） |
| **L118–119** | `TH_W = 24*6 = 144`、`TH_H = 32*6 = 192`（原 32*6 / 24*6） |
| **L139–153** | 地址与块内偏移：`th_row = th_dx/6`（0..23）、`th_col = th_dy/6`（0..31）、`th_addr = {th_row, th_col}` = row*32+col；`blk_x = th_dx − 6*th_row`、`blk_y = th_dy − 6*th_col`。原先是 `th_sx = th_dx/6`（列）、`th_sy = th_dy/6`（行）、`addr = {th_sy, th_sx}` |

**未改**：`TH_SCALE=6`、16 档色阶表、hot 红框（6×6 块四边）、`heat_wd[7]`/`[3:0]` 编码、信息条内容与格式、`v7_ir_proc.v`（读出顺序/热判据不变）、`v7_osd_top.v`、`v7_mmt_core.v`。

> 说明：`th_rd_addr1..3` 仍与 `th_rd_addr0` 同址（MERGE16 起就不再插值），保持原样。

## 2. 改动二：APB 字 21 复位默认值（`rtl/ti60f225_oob_top.v`）

| 行 | 内容 |
|---|---|
| **L931** | `wb_b_core <= 16'h1C8;`（原 `16'h170`）——APB 字 21（0xF8100054）白平衡 B 增益，Q8.8 = 1.78125× |

R（字 19）默认 `0x158`、G（字 20）默认 `0x118` 不变；地址表、读写属性不变；固件启动仍可覆盖三个值。

## 3. 仿真（先仿真后编译）

`sim/tb_heat_rot.v`：驱动 250 行 × 1920 像素，逐像素检查 `th_rd_addr0` 是否等于 `((x−TH_X0)/6)*32 + (y−TH_Y0)/6`，并对 4 个角检查色阶。

```
$ iverilog -g2012 -o tb_rot.vvp tb_heat_rot.v ../rtl/v7/osd/v7_osd_overlay.v
$ vvp tb_rot.vvp
addr_checks=27648 addr_errors=0
TB_HEAT_ROT PASS (transposed mapping correct)
```

- 检查点 27,648 个（= 144×192，窗口全覆盖），地址错误 **0**。
- 四个角的期望：col0/row0 → addr 0（深蓝 level0）；col31/row0 → addr 31（白 level15）；col0/row23 → addr 736（深蓝 level0）；col31/row23 → addr 767（白 level15）。
- 日志：`sim_log.txt`；波形：`wave_transpose.png`（x/y、th_rd_addr0、输出 RGB 的 VCD 片段）。

## 4. 综合 / 布局布线 / 时序

- 流程：`tools/v7_flow_seed6.ps1`（v7_flow.ps1 的副本，pnr2 `--seed 6`），5 步全 exit 0。
- `No valid pin(s) found for clock = 0` ✅；`No clocks matched = 87`（jtag 无害）。

| 指标 | MERGE16（基线） | **MERGE17** | 验收 |
|---|---|---|---|
| 最差 setup（hdmi_tx_slow_clk → core_clk） | −1.020 ns | **−0.984 ns** | 不更差 ✅（优于基线 0.036 ns） |
| hold 违例条数 | 7（同族 5 + hdmi 域内 / hdmi→core） | **7（同一批路径）** | 一致 ✅ |
| XLR | 42,692 / 60,800（70.22%） | **42,857 / 60,800（70.49%）** | ≤72% ✅ |
| Memory / DSP | 192→189 / 256；67 / 160 | 189 / 256（73.83%）；67 / 160 | 不变 |

- hold 7 条明细（与 MERGE16 同一批）：tx_cal_90edge −0.440、sdram −0.484、rx_cal −0.710、tx_cal −0.416、hdmi 域内 −0.804、hdmi→core −0.805、core −0.742。

## 5. 产物

```
evidence/v29_rtl_ir_rot/
├── v7_MERGE17.bit            2,845,704 B  SHA256 3A69AAFB…887CF
├── v7_MERGE17.bit.sha256.txt 文件名/字节数/SHA256
├── timing_final.rpt          最终时序（Efinity timing analysis）
├── place.rpt                 资源占用
├── rtl.diff                  MERGE16 → MERGE17 的 unified diff（只有 2 个文件）
├── sim_log.txt               仿真日志（TB_HEAT_ROT PASS）
├── wave_transpose.png        波形截图
├── tb_heat_rot.v             新 testbench
├── v7_osd_overlay.v          改动后快照
├── ti60f225_oob_top.v        改动后快照
└── README.md                 本文件
```

## 6. 未动（按要求保持原样）

判决/融合/红外热点判据（`v7_ir_proc` 的 FREEZE/HOT_CNT 逻辑）、运动检测、低功耗、APB 地址表（字 0..26 与 MERGE16 完全一致）、`rgb_gain` 端口交叉（`.gain_b(r_gain)` / `.gain_r(b_gain)`）、HDMI 时序、DDR、TinyML 加速器。

## 7. 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\v7_flow_seed6.ps1 -Work D:\v7work\v7_MERGE17 -Tag MERGE17
```
