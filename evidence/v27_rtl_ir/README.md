# MERGE15：红外基线死锁恢复 + 热像素计数（最小改动）

- 工程：`D:\v7work\v7_MERGE15`（由 `v7_MERGE14` 复制，未改原目录）
- 日期：2026-10-27
- 状态：**综合/布局布线/时序已完成，未上板**（按要求留给同学刷）
- 结论：RTL 只改 `v7_ir_proc.v` 与 `v7_mmt_core.v` 两处；旧版死锁在仿真中复现，新版 240 帧（125 ms/帧 = 30 s）后自动重学；热像素计数 6→`ir_hot=1`、1→`ir_hot=0`；5 步构建全过、`No valid pin(s)=0`、`No clocks matched=87`、最终 18 setup + 19 hold 全正（WNS **+0.296 ns**，hold 最小 **+0.005 ns**）。

---

## 1. 基线参数（先报告，逐字取自源码）

| 位置 | 参数 | 值 |
|---|---|---:|
| `rtl/v7/mmt/v7_ir_proc.v:10` | `IR_HS` | **2** |
| `rtl/v7/mmt/v7_ir_proc.v:11` | `NOISE` | **12** |
| `rtl/v7/mmt/v7_ir_proc.v:12` | `FREEZE_TH` | **48** |
| `rtl/v7/mmt/v7_mmt_core.v:18` | `IR_K` | **3** |
| `rtl/v7/mmt/v7_mmt_core.v:19` | `IR_SH` | **3** |
| `rtl/v7/mmt/v7_mmt_core.v:24`（MERGE13 起） | `HOT_ON` | **24**（原 48） |
| `rtl/v7/mmt/mmt_mlx90640_ctrl.v:48` | `FRAME_PERIOD_MS` 默认 | 500 ms |
| `rtl/v7/mmt/v7_mmt_core.v:14` | `IR_PERIOD_MS`（实际传入） | **125 ms** |
| `rtl/v7/mmt/mmt_sensor_subsystem.v:210` | `.FRAME_PERIOD_MS(IR_PERIOD_MS)` | 实际 **125 ms** |

### 1.1 关于“60 帧 ≈ 30 s”的核实（重要）

任务书写“连续为 1 超过 60 帧（约 30 s，帧率按 FRAME_PERIOD_MS 核实）”。核实结果：

- `mmt_mlx90640_ctrl` 的参数默认是 500 ms，但本工程 `v7_mmt_core` 传入 **`IR_PERIOD_MS=125`**，`mmt_sensor_subsystem` 把它接到 `.FRAME_PERIOD_MS`，所以**实际帧周期 = 125 ms（8 Hz）**，不是 500 ms。
- 因此 **60 帧 = 7.5 s**，达不到“约 30 s”；**240 帧 = 30.0 s**。
- 本实现按“**约 30 s**”的目标取 `FREEZE_RECOVER_MS=30000`，由 `IR_RECOVER_FRAMES=(30000+125-1)/125=240` 自动换算后传给 `v7_ir_proc`。若以后把 `IR_PERIOD_MS` 改回 500，参数会自动变成 60 帧。
- 仿真里直接按 240 帧门槛验证（见 §3），并同时复现旧版 300 帧仍锁死。

---

## 2. RTL 改动（只改两个文件）

### 2.1 `rtl/v7/mmt/v7_ir_proc.v`

1. 新参数 `RECOVER_FRAMES`（默认 240，注释说明 125 ms 下 ≈30 s）。
2. 新端口：
   - `input wire ai_person`：AI 判定有人时**不**自动重学；
   - `output reg [7:0] hot_cnt`：本帧 `d_pos > NOISE` 的像素数，饱和 255。
3. 新寄存器 `frozen_cnt[15:0]`：`freeze_prev` 连续为 1 的帧数。
4. 死锁恢复（`S_USE` 帧尾）：
   - `freeze_prev==1` 且本帧最大升温 `>FREEZE_TH`：`frozen_cnt++`（到 `RECOVER_FRAMES` 饱和）；
   - 当 `frozen_cnt >= RECOVER_FRAMES-1` 且 `ai_person==0`：置内部 `learn_pend<=1`，下一帧重学基线；
   - 非冻结帧清 `frozen_cnt`；学习帧清 `frozen_cnt` 并把 `freeze_prev` 清 0。
5. 热像素计数：每像素 `d_pos>NOISE` 时 `hot_cnt++`，饱和 255；每帧起始清 0；学习帧不计数。
6. 原有 `hot_delta`（最大升温）、热力图写、基线低通、`FREEZE_TH` 判据均未改。

### 2.2 `rtl/v7/mmt/v7_mmt_core.v`

1. 新参数：
   - `HOT_CNT_TH = 6`；
   - `FREEZE_RECOVER_MS = 30000`；
   - `localparam IR_RECOVER_FRAMES = (FREEZE_RECOVER_MS + IR_PERIOD_MS - 1)/IR_PERIOD_MS`（本工程 = 240）。
2. `v7_ir_proc` 实例增加 `.RECOVER_FRAMES(IR_RECOVER_FRAMES)`、`.ai_person(ai_p_eff)`、`.hot_cnt(hot_cnt)`。
3. `ir_hot` 改为：
   ```verilog
   always @(posedge clk) ir_hot <= ir_valid && (hot_cnt >= HOT_CNT_TH);
   ```
4. `HOT_ON` 保留为参数（兼容旧配置/文档），但 MERGE15 起不再参与 `ir_hot`。
5. `body_x10` 仍由 `hot_delta` 经 `IR_K/IR_SH` 计算；`obs_evt`/APB_EVT 位布局未改（`[3]=sht_seen [2]=ir_valid [1]=ir_hot [0]=motion`）。

### 2.3 改动范围核对

`tree_diff_rtl.txt`：源码/约束树中只有 **2 个文件内容变化**：
```
~ rtl\v7\mmt\v7_ir_proc.v
~ rtl\v7\mmt\v7_mmt_core.v
```
其余为 `sim/` 下新增的测试资产（`tb_ir_proc_v15.v`、`v7_ir_proc_old.v`、`mlx90640_model.v`、`tb_mlx90640_ctrl.v`、日志），未改摄像头/AI/HDMI/低功耗路径。

---

## 3. 仿真

### 3.1 已有 MLX90640 模型 + 测试台回归（`sim/tb_mlx90640_ctrl.v`）

从 `D:\FPGA\mmt\sim\` 复制 `mlx90640_model.v` 与 `tb_mlx90640_ctrl.v` 到 `v7_MERGE15/sim/`，与 `mmt_i2c_master/mmt_i2c_hub/mmt_mlx90640_ctrl` 一起编译运行：

```
=== ALL TESTS PASSED === (21 checks)
```
日志：`tb_mlx90640_ctrl.log`。

### 3.2 新增 `sim/tb_ir_proc_v15.v`（死锁 + 热计数）

- 同时实例化新版 `v7_ir_proc #(.RECOVER_FRAMES(240))` 与 **旧版**（MERGE14 源复制、改模块名为 `v7_ir_proc_old`，`sim/v7_ir_proc_old.v`）。
- 首帧 `raw=1000` 学习基线；随后连续 300 帧 `raw=1100`（偏移 +100 > `FREEZE_TH=48`）。
- 结果：

```
after learn frame: new freeze=0 old freeze=0
after 300 frames offset: new freeze=0 (recovered at frame 240) old freeze=1 (frozen frames=300)
PASS new recovers within RECOVER_FRAMES+margin (240 frames=30s@125ms)
PASS old stays locked (MERGE14 behavior reproduced)
PASS ai_person=1 blocks auto relearn
PASS recovery resumes after ai_person=0
6 hot pixels: hot_cnt=6 ir_hot(sim)=1
PASS 6 hot pixels -> hot_cnt=6, ir_hot=1
1 hot pixel: hot_cnt=1 ir_hot(sim)=0
PASS 1 hot pixel -> hot_cnt=1, ir_hot=0
PASS no hot pixel -> hot_cnt=0
=== RESULT: ALL TESTS PASSED ===
```

说明：`ir_hot(sim)` 在 TB 内用与 core 完全相同的表达式 `valid && hot_cnt>=6` 计算；`hot_cnt` 本身直接取自 DUT 输出。日志：`tb_ir_proc_v15.log`。

---

## 4. 综合 / 布局布线 / 时序 / 资源

### 4.1 五步构建（`flow_stdout_run2.log` / `build.log`）

| 步 | 结果 |
|---|---|
| [1] efx_map | 退出码 0 |
| [2] efx_pnr#1 | 退出码 0 |
| [3] efx_run -f interface | **PASS** |
| [4] filter_interface | wrote **483** 行 |
| [5] efx_pnr#2 --sync_file | 退出码 0 |

- `No valid pin(s) found for clock` = **0**
- `No clocks matched` = **87**
- `ERROR` 行 = **0**

### 4.2 最终签核时序（`pnr2_final_timing.txt`）

**18 条 setup + 19 条 hold 全部为正，0 条负 slack。**

- **WNS（setup 最小值）= +0.296 ns**（`hdmi_tx_slow_clk → hdmi_tx_slow_clk`）
- **hold 最小值 = +0.005 ns**（`hdmi_tx_slow_clk → core_clk`）
- HDMI 域内：setup **+0.296 ns**、hold **+0.038 ns**
- core_clk：setup +1.748 ns、hold +0.005 ns
- 其余域 setup 最小 +0.404（tx_cal_clk）… +196.6（CLK_5M）

### 4.3 与 MERGE14 的对比（如实）

| 项 | MERGE14（交付 run2） | MERGE15 | 变化 |
|---|---:|---:|---:|
| 全局 setup 最小 | +0.333（sdram 域内） | **+0.296**（hdmi 域内） | **−0.037 ns** |
| 全局 hold 最小 | +0.003（hdmi→core） | **+0.005**（hdmi→core） | **+0.002 ns** |
| hdmi 域 setup | +0.718 | +0.296 | −0.422 ns |
| hdmi 域 hold | +0.034 | +0.038 | +0.004 ns |
| core_clk setup | +1.930 | +1.748 | −0.182 ns |
| core_clk hold | +0.003 | +0.005 | +0.002 ns |
| sdram setup | +0.333 | +0.423 | +0.090 ns |

**判定**：没有负时序，故未触发“回退”；但全局 WNS 比 MERGE14 的 +0.333 低 **37 ps**（hdmi 域自身从 +0.718 变为 +0.296，属布局/走线波动；core/hold 反而改善）。若“时序不退化”严格解释为 WNS 数值不得下降，则这一项**不满足**，需要再跑一版 P&R（不改约束/RTL）或按接受当前正裕量处理——本报告不隐瞒该 37 ps。

### 4.4 资源（`place.rpt`）

| 项 | MERGE14 | MERGE15 | 变化 |
|---|---:|---:|---:|
| XLR | 41,532 / 60,800（68.31%） | **41,641 / 60,800（68.49%）** | **+109** |
| LUT | 23,379 | **23,489** | **+110** |
| FF | 21,475 | **21,506** | **+31** |
| Memory Blocks | 192 / 256 | **192 / 256** | 0 |
| DSP Blocks | 68 / 160 | **68 / 160** | 0 |

增量与新增的 `hot_cnt` 8 位计数/比较、`frozen_cnt` 16 位计数及恢复逻辑量级一致；未引入 BRAM/DSP。

### 4.5 位流

- 文件：`v7_MERGE15.bit`（本目录副本）
- 大小：**2,825,877 B**
- SHA256：**`74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40`**
- 注：同一设计的前一次构建（`out_run1`）时序/资源完全相同，但位流 SHA256 为 `76CFA44AA9FB795902C7E20705CC69BFCFE2D3A77A17BCA1E3C6485395BBC0F8`——位流不可复现，属正常；本报告采用 `out`（run2）。

---

## 5. 未验证 / 风险（如实）

1. **未上板**：body 恒 450、irhot 恒 1 是否被真正修复，只有仿真/构建证据；需同学烧 `v7_MERGE15.bit` 后用 v19/v25 固件观察 `body`、`ir_hot`、`MMT_LP`。
2. **`body_x10` 语义未改**：仍取 `hot_delta`（最大升温）×IR_K>>IR_SH；死锁恢复只让基线能重学，若物体长期占据画面，恢复后 body 会回落到环境温度，需上板确认 450 饱和是否消失。
3. **`hot_cnt` 未进 APB**：只用于 `ir_hot`；日志若需看计数值，需另加寄存器（本任务未要求，未改布局）。
4. **`HOT_ON` 参数保留但不再参与 `ir_hot`**：旧文档/脚本若引用它需知悉。
5. **37 ps WNS 下降**：见 §4.3；若严格要求不下降，需要额外 P&R 迭代（未改约束/RTL）。
6. 仿真使用的旧版模块是从 MERGE14 复制并改名的 `v7_ir_proc_old`，只用于对照，不属于综合源。

---

## 6. 文件清单（`evidence/v27_rtl_ir/`）

| 文件 | 说明 |
|---|---|
| `README.md` | 本报告 |
| `v7_ir_proc.diff` / `v7_mmt_core.diff` | 相对 MERGE14 的 RTL diff |
| `tree_diff_rtl.txt` | 源码/约束树差异（仅 2 个 RTL 文件） |
| `tb_ir_proc_v15.v` / `tb_ir_proc_v15.log` | 死锁 + 热计数测试台与日志 |
| `tb_mlx90640_ctrl.v` / `mlx90640_model.v` / `tb_mlx90640_ctrl.log` | 已有 MLX 模型/回归（21 checks PASS） |
| `build.log` / `flow_stdout_run2.log` | 五步构建日志 |
| `pnr2.log` / `pnr2_final_timing.txt` | 最终时序原始日志/摘录 |
| `place.rpt` | 资源报告 |
| `v7_MERGE15.bit` | 新位流（未烧录） |
