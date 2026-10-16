# 去马赛克 Bayer 相位分析 —— "画面全紫" 的根因与修法

- 工程：`D:\FPGA\mmt`（Efinix Efinity 2026.1.132，Ti60F225I3，顶层 `mmt_top`）
- 任务：task-18 —— 不用屏幕，用仿真把"画面全紫"的修法定下来
- 日期：2026-10-13
- 仿真目录：`D:\FPGA\mmt\sim\debayer\`

---

## 0. 结论先行

| 问题 | 结论 | 等级 |
|---|---|---|
| 根因在哪？ | **显示通路上多了一次 R/B 交叉**：`rtl/mm/mmt_top.v:1388-1390` 把 `hdmi_tx_bdata`（蓝）接到 `mmt_osd_overlay` 的 `i_r`（红）、`hdmi_tx_rdata`（红）接到 `i_b`（蓝） | **实测（仿真复现）** |
| 这一路交叉会走到屏幕吗？ | **会**。`mmt_osd_overlay` 主区域原样透传（仿真：输入 `11/22/33` → 输出 `33/22/11`），而它到编码器是**正接**的（`mmt_top.v:1277-1279`），所以红通道最终拿到蓝 | **实测（仿真）** |
| 是 debayer（去马赛克）的错吗？ | **不是**。`raw_to_rgb #(.LEGACY(1'b1))` 实测是一个**完全正确的 RGGB 去马赛克**：纯红场→R、纯绿场→G、纯蓝场→B | **实测（仿真）** |
| 为什么官方 demo 也紫？ | 官方 demo **有同样的交叉**，而且**原始正确接法还留在注释里**：`07_官方demo工程/.../ti60f225_oob_top.v:963-965`（`//(video_b)`、`//(video_r)`、`//(bdata_in)`、`//(rdata_in)`）→ 证明 `i_rdata` 就是红，这个交叉是缺陷、不是约定 | **代码实测** |
| 修法 | **只改 1 处、3 行**：`mmt_top.v:1388-1390` 改回正接（§6 的 P0）。**与传感器 Bayer 相位无关**（§1 给了奇偶性证明） | **实测 + 推断** |
| 需要改 debayer / LEGACY / 增益 / 字节序吗？ | **都不需要**，而且其中三项实测**无效**、一项实测**不解决问题**（§5） | **实测** |
| 需要知道 IMX219 的实际相位吗？ | **本轮不需要**。修法在 `t`（传感器侧反相）与 `e`（编码器命名反相）取任何值时都正确（§1） | — |

**给 Lead 的一句话**：群里说的"bayer 映射错"是**误诊**。去马赛克本身是对的，紫的原因是显示通路把 R/B 接反了——而且这条线是**从厂商官方 demo 抄来的**（demo 里原始的正确接法被注释掉了，说明是后来改错的）。改 3 行即可，绿色通道完全不受影响。

---

## 1. 为什么这个修法必然正确（与 Bayer 相位无关）

用"反相次数奇偶性"来判定，比逐级追颜色更可靠。定义三个 0/1 量：

- **`t`**：debayer 链（传感器相位 + `line_buffer` + `raw_to_rgb`）给出的 `rgb_datax2` 是否 R/B 颠倒；
- **`e`**：`dvi_encoder` 的端口 `i_rdata` 物理上是否其实是蓝（命名反了）；
- **`s`**：编码器输入端是否把 `rdata`/`bdata` 交叉。

**画面是紫的 ⟺ 总反相次数 `t + e + s` 为奇数。**

两个已知事实：

1. 【代码实测】官方 demo 的 `s = 1`（`ti60f225_oob_top.v:963,965` 明确交叉）。
2. 【外部情报】官方 demo 的画面**就是紫的**（"去年企业杯整个画面也是紫的"）。
   ⇒ `t + e + 1` 为奇 ⇒ **`t + e` 为偶数**。

我们的设计目前也是 `s = 1`（交叉发生在 `mmt_top.v:1388-1390`，见 §3），所以同样紫，与情报一致。

**把 `s` 改成 0 之后，总反相次数 = `t + e` = 偶数 ⇒ 颜色正确，无论 `t` 和 `e` 各自取什么值。**

也就是说：这条修法**不需要先知道 IMX219 的实际 Bayer 相位**，也不需要知道 `dvi_encoder`（加密）内部怎么命名。这是本轮最有价值的一点——它把一个"需要上板看颜色"的问题变成了一个可以离线定死的代数问题。

补充：从 `s=1` 反推 `t=0` 也有很强的旁证——官方 demo 注释里保留的原始接法是 `.i_rdata(video_r)`、`.i_bdata(video_b)`，端口名又叫 `rdata_in`/`bdata_in`（`ti60f225_oob_top.v:963-965`），所以 **`e = 0`**，于是 **`t = 0`**，即 **debayer 链本身是对的**。

> 另一个"再错一次抵消"的做法（在 debayer 输出再交叉一次 R/B）虽然也能让画面变正，但会让 OSD **自己画的颜色**跟着反——报警红框在 `mmt_osd_overlay.v:288` 写死 `o_r=8'hFF, o_g=0, o_b=0`，热力图色阶在 `:258-301` 生成。改显示通路则这些颜色同时变正确。所以 P0 是"清零反相"，不是"再叠一次"。

---

## 2. 仿真怎么跑起来的

两个 testbench，一条命令跑完：

```
cd D:\FPGA\mmt
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\debayer\run_debayer.ps1
```
退出码 **0**，末尾打印 `=== OVERALL: DEBAYER + DISPLAY PATH AS EXPECTED ===`。

编译命令（脚本内即是这个，RTL 全部**只读**从 `rtl\` 取）：

```
D:\iverilog\Library\bin\iverilog.exe -g2012 -s tb_debayer -o %TEMP%\debayer_sim\v_ORIGINAL.vvp ^
    rtl\true_dual_port_ram.v rtl\debayer\rgb_gain.v rtl\debayer\line_buffer.v ^
    rtl\debayer\raw_to_rgb.v rtl\debayer\debayer_top_2to1.v sim\debayer\tb_debayer.v
D:\iverilog\Library\bin\vvp.exe %TEMP%\debayer_sim\v_ORIGINAL.vvp

D:\iverilog\Library\bin\iverilog.exe -g2012 -s tb_osd_passthrough -o %TEMP%\debayer_sim\osd.vvp ^
    rtl\mmt\osd\mmt_osd_overlay.v sim\debayer\tb_osd_passthrough.v
```

- `tb_debayer.v`：喂**合成 Bayer 图样**给 `debayer_top_2to1`，做 4 组实验（单点探针 / 纯色场 / 对齐网格 / 斜坡场景），并对比 4 个变体（ORIGINAL / RB_SWAP / ROWFLIP / LEGACY0）。
- `tb_osd_passthrough.v`：同时例化**两份** `mmt_osd_overlay`，一份按"应该有的接法"、一份按**当前 `mmt_top.v:1388-1390` 的接法**，喂同一个像素，比较输出。必须在 `D:\FPGA\mmt` 下运行（`mmt_osd_overlay.v:100` 有 `$readmemh("font8x16.hex")`，文件在工程根目录）。

依赖说明：`line_buffer` 需要 Efinix 原语 `true_dual_port_ram`，工程里已有明文实现 `rtl\true_dual_port_ram.v`（144 行，可直接仿真）。整条 debayer 链**全部是明文**，不需要任何加密 IP，所以这条链路可以 100% 真仿真（不像 AXI 互联那条，见 `docs/AXI互联仿真结论.md`）。

---

## 3. 【实测】显示通路的 R/B 交叉（根因）

### 3.1 代码上的交叉位置

`rtl/mm/mmt_top.v:1382-1390`：
```verilog
mmt_osd_overlay #(
    .H_ACTIVE (1920),
    .V_ACTIVE (1080)
) u_osd (
    .vclk       (hdmi_tx_slow_clk),
    .vrst_n     (w_arstn),
    .i_r        (hdmi_tx_bdata),    // 同上：命名里 r/b 是反的     <-- 蓝接进红
    .i_g        (hdmi_tx_gdata),
    .i_b        (hdmi_tx_rdata),    //                            <-- 红接进蓝
```

而 `rgb_datax2_o` 的真实字节序是 `{r,g,b, r,g,b}`（`debayer_top_2to1.v:151-152`，MSB→LSB），`mmt_top.v:1086/1088` 也是按 `{rdata,gdata,bdata}` 解包的：
```verilog
{hdmi_tx_rdata,hdmi_tx_gdata,hdmi_tx_bdata} <= rgb_datax2[47:24];   // = {r1,g1,b1}
```
所以 **`hdmi_tx_rdata` 就是红**，`:1388-1390` 的注释"命名里 r/b 是反的"是**错的**——它源自 `debayer_top_2to1.v:16` 那句过时注释 `//b,g,r,b,g,r`。

### 3.2 仿真证据

`tb_osd_passthrough.v` 实测输出（驱动像素 `r=0x11, g=0x22, b=0x33`）：

```
  line 0 : driven r/g/b = 11/22/33
             honest  (i_r<-rdata) -> o_r/g/b = 11/22/33     <-- 正接：R/G/B 原样
             CURRENT (i_r<-bdata) -> o_r/g/b = 33/22/11     <-- 现接法：蓝跑到红、红跑到蓝
...
[PASS] honest wiring passes r/g/b straight through
[PASS] CURRENT wiring delivers BLUE (33) on o_r -> the red channel
       => with an honest encoder connection the picture is R/B SWAPPED
[SUMMARY] PASS=2 FAIL=0
```

`mmt_osd_overlay` 主区域是**纯透传**，模块内**没有任何 r/b 交换**：
- `mmt_osd_overlay.v:214-216`：`s1_r <= i_r; s1_g <= i_g; s1_b <= i_b;`
- `mmt_osd_overlay.v:304`（默认分支）：`o_r <= s2_r; o_g <= s2_g; o_b <= s2_b;`

而它到编码器是正接的（`mmt_top.v:1277-1279`）：
```verilog
.i_bdata  (osd_b ),
.i_gdata  (osd_g ),
.i_rdata  (osd_r ),
```
⇒ 蓝一路走到 `i_rdata` ⇒ **TMDS 红通道输出蓝 ⇒ 全屏紫**。

### 3.3 官方 demo 的同款交叉（解释"企业杯也紫"）

`D:\FPGA\易灵思\工作区\07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\rtl\ti60f225_oob_top.v:963-965`：
```verilog
.i_bdata  (hdmi_tx_rdata ),//(video_b  ),//(bdata_in ),   //
.i_gdata  (hdmi_tx_gdata ),//(video_g  ),//(gdata_in ),   //
.i_rdata  (hdmi_tx_bdata ),//(video_r  ),//(rdata_in ),   //
```
**注释里留着的是原始正确接法**（`i_bdata←video_b`、`i_rdata←video_r`，端口名 `bdata_in`/`rdata_in`）。也就是说：原厂本来接对了，后来被改成交叉的；而 demo 是**带着这个 bug 发布的**——这正是群里"去年企业杯整个画面也是紫的"的原因。

---

## 4. 【实测】debayer 是正确 RGGB，以及"紫"的判据

### 4.1 单点探针：哪个 Bayer 位置进哪个输出通道

`PACK=1`（`raw_datax4_i[15:8]` 承载偶列像素，推导见 §4.4）：

| 亮起来的 Bayer 位置 (x 奇偶, y 奇偶) | 输出发亮的通道 |
|---|---|
| (偶, 偶) | **R** |
| (奇, 偶) | **G** |
| (偶, 奇) | **G** |
| (奇, 奇) | **B** |

⇒ 这正是标准 **RGGB**。所以 `raw_to_rgb` 在 `LEGACY=1'b1` 下是一个**相位正确、通道正确**的去马赛克。

### 4.2 纯色场 → 输出三元组

```
  phase  field  ORIG   RB_SWP ROWFLIP LEG0
  RGGB   RED    R      B      G      R
  RGGB   GREEN  G      G      R      G
  RGGB   BLUE   B      R      G      B
  BGGR   RED    B      R      G      B
  BGGR   GREEN  G      G      R      G
  BGGR   BLUE   R      B      G      R
  GRBG   RED    G      G      B      G
  GRBG   GREEN  R      B      G      R
  GRBG   BLUE   G      G      R      G
  GBRG   RED    G      G      R      G
  GBRG   GREEN  R      B      G      R
  GBRG   BLUE   G      G      B      G
```
读法：`ORIG` 列里 `RGGB` 行是 `R/G/B` ⇒ 正确。`BGGR` 行是 `B/G/R` ⇒ **恰好是纯 R/B 对调、绿色不动**。

### 4.3 "紫" = 纯 R/B 对调；判据（不用屏幕也能分辨）

关键事实：**RGGB 与 BGGR 的绿色格点完全相同**，两者只交换 R 和 B。所以：

- **R/B 对调（紫）不可能由任何行/列错位造成。**
- 反过来，行错位（RGGB→GBRG）或列错位（RGGB→GRBG）会**打乱绿色格点**。实测：`ORIG` + `GRBG` 时，纯红场输出的绿色和高达 4950（本该是 0）——红色场里漏出了绿色，这是格点错位的特征，表现为**绿色/棋盘伪影**，不是干净的紫。

⇒ **判据**：画面若是"干净的紫、绿色和边缘正常"，就是 R/B 对调；若出现绿色/棋盘伪影，才是格点错位。本轮情报说的是"全紫"，属于前者，因此与 §3 的显示通路交叉完全吻合。

### 4.4 字节序推导（为什么 `PACK=1` 对应现设计）

链路里有**两次字节交换**，净效果是 `_0` 组 = `raw_datax4_i[15:8]`：

| 位置 | 代码 | 效果 |
|---|---|---|
| `mmt_top.v:710` | `.vout({ch0_g, ch0_b})` | vout[15:8]=ch0_g，vout[7:0]=ch0_b |
| `mmt_top.v:1067` | `.raw_datax4_i({ch0_b, ch0_g})` | **交换①**：raw[15:8]=ch0_b |
| `debayer_top_2to1.v:79` | `.i_p({w_gain_data[7:0], w_gain_data[15:8]})` | **交换②**：i_p[7:0]=raw[15:8] |
| `raw_to_rgb.v:256-257` | `_0 <= i_p[P_DEPTH-1:0]` | `_0` = i_p[7:0] = raw[15:8] = **ch0_b** |

所以 RTL 的"偶列流"是 `ch0_b`，`_1`（奇列流）是 `ch0_g`。

### 4.5 附带实测：`RGB_SWAP` 是数学精确的（斜坡场景验证）

用"R 随 x 斜坡、G=200、B=16"的空间变化场景测试，确认在 debayer 输出交换 R/B **不是**只在纯色场成立的近似：

```
   PACK=1 phase=RGGB（参考，正确）:  32/200/8   40/200/16  48/200/16  56/200/16 ...
   PACK=1 phase=BGGR（当前会紫）  :  16/200/16  16/200/36  16/200/44  16/200/52 ...
   PACK=1 phase=BGGR + RB_SWAP    :  16/200/16  36/200/16  44/200/16  52/200/16 ...
```
BGGR 场景里 R 点在奇列（值 32,40,48…），B 点在偶列；在偶列位置 R 必须由 4 个对角 R 邻居插值 = `(32+40)/2=36`、`(40+48)/2=44`… **与 `RB_SWAP` 的输出逐值吻合** ⇒ 交换是可用的精确补偿。**但本轮不建议用它**（见 §5 末与 §1 的说明）。

---

## 5. 【实测】被排除 / 被否定的四个候选

| 候选 | 改动位置 | 实测结果 | 判定 |
|---|---|---|---|
| ② `LEGACY` 改 `1'b0` | `debayer_top_2to1.v:101` | 24 个用例的判定**与 `LEGACY=1'b1` 完全一致**（`run_debayer.ps1` 的 E6 PASS） | **无效**。原因：`LEGACY` 只影响 `r_y_cnt==0/1` 两行的预热抽头（`raw_to_rgb.v:250-294`），正常行的两条分支赋值相同 ⇒ 至多影响前 2 行输出 |
| ① 把 R/B 增益映射改回 | `debayer_top_2to1.v:45,47` | **no-op**。三个增益都是 `3'd4`（`:19-21`），而 `rgb_gain.v:85-103` 里 `gain[2]=1, gain[1:0]=00` ⇒ `byte + (byte>>1 & 0) + (byte>>2 & 0)` = ×1.0 | **无效**。`rgb_gain` 在这套配置下只是一级寄存器延时（`rgb_gain.v:143-150`） |
| ④ 顶层交换 `{ch0_b, ch0_g}` | `mmt_top.v:1067` | 只是把 `PACK` 翻转：紫从 `BGGR` 相位**搬到** `GBRG` 相位（表里 `GRBG`/`GBRG` 两行），并不产生正确输出 | **不解决问题**。它改的是**列**相位，而"紫"是 R/B（绿格点不变）的问题 |
| ③ 挪一像素/一行相位 | `raw_to_rgb.v:337`（`r_y_cnt[0]` → `!r_y_cnt[0]`） | 实测把"正确相位"从 `RGGB` 变成 `GBRG`；对 `BGGR`（紫的场景）**不修复**（`ORIG` 的 `BGGR` 行是 `B/G/R`，`ROWFLIP` 的 `BGGR` 行是 `G/R/G`） | **不修复紫色**。它是"格点行错位"的修法，对应的是绿色/棋盘伪影那种症状 |
| （备选）debayer 输出交换 R/B | `debayer_top_2to1.v:151-152` | 能把 `BGGR` 变正确（§4.5 证明是精确的） | **能做但不该做**：这是"再叠一次反相去抵消"，会让 OSD 自绘颜色（报警红框、热力图）反过来；且根因在显示通路（§3） |

---

## 6. 修法排序（改哪一行 / 预期 / 风险 / 判据）

### P0 —— 唯一推荐改动（3 行）

**文件**：`rtl/mm/mmt_top.v`，**1388-1390 行**

改成：
```verilog
    .i_r        (hdmi_tx_rdata),    // 红就是红（原注释"命名 r/b 反"是错的，见 docs\去马赛克Bayer相位分析.md）
    .i_g        (hdmi_tx_gdata),
    .i_b        (hdmi_tx_bdata),
```

- **预期效果**：总反相次数 `t+e+s` 从奇数变偶数 ⇒ 画面色相正确；绿色、亮度、同步完全不变（只动 R/B）。
- **风险**：低。3 行改动、纯连线、无逻辑/时序变化；且与 `dvi_encoder` 的加密实现无关。唯一风险是 TMDS/面板侧若还藏有第三个反相（本轮未发现），改完会变成"另一种反"，回退即可。
- **判据**：
  1. 上板/仿真：画面里红色物体显示为红、蓝色为蓝；OSD 报警红框（模块内写死 `o_r=8'hFF,o_g=0,o_b=0`，`mmt_osd_overlay.v:288`）显示为**红色**；温度热力图色阶方向正确。
  2. 离线：`run_debayer.ps1` 里 `tb_osd_passthrough` 的两行应互换——改完后若把该 TB 的 `u_swapped` 也接成正接，`o_r/g/b` 必须回到 `11/22/33`（现为 `33/22/11`）。

### P1 —— 同一处缺陷的第二个副本（建议一起改）

**文件**：`rtl/mm/mmt_top.v`，**1338-1340 行**（`mmt_video_downscale` 输入）
```verilog
    .in_r      (hdmi_tx_rdata),
    .in_g      (hdmi_tx_gdata),
    .in_b      (hdmi_tx_bdata),
```
- **预期**：不影响 HDMI 画面；修正 TinyML 灰度通路的 R/B。该模块用 BT.601 定点加权 `y_sum = in_r*77 + in_g*150 + in_b*29`（`mmt_video_downscale.v:71`），接反后实际算的是 `77·B + 150·G + 29·R`，亮度会有可见偏差（全红场应为 Y≈77，接反后变成 Y≈29）。
- **风险**：极低（只影响送 TinyML 的灰度像素，且变化幅度很小）。
- **判据**：`gray_pix` 对同一场景的数值有微小变化；HDMI 画面不变。

### P2 —— 顺手清理两处错误注释（避免后人再被误导）

1. `debayer_top_2to1.v:16` 的 `//b,g,r,b,g,r` —— 实测真实字节序是 `{r,g,b, r,g,b}`（MSB→LSB）。这句注释是本次误判的源头。
2. `mmt_top.v:1338-1340`、`1388-1390` 的"demo 的命名里 r/b 是反的"—— 已被 §1 的奇偶性论证和官方 demo 的注释证伪。

### 不要做

§5 表格里的四项（`LEGACY`、增益映射、`{ch0_b,ch0_g}` 字节序、行相位翻转）。它们要么实测无效，要么不解决紫色，要么属于"再叠一次补偿"。

---

## 7. 复现方式

```powershell
# 一条命令跑完 debayer 4 变体 + OSD 透传检查，退出码 0 = 全部符合预期
cd D:\FPGA\mmt
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\debayer\run_debayer.ps1

# 单独看 OSD 透传（必须在工程根目录跑，$readmemh 需要 font8x16.hex）
cd D:\FPGA\mmt
D:\iverilog\Library\bin\iverilog.exe -g2012 -s tb_osd_passthrough -o $env:TEMP\osd.vvp `
    rtl\mmt\osd\mmt_osd_overlay.v sim\debayer\tb_osd_passthrough.v
D:\iverilog\Library\bin\vvp.exe $env:TEMP\osd.vvp
```

前置条件：PATH 需含 `D:\iverilog\Library\bin` 与 `D:\iverilog\Library\mingw-w64\bin`（与 `sim\run_all.ps1` 相同）。

---

## 8. 未证实 / 限制

1. **IMX219 的实际 CFA 相位（`t`）**：本轮**不需要**它（§1 的奇偶性论证对 `t` 任意取值都成立），因此没有去证实。工程里只有 `mmt_top.v:682` 一句 `// IMX219` 注释作为器件线索。若将来要改 debayer（例如加宽 ID、换相位）才需要单独确认。
2. **`dvi_encoder` 内部**：`rtl/dvi_tx/dvi_encoder.v_encrypted.v` 是加密的，读不到。`e = 0` 的依据是原厂自己的端口名（`i_rdata`/`i_bdata`）和官方 demo 注释里保留的 `rdata_in`/`video_r`——证据强，但**不是**对模块内部的直接验证。
3. **TMDS/面板侧是否还有第三个反相**：本轮追踪到 `dvi_encoder` 输入为止（`mmt_top.v:1273-1297`），其后是加密模块与 TMDS 输出，未继续追。§1 的结论不受影响（改 `s` 后总数变偶），但若上板后发现仍是"另一种反"，说明这里还有一相，需要再定位。
4. **`mmt_video_downscale`（P1）对最终画面的影响**：它只送 TinyML 灰度通路，**不影响 HDMI 显示**，所以 P1 不是紫色的必要修复，只是同一缺陷的第二个副本。

---

## 9. 附带发现

1. **官方 demo 还把行/场同步交叉了**：`ti60f225_oob_top.v:966-967` 是 `.i_hs(hdmi_tx_vs)` / `.i_vs(hdmi_tx_hs)`。我们的 `mmt_top.v:1280-1281` 是正接的（`.i_hs(osd_hs)` / `.i_vs(osd_vs)`）——**这一条没有继承**，是好事。
2. **`rgb_datax2` 的注释是错的**：`debayer_top_2to1.v:16` 写 `//b,g,r,b,g,r`，但 `:151-152` 的实际拼接是 `{r,g,b, r,g,b}`。这个错误注释很可能就是当年有人把编码器输入改成交叉的动机。
3. debayer 这条链**全明文、依赖少**（4 个 RTL + 1 个原语模型），非常适合做回归；建议把 `run_debayer.ps1` 纳入常规回归（它不碰 `sim\run_all.ps1`，是独立脚本）。

---

## 10. 文件清单

| 文件 | 说明 |
|---|---|
| `sim/debayer/tb_debayer.v` | Bayer 相位 / 颜色映射 testbench（单点探针 + 纯色场 + 网格 + 斜坡，4 变体对比） |
| `sim/debayer/tb_osd_passthrough.v` | `mmt_osd_overlay` 透传 / R-B 接线仿真（根因证据） |
| `sim/debayer/patched/top_rbswap.v` | 变体：debayer 输出交换 R/B |
| `sim/debayer/patched/top_legacy0.v` | 变体：`LEGACY=1'b0` |
| `sim/debayer/patched/raw_to_rgb_rowflip.v` | 变体：行相位翻转 `r_y_cnt[0]` → `!r_y_cnt[0]` |
| `sim/debayer/run_debayer.ps1` | 一键跑全部变体 + 判据断言（退出码 0 = 全部符合预期） |
| `docs/去马赛克Bayer相位分析.md` | 本文档 |

**未修改**：`rtl\**`（本任务只读；P0/P1/P2 的改动由 Lead 应用）、`sim\run_all.ps1` 及其它已有仿真文件、`ip\`、`constr\`、`sw\`、`mmt.xml`。未执行任何 Efinity 流程。
