# 帧缓冲写通路 RTL 功能仿真

- 工程：`D:\FPGA\mmt`（Efinix Efinity 2026.1.132，Ti60F225I3）
- 任务：task-20 —— 给 `frame_buffer` 喂**有效的合成视频时序**，用仿真回答"它的写通路到底会不会产生 AXI 写"
- 日期：2026-10-13
- 仿真目录：`D:\FPGA\mmt\sim\frame_wr\`

---

## 0. 结论先行

| 问题 | 答案 | 等级 |
|---|---|---|
| **总结论** | **在给定有效视频时序时，厂商 `frame_buffer` 的写通路是正常的**：`frame_start`/`frame_stable` 会置位、写 FIFO 会填、`awvalid` 会拉高、地址 = `0x02000000` 起、突发长度符合 `BURST_LEN`、`wlast` 逐拍正确 | **实测** |
| **对上板现象的意义** | 上板 `AW=0 W=0 st=0x00` **不是写通路的 RTL bug**，而是**上游根本没有有效视频**（没有让 `frame_stable` 置位的连续帧、或没有 `de`/`vs`） | **推断（证据链强）** |
| Q1 `frame_start`/`frame_stable` 会置位吗 | **会**。`frame_start` 每帧起始一个脉冲（实测 3 次）；`frame_stable` 在第 3 帧结束处拉高并保持（t=66945 ns）。`ddr_frame_len` 正确算出 **512** 个 128-bit 字 | **实测** |
| Q2 `awvalid` 会拉高吗？地址/突发长度对吗 | **会**。首个 AW：`t=72725ns awaddr=0x02000000 awlen=127 awsize=4 awburst=1 awid=0xd` —— 地址正是 `START_ADDR`，`awlen=127` 与 `BURST_LEN=127` 一致，`awsize=4`=16 字节/拍。地址按 2048 字节线性推进（`0x02000000 → 0x02000800 → 0x02001000 → 0x02001800`） | **实测** |
| Q3 `wvalid`/`wlast` 出现吗？FIFO 行为 | **出现**。实测 1424 个 W 拍、12 次 `wlast`，每个突发 = `awlen+1` 拍（128/128/128/128/64/128…），**0 次拍数不匹配**；**12 个 B 响应**。写 FIFO 先填到 **128 字**（= `ddr_awlen`+1）后由 128 拍突发抽干 → `rdusedw` 峰值 128、`wrfull` 从未拉高 | **实测** |
| Q4 三帧长度不一致时会不会不写 | **仍然会写**（负对照失败）。UNEQUAL 场景下 `frame_stable` 照样在 t=61465 拉高、照样产生 10 个 AW / 8 个完成突发。根因见 §4：`frame_info_det.v:93` 把 `frame_end_r0`（1 位）赋给了 24 位的 `frame_len_d0`，使"三帧等长"判据**恒真** | **实测 + 代码证据** |
| 附带发现 1（真缺陷） | `frame_info_det.v:93` `frame_len_d0 <= frame_end_r0;` 几乎必然是 `frame_cnt` 的笔误 → 帧长稳定性检查形同虚设 | **代码证据** |
| 附带发现 2（仿真陷阱） | `DC_FIFO.v:787` `GrayDecode` 用 `always @ (GrayIn)`，**敏感表不全**；iverilog 下当输入不变时输出恒为 X，导致 `WrDNum/RdDNum = X`、`wr_req` 恒假、**仿真里一个 AW 都不会有**（见 §2） | **实测** |
| 附带发现 3（开放项） | 4 个突发后写地址跳到 `0x02fd2400`，**超出 3 bank 视频区**（`0x02000000`+3×FRAME_LEN=0x02C5DE00）。**根因未查明**，可能是"合成帧太小"的产物，需用接近真实的帧长复跑 | **实测现象 / 未能定性** |

**一句话给 Lead**：写通路的 RTL 是好的——给有效时序就正常写。所以上板 `AW` 恒 0 说明**摄像头侧没有把有效视频送到帧缓冲**，火力应集中到 MIPI/CSI 上游。但有两件事要顺手处理：① `DC_FIFO.v:787` 的敏感表建议补全（虽然综合器当组合逻辑处理，但这是个仿真/综合不一致的隐患）；② `frame_info_det.v:93` 的帧长判据要修（现在等于没有）。

---

## 1. 证据分级

- **实测**：本机真跑过，命令 + 原始输出可复现（`run_frame_wr.ps1` 退出码 0）。
- **代码证据**：直接读 RTL 并给出 `文件:行`。
- **推断**：由实测+代码推出的结论。
- **未能定性**：现象可复现但根因未查明。

**⚠️ 诚实声明（很重要）**：厂商 RTL **没有**被修改（`rtl\` 只读），但仿真是在 `%TEMP%\frame_wr_sim\src\` 的一份**打了 3 处 shim 的副本**上跑的。3 处 shim 全部是 iverilog 兼容性/仿真语义问题，**不改变逻辑功能**，见 §2。其中第 3 处（`GrayDecode`）直接决定了"能不能看到写"，必须重点看。

---

## 2. 为什么需要 3 处 shim（以及它们为什么不影响结论）

### shim 1+2：iverilog 不接受未定宽字面量

```
rtl\frame_buffer\ddr_wr_buffer.v:262:  assign nx_ddr_wr_addr = ddr_wr_addr + {(ddr_awlen+1) ,{WR_ADDR_SHIFT_BITS{1'b0}}};
rtl\frame_buffer\ddr_rd_buffer.v:194:  assign nx_ddr_addr    = ddr_addr    + {(ddr_arlen+1),{ADDR_SHIFT_BITS{1'b0}} };
```
`(ddr_awlen+1)` 里的 `1` 是未定宽字面量，放在拼接里 iverilog 报
`error: Concatenation operand "(ddr_awlen)+('sd1)" has indefinite width`（`-g2005 / -g2009 / -g2012` **全部**报错）。
shim 改成 `(ddr_awlen+9'd1)` / `(ddr_arlen+9'd1)`：对 `awlen/arlen ≤ 255` 数值完全相同（9 位足够放下 255+1）。

### shim 3：`GrayDecode` 敏感表不全 —— 这是仿真能不能跑通的关键

`rtl\frame_buffer\DC_FIFO.v:787`（模块 `GrayDecode`）：
```verilog
reg [DW_C-1:0] Hex;
integer i;
always @ (GrayIn)                      // <-- 敏感表只有 GrayIn
begin
    Hex[DW_C-1]=GrayIn[DW_C-1];
    for(i=DW_C-2;i>=0;i=i-1) Hex[i]=Hex[i+1]^GrayIn[i];
end
assign HexOut = Hex;
```

- 这个 `always` 块**只有在 `GrayIn` 发生变化时才执行**。`Hex` 是 reg，未初始化时是 X。
- `WRAGray2Hex` 的输入是 `WrRdAddr`（写时钟域同步过来的读地址），它在整段仿真里**恒为 0、从不翻转** ⇒ 该 always 块**一次都不执行** ⇒ `Hex` 永远 X ⇒ `WrRdAHex = X` ⇒ `WrAddrDiff = X` ⇒ `WrDNum = X`。
- 于是 `ddr_wr_buffer.v:322` 的 `wr_req <= (wr_fifo_rdusedw > ddr_awlen)` 结果是 **X**，Verilog 里 `if(X)` 取假 ⇒ **写状态机永远停在 state 1，一个 AW 都不发**。

**实测证据**（shim 之前，`%TEMP%` 日志）：
```
[FIFO] t=67305  WrEn=0 FifoWrAddr=00000000000 WrRdAddr=00000000000 WrWrAHex=0000000000 WrRdAHex=xxxxxxxxxx WrDNum=0
[FIFO] t=67315  WrEn=1 FifoWrAddr=00000000000 WrRdAddr=00000000000 WrWrAHex=0000000000 WrRdAHex=xxxxxxxxxx WrDNum=x
[FIFO] t=67325  WrEn=0 FifoWrAddr=00000000001 WrRdAddr=00000000000 WrWrAHex=0000000001 WrRdAHex=xxxxxxxxxx WrDNum=x
```
注意 `WrWrAHex`（来自会翻转的 `FifoWrAddr`）**解码正确**（0→1→2→3→4→5），而 `WrRdAHex`（来自不翻转的 `WrRdAddr`）恒为 X —— 完全印证"输入不变则该块不执行"。

**为什么这不算厂商的硬件 bug**：综合器（Verific/Efinity）对组合逻辑 `always` 块**忽略敏感表**，把它推断成纯组合逻辑（`Hex` 不会有触发器），所以硬件上 `HexOut` 始终是 `GrayIn` 的组合函数，行为正确。shim 把它改写成等价的连续赋值（gray→binary 的前缀异或），**让仿真模型与综合结果一致**：

```verilog
wire [DW_C-1:0] sh1 = GrayIn ^ (GrayIn >> 1);
wire [DW_C-1:0] sh2 = sh1 ^ (sh1 >> 2);
wire [DW_C-1:0] sh4 = sh2 ^ (sh2 >> 4);
wire [DW_C-1:0] sh8 = sh4 ^ (sh4 >> 8);
assign HexOut = sh8;      // 与 Hex[i]=Hex[i+1]^GrayIn[i] 完全等价
```
（顺带试过只把 `@(GrayIn)` 改成 `@(*)`：**不够**，因为 iverilog 在时间 0 不主动求值 `@(*)` 块，输入不变时依旧不执行。）

shim 之后同一窗口：
```
[FIFO] t=67305  ... WrWrAHex=0000000000 WrRdAHex=0000000000 WrDNum=0
[FIFO] t=67325  ... WrWrAHex=0000000001 WrRdAHex=0000000000 WrDNum=1
```
计数正常了，AW 立刻出现（§3）。

> **对 Lead 的建议**：把 `DC_FIFO.v:787` 的 `always @ (GrayIn)` 直接改成 `always @ (*)`（或改成上面的 assign）是**零功能风险**的健壮性修改，能消除"仿真看不到写 / 换工具行为不一致"的隐患。这是本轮唯一建议改动厂商 RTL 的地方。其余两处若嫌麻烦可以不改（只影响 iverilog）。

---

## 3. Q1–Q4 逐条实测

运行命令：
```powershell
cd D:\FPGA\mmt
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\frame_wr\run_frame_wr.ps1
# 退出码 0；三个场景各自 PASS
```

testbench 配置（与 `rtl\mmt\mmt_top.v:692-706` 逐参数一致）：
`I_VID_WIDTH=32 O_VID_WIDTH=16 AXI_DATA_WIDTH=128 AXI_ADDR_WIDTH=32 START_ADDR=0x02000000 BURST_LEN=127 FB_NUM=3 WR_FIFO_DEPTH=1024 RD_FIFO_DEPTH=512 MAX_VID 960x1080`；
时钟 `i_clk=100MHz axi_clk=100MHz o_clk≈71MHz`；合成视频 128 像素/行 × 16 行 = 2048 个 `de` 拍/帧 = 8192 字节 = **512 个 128-bit 字**；共 6 帧。

### Q1 —— `frame_start` / `frame_stable` 会置位 ✅【实测】

```
[Q1] t=22705 ns  frame_start PULSE #1 (frame_cnt=0 ddr_frame_len=512)
[Q1] t=66945 ns  frame_stable RISES (1st time)  frame_cnt=0 ddr_frame_len=512
[Q1] t=89545 ns  frame_start PULSE #2 (frame_cnt=0 ddr_frame_len=512)
[Q1] t=111825 ns frame_start PULSE #3 (frame_cnt=0 ddr_frame_len=512)
```
- `frame_stable` 在**第 3 帧结束**处拉高（t=66945，第 3 帧 44950 开始、第 4 帧 67230 开始）——与 §4 的"3 帧判据"一致。
- `ddr_frame_len = 512` = `2048×4/16` ✓ 完全正确。
- **系统级含义**：`wr_start = frame_start & frame_stable`（`frame_buffer.v:196`），所以**前 3 帧一定不写**，从第 4 帧才开始写。这是设计意图，不是 bug。

### Q2 —— `awvalid` / 地址 / 突发长度 ✅【实测】

```
[AW]  t=72725 ns  #1  awaddr=0x02000000 awlen=127 awsize=4 awburst=1 awid=0xd
[AW]  t=78205 ns  #2  awaddr=0x02000800 awlen=127 awsize=4 awburst=1 awid=0xd
[AW]  t=83685 ns  #3  awaddr=0x02001000 awlen=127 awsize=4 awburst=1 awid=0xd
[AW]  t=89165 ns  #4  awaddr=0x02001800 awlen=127 awsize=4 awburst=1 awid=0xd
```
- 首地址 = `START_ADDR` = `0x02000000` ✓（`mmt_top.v:695`）
- `awlen=127` = `BURST_LEN-1` ✓；`awsize=4` = 16 字节/拍 ✓；`awburst=1` = INCR ✓
- 地址按 `(awlen+1)×16 = 2048` 字节线性推进 ✓
- `awid=0xd`——这是队友在 task-2 之后改的（`ddr_wr_buffer.v:494` `assign awid = 6'h0D;`），与 TinyML 的 ID=0 互斥 ✓
- 总计 **14 个 AW 握手**（6 帧里有效写入的是第 4~6 帧）

### Q3 —— `wvalid` / `wlast` / FIFO ✅【实测】

```
[W ]  t=74005 ns  burst #1 finished: 128 beats (awlen gave 128)
[W ]  t=79485 ns  burst #2 finished: 128 beats (awlen gave 128)
[W ]  t=84965 ns  burst #3 finished: 128 beats (awlen gave 128)
[W ]  t=92905 ns  burst #4 finished: 64 beats  (awlen gave 64)
...
Q3  W beats       = 1424   wlast count = 12
Q3  B responses   = 12
Q3  burst beat mismatch = 0
Q3  write-FIFO wrusedw max=1  rdusedw max=128  wrfull=0 (0 clk)
```
- 每个突发的 W 拍数 **严格等于 `awlen+1`**，**0 次不匹配** ✓
- 12 个突发全部以 `wlast` 收尾并收到 12 个 B 响应 ✓
- 写 FIFO 先填到 **128 字**（`rdusedw` 峰值 128）后被 128 拍突发抽干 → 这就是 `wr_req = rdusedw > ddr_awlen(=127)` 的门限行为，**FIFO 从未溢出**（`wrfull` 全程 0）✓
- 最后 2 个 AW 在视频停止时仍在飞行（burst 未收尾）——符合预期，属测试激励截断，非缺陷

### Q4 —— 长度不一致时不写？**❌ 判据失效，仍然会写**【实测 + 代码证据】

UNEQUAL 场景（奇偶帧 16/12 行交替）：
```
[Q1] t=61465 ns  frame_stable RISES (1st time)  frame_cnt=0 ddr_frame_len=512
Q2  AW handshakes = 10
Q2  first AW: t=67245 ns addr=0x02000000 len=127
Q3  W beats = 1041   wlast count = 8
[NOTE] UNEQUAL run: frame_stable asserted 1 time(s)
```
**三帧长度不一致，`frame_stable` 照样拉高，照样写。**

根因（`rtl\frame_buffer\frame_info_det.v:86-97`）：
```verilog
end else if( frame_end_r0 ) begin
    frame_len_d0 <= frame_end_r0;   // ← 第 93 行：把 1 位的"帧结束"脉冲当成帧长
    frame_len_d1 <= frame_len_d0;
    frame_len_d2 <= frame_len_d1;
end
```
`frame_len_d0` 是 24 位、`frame_end_r0` 是 1 位，赋值后 `frame_len_d0` 恒为 `1`。于是第 104 行的判据
```verilog
if( frame_len_d0 == frame_len_d1 && frame_len_d0 == frame_len_d2 ) frame_stable <= 1'b1;
```
在**任何**帧长下都成立（三帧后 d0/d1/d2 都变成 1）。**它几乎必然是 `frame_len_d0 <= frame_cnt;` 的笔误。**

- 影响的**方向是"更宽松"**（该拦的不拦），所以它**不能**解释上板"AW 恒 0"；但它是真缺陷：只要连来 3 帧（哪怕长度乱七八糟）就会开始写 DDR。
- **建议修法**：`frame_info_det.v:93` 改成 `frame_len_d0 <= frame_cnt;`（该模块第 28 行已有 `frame_cnt`）。改完 Q4 场景应变成"`frame_stable` 不置位、AW = 0"。这条要 Lead 改（我只读未改）。

---

## 4. 附带发现 3：写地址越界（**开放项，未能定性**）

三个场景都能复现同一个现象：前 4 个突发从 `0x02000000` 线性推进后，第 5 个突发跳到 `0x02fd2400`：

```
[AW] #1 0x02000000  [AW] #2 0x02000800  [AW] #3 0x02001000  [AW] #4 0x02001800
[AW] #5 0x02fd2400  [AW] #6 0x02fd2800  [AW] #7 0x02fd3000  [AW] #8 0x02fd3800  [AW] #9 0x02fd4000
[AW] #10 0x027e9200
```
- 3 bank 视频区应为 `0x02000000` .. `0x02000000 + 3×FRAME_LEN`；`FRAME_LEN = 960*1080*32/8 + 0x200 = 0x3F4A00`（`bank_switch.v:32`）⇒ 上界约 `0x02C5DE00`。
- `0x02fd2400 > 0x02C5DE00` ⇒ **第 5~9 个突发落在 3 bank 区之外**，而它们紧邻 `0x02000000 + 4×FRAME_LEN`（`4×0x3F4A00 = 0xFD2800`）。看起来写地址按"每帧前进一个 FRAME_LEN"线性增长，而不是被 bank 切换限制在 3 个 bank 内。
- 读侧地址在 `0x027e9xxx`（≈ `2×FRAME_LEN + START_ADDR`），与写侧 `0x02fd2xxx`（≈ `4×FRAME_LEN`）并不对应。

**为什么不定性**：我的合成帧只有 2048 个 `de` 拍（8192 字节），而 `bank_switch` / `burst_num` / `burst_last` 这套逻辑是按**真实大帧**（`MAX_VID_WIDTH×MAX_VID_HIGHT`）设计的；bank 切换由 `burst_last`（= `burst_add_en && burst_num == total_burst_num+2`，`ddr_wr_buffer.v:310`）触发，而 `burst_num` 由 `ddr_frame_len` 算出——**小帧下这套计数很可能走了非典型分支**。

**结论**：**无法确认**这是真 bug 还是小帧激励的产物。**建议下一步**：把 TB 的 `H_ACTIVE/V_ACTIVE` 调到接近真实帧（例如 960×1080 = 1,036,800 个 de 拍 → 259,200 个 128-bit 字，仿真会慢但可行；或折中 480×270），复跑并检查写地址是否始终落在 3 bank 区内。**在上板之前应该把这一条查清**——若真越界，会写坏 TinyML/其它 DDR 数据。

---

## 5. 修法清单（我未改任何 `rtl\`）

| 优先级 | 位置 | 改动 | 预期 / 判据 | 风险 |
|---|---|---|---|---|
| P0（建议） | `rtl\frame_buffer\DC_FIFO.v:787` | `always @ (GrayIn)` → `always @ (*)`（或改成 gray→bin 的 assign） | 消除"敏感表不全"的仿真/综合不一致隐患。判据：本仿真**不用 shim 也能跑出 AW** | 零（综合器本来就当组合逻辑） |
| P0（建议） | `rtl\frame_buffer\frame_info_det.v:93` | `frame_len_d0 <= frame_end_r0;` → `frame_len_d0 <= frame_cnt;` | 恢复"三帧等长才写"的判据。判据：`run_frame_wr.ps1` 的 **VS1-UNEQUAL 场景应变成 `frame_stable` 不置位、AW=0** | 低；但会让"帧长偶尔抖动"时更晚开始写（这是原设计意图） |
| P1（调查） | 写地址推进 | 先用真实尺度帧复跑，确认 §4 是否真越界 | 若越界，再查 `bank_switch.v` 的 `dirt_bank/clean_bank` 轮转与 `ddr_wr_buffer` 的 `burst_num/burst_last` | — |
| **不要做** | 写通路逻辑 | 不要因为上板 `AW=0` 去改 `ddr_wr_buffer`/`ser2par` | 本仿真证明它工作正常；问题在上游 MIPI/CSI | — |

---

## 6. 复现方式

```powershell
# 一条命令跑 3 个场景（VS1-EQ / VS1-UNEQUAL / VS0-EQ），退出码 0
cd D:\FPGA\mmt
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\frame_wr\run_frame_wr.ps1

# 脚本会在 %TEMP%\frame_wr_sim\ 下留下：
#   src\                  打 shim 的厂商源码副本（供审计）
#   shims_applied.txt     哪几个文件被 shim 了
#   res_<场景>.log        三个场景的完整原始输出
```

前置条件：PATH 需含 `D:\iverilog\Library\bin` 与 `D:\iverilog\Library\mingw-w64\bin`。

---

## 7. 限制 / 未证实

1. **必须打 shim 才能看到写**：因为 `GrayDecode` 的敏感表问题（§2）。本轮论证了"综合器会当组合逻辑"，所以 shim 后的结论**代表硬件行为**；但严格说，这条依赖"Efinity/Verific 确实把该 always 块推断为组合逻辑"这一前提（未用 Efinity 复核——本任务不允许跑 Efinity）。**若想彻底消除这个前提**，就采纳 §5 的 P0 修改。
2. **合成帧远小于真实帧**（2048 de 拍 vs 真实 960×1080+），所以 `bank_switch`/突发切分走了非典型分支 → §4 的地址越界**未能定性**。
3. **`i_vs` 极性两种约定都测了**（VS_MODE=1 跨整个有效帧、VS_MODE=0 只在消隐期脉冲），**两种都能正常写**（`frame_info_det` 的 `negtive_sync` 自适应）。所以上板"不写"不能用 vs 极性解释。
4. **未测异常/背压场景**：`awready`/`wready` 全程立即响应，没有测 DDR 侧反压下的行为，也没有测中途 `i_vs` 丢失。
5. **`frame_cnt` 计数与 `frame_pix_num` 的配合**未逐帧核对（只在 512 字的 `ddr_frame_len` 上验证了总量正确）。

---

## 8. 文件清单

| 文件 | 说明 |
|---|---|
| `sim/frame_wr/tb_frame_wr.v` | testbench：例化厂商 `frame_buffer` + AXI 写/读从机模型 + 合成视频激励 + Q1~Q4 探针与断言 |
| `sim/frame_wr/run_frame_wr.ps1` | 一键脚本：生成 shim 副本（含审计记录）+ 编译 + 跑 3 个场景 |
| `docs/帧缓冲写通路RTL仿真.md` | 本文档 |

**未修改**：`rtl\**`（只读；shim 只作用于 `%TEMP%` 的副本）、`mmt.xml`、`sim\` 下其它文件（含 `sim\run_all.ps1`）、`ip\`、`constr\`、`sw\`。未执行任何 Efinity 流程。

---

## 9. 【更正 2026-10-13，task-21】§4「附带发现 3」的结论是错的

本文件 §4 说 `0x02fd2400` "超出 3 bank 视频区、像按每帧一个 FRAME_LEN 线性增长"，并在 §0 表格里把它标成"未能定性"。**task-21 已查明，该表述有误，以 `docs\帧缓冲写地址范围核查.md` 为准**：

1. **`FRAME_LEN` 根本不是 960 版。** `frame_buffer.v:181-189` 例化 `ddr_buffer` 时**没有传** `MAX_VID_WIDTH / MAX_VID_HIGHT / FB_NUM`，于是 `ddr_buffer.v:8-10` 的默认值（3 / **1920** / **1080**）生效 ⇒ `bank_switch.v:32` 得 `FRAME_LEN = 1920×1080×32/8 + 0x200 = 0x7E9200`（8.29 MB），而不是本文件假设的 960 版 `0x3F4A00`（4.15 MB）。
2. **`0x02fd2400` 就是 bank2 的基址**（`START_ADDR + 2×0x7E9200`），**不是地址跑飞**。同理仿真实测到的 `rd_start_addr = 0x027e9200` = bank1 基址（`START_ADDR + 1×0x7E9200`）——两个观测值都只能用 1920-based 的 `FRAME_LEN` 精确解释。
3. **越界的真实上界是 `0x02BDDE00`**（960 版 3 bank 的末尾，与工程文档 `0x02000000–0x02BDDDFF` 一致），本文件写的 `0x02C5DE00` 是笔误。
4. **结论方向不变但严重性更高**：写地址**确实越界**，真实帧长（`de` 拍/帧 = 518,400）下最大写地址 `0x031CC7FF`，并把 **R7 张量/激活区（`0x03000000` 起）的前 1.80 MB 覆盖掉**。修法见 `docs\帧缓冲写地址范围核查.md` §5（`frame_buffer.v` 补 3 行参数转发）。

§4 里"我的合成帧太小所以未能定性"这个自我限制，事后看是**参数算错**（用了 960 版 `FRAME_LEN`）而不是帧长不够；task-21 用 SHORT / MID(65,280 de/帧) / REAL(518,400 de/帧) 三个尺度都已复现同一个 bank2 基址。
