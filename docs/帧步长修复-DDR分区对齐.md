# 帧步长参数修复：bank 基址算错一倍，会覆盖 TinyML 张量区

> 2026-10-13 · Ti60F225I3 / Efinity 2026.1.132 · 由仿真发现、已修复并重编
> 结论一句话：**`frame_buffer` 例化 `ddr_buffer` 时漏转发三个几何参数，导致帧步长按 1920 版算（是约定值的 2 倍），第 3 个 bank 会写进 TinyML 张量区前 1.8 MB。**

---

## 1. 现象（仿真实测，不是推断）

`sim\frame_wr\tb_frame_addr.v` 用三档帧尺度（SHORT 2,048 / MID 65,280 / REAL 518,400 个 `de` 拍/帧）
观测 `frame_buffer` 的写地址，三档都复现同一组 bank 基址：

```
bank 基址        : 0x02000000 / 0x027E9200 / 0x02FD2400
[RELOAD] 实测值  : wr_start = 0x02000000 / 0x027E9200 / 0x02FD2400
每个 bank 跨度   : 0x7E9200  ×3  ⇒ 三 bank 占用到 0x037BB600
约定区间（文档）  : [0x02000000, 0x02BDDE00)
```

REAL 尺度下每帧 **1013 笔 AW**，最大写地址 **`0x031CC7FF`**（超出区上界约 5.93 MB），
其中 2,026 笔 AW 落在约定区之外。

---

## 2. 根因（算术与仿真逐位吻合）

`rtl\frame_buffer\frame_buffer.v:181` 例化 `ddr_buffer` 时**只转发了 7 个参数**，
漏掉 `FB_NUM` / `MAX_VID_WIDTH` / `MAX_VID_HIGHT` ⇒ `ddr_buffer.v:9-11` 的默认值
（3 / **1920** / 1080）生效 ⇒ `bank_switch.v` 算出的帧步长：

| 版本 | `FRAME_LEN = W×H×32/8 + 0x200` | 三个 bank 基址 |
|---|---|---|
| **960（本工程约定）** | `960×1080×4 + 0x200` = **`0x3F4A00`** | `0x02000000` / `0x023F4A00` / `0x027E9400` |
| **1920（实际生效）** | `1920×1080×4 + 0x200` = **`0x7E9200`** | `0x02000000` / `0x027E9200` / `0x02FD2400` |

**仿真观测到的 `0x027E9200` / `0x02FD2400` 逐位等于 1920 版** ⇒ 根因坐实。

### 为什么可以确定"960 才是对的"

1. **文档自洽（决定性）**：`docs\DDR固件与模型放置方案.md:343` 写
   R5 视频帧缓存 = `0x02000000 – 0x02BDDDFF`，而 **`0x02000000 + 3×0x3F4A00 = 0x02BDDE00`**
   —— 文档边界就是按 960 算出来的；`:351` 还明确写"R5 尾 `0x02BDDDFF` < R7 头 `0x03000000`"。
2. **顶层传的就是 960**：`rtl\mmt\mmt_top.v:701-703` → `.FB_NUM(3) .MAX_VID_WIDTH(960) .MAX_VID_HIGHT(1080)`。
3. **厂商 demo 同源**：`07_官方demo工程\...\ti60f225_oob_top.v:499-501` 也传 960，
   而它共用同一份 `frame_buffer.v` ⇒ **demo 也有这个 bug**（它的 `START_ADDR=0x00000`，布局不同而已）。
4. 全树 grep：算帧步长/bank 基址的只有 `bank_switch.v`（在 `ddr_buffer` 内），无第二处。

---

## 3. 危害：会覆盖 TinyML 张量区（相机一出图就发生）

| 区域 | 地址范围 | 说明 |
|---|---|---|
| R5 视频帧缓存（**实际**，1920 版） | `0x02000000 – 0x037BB600` | bank2 = `[0x02FD2400, 0x031CC800)` |
| **R7 张量/激活区** | `0x03000000 – 0x03FFFFFF` | TinyML 输入/输出/中间张量，**必须 8 字节对齐** |

重叠区间 **`0x03000000 – 0x031CC800` = 1,886,208 字节 ≈ 1.80 MB**。
⇒ **每次写 bank2 就会覆盖 AI 张量区的前 1.8 MB**，只要相机出图就会发生。

> 这正是最难查的一类 bug：编译通过、上板"看着正常"，等 AI 功能打开后才表现为
> **结果乱、偶发崩**，而且会让人怀疑模型/固件而不是帧缓冲。

---

## 4. 修复（3 行参数转发，已应用）

`rtl\frame_buffer\frame_buffer.v` 的 `ddr_buffer #(...)` 参数表里补上：

```verilog
.FB_NUM           ( FB_NUM           ),
.MAX_VID_WIDTH    ( MAX_VID_WIDTH    ),
.MAX_VID_HIGHT    ( MAX_VID_HIGHT    )
```

修复后重跑同一仿真：

```
[RELOAD] wr_start = 0x02000000 / 0x023F4A00 / 0x027E9400     ← 960 版 ✅
REAL 尺度最大地址 = 0x029E3000  <  0x02BDDE00                ← 完全落回 R5 ✅
AW beyond REGION_HI = 0     ⇒ NO OVERFLOW ✅
```

DDR 分区（修复后）：

| 区域 | 范围 | 备注 |
|---|---|---|
| R5 视频帧缓存 | `0x02000000 – 0x02BDDE00` | 3 bank × `0x3F4A00` |
| （空隙） | `0x02BDDE00 – 0x03000000` | 约 4.2 MB 余量 |
| R7 张量区 | `0x03000000 – 0x03FFFFFF` | 与 R5 不再重叠 ✅ |

**重编证据**：两次编译之间唯一的 RTL 改动就是这三行，
`XLR 43,730 → 43,959`（+229）、位流 `out\mmt.bit` 生成于改动之后 ⇒ 修复确实进了位流。
写通路守卫 4 项 PASS、BRAM 235/256、DSP 24/160、未分配引脚 0。

---

## 5. 复现命令

```powershell
# 地址范围核查（SHORT / MID / REAL 三档）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\frame_wr\run_frame_addr.ps1
```

判据：`[RELOAD]` 出现 `0x023f4a00` / `0x027e9400`；`AW beyond REGION_HI = 0`。

> ⚠️ 该 testbench 的 **`bank bases (RTL)` / `actual 3-bank span` 两行是写死的旧值**，
> 与它自己打印的 `[RELOAD]` 实测值不一致（已让作者改为按实测计算）。
> **看结论请以 `[RELOAD]` 实测值与 `AW beyond REGION_HI` 为准。**

---

## 6. 顺带发现（未修，待相机出图后处理）

| 位置 | 问题 | 处置 |
|---|---|---|
| `rtl\frame_buffer\frame_info_det.v:93` | 把 1 位的 `frame_end_r0` 赋给 24 位的 `frame_len_d0`（应是 `frame_cnt` 的笔误）⇒ "连续 3 帧等长"判据**恒真**，负对照（帧长不一致）实测照样会写 | **先不改**：改严后若相机帧长有抖动，可能反而永不触发写通路；等相机出图稳定后再修 |
| `rtl\frame_buffer\DC_FIFO.v:787` | `GrayDecode` 用 `always @(GrayIn)`（敏感表不全）⇒ iverilog 下计数器停 X、仿真里一个 AW 都不会有（综合忽略敏感表，硬件无影响） | 建议改 `always @(*)`（零功能风险，消除仿真/综合不一致） |
