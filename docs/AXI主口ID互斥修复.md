# AXI 主口 ID 互斥修复（frame_buffer 硬连线 ID=0 → 0xC / 0xD）

- 工程：`D:\FPGA\mmt`（Efinix Efinity 2026.1.132，器件 Ti60F225I3，顶层 `mmt_top`）
- 任务：task-6 —— 判定 frame_buffer 的 AXI ID 是否为纯 tag，若是则把两处硬连线 ID 改成"低 4 位非 0 且与其它主口互斥"的常量
- 日期：2026-10-11
- 执行者：fb-id-fixer
- 上游证据：`docs\AXI互联仿真结论.md`（task-2，axi-sim）

---

## 0. 结论先行（TL;DR）

| 问题 | 结论 | 证据等级 |
|---|---|---|
| frame_buffer 的 AXI ID 是纯 tag 吗？ | **是，纯 tag**。`arid`/`awid` 只在一条 `assign` 里被赋常量；回程 `rid`/`bid` 在整个 frame_buffer 子树里**除端口声明外零引用**（无比较、无选择、无握手判断） | **静态实测（`文件:行`）** |
| 改动 | 2 处，各 1 行，全项目仅此 2 处驱动这两个 ID | **静态实测 + iverilog 实测** |
| 读 ID | `rtl\frame_buffer\ddr_rd_buffer.v:227`：`6'h00` → **`6'h0C`** | 实测 |
| 写 ID | `rtl\frame_buffer\ddr_wr_buffer.v:494`：`8'd0` → **`6'h0D`** | 实测 |
| 为什么不会撞 | 顶层取低 4 位（`mmt_top.v:768/795`）→ s0 发 **0xC / 0xD**；s2（TinyML）经证据链确认实质为 **0**；已确认的 s0↔s2 冲突被消除。且 0xC/0xD 位于 4 位空间高半区、又避开了现有仿真常量 0x0/0x5/0xA | 静态实测 + 推断（SoC 部分见第 6 节） |
| 是否规避 >0xF 截断风险 | **规避**。0xC/0xD ≤ 0xF，截断+零扩展是恒等映射（0x0C→0xC→0x0C） | 静态实测 |
| RTL 语法/常量验证 | iverilog 探针实测输出 `arid=0c awid=0d`，`ID PROBE: PASS`，退出码 0 | **实测** |
| 残留风险 | Sapphire SoC 的 4 位 ID 不可控（加密网表）；若它也用 0xC/0xD 仍会撞。本任务无权限修 SoC 侧 | 未证实 |

**一句话**：ID 是纯 tag，两处硬连线常量已改成 `6'h0C`（读）/ `6'h0D`（写），已确认的 s0↔s2 同 ID=0 冲突被确定性消除，且**不依赖**厂商 IP 是"按端口记账"还是"按 ID 记账"。

---

## 1. 证据链：ID 在 frame_buffer 里的用法

### 1.1 检索方法（可复现）

对两个目标文件做"**包含 awid/arid/bid/rid 的任意标识符**"大小写不敏感全文检索（`grep -i -E '\w*(awid|arid|bid|rid)\w*'`），命中数如下：

| 文件 | 命中总数 | 命中行 |
|---|---|---|
| `rtl\frame_buffer\ddr_rd_buffer.v` | **4** | 29, 42, 49, 227 |
| `rtl\frame_buffer\ddr_wr_buffer.v` | **3** | 28, 50, 494 |

**这就是全部**——文件中不存在 `rid_r`、`bid_cnt`、`arid_reg` 之类派生信号。

### 1.2 ddr_rd_buffer.v（读通道）

```
 29: output [5:0] 									    arid,      ← 端口声明（输出）
 42: input [5:0] 									rid,       ← 端口声明（输入）
 49: input [5:0] 									bid,       ← 端口声明（输入）
227: assign arid     = 6'h0C;  // ...                                      ← 唯一驱动
```

- `arid`：**只有 227 行这一条 `assign` 驱动它是常量**。全文再无第二处引用 → 它是纯粹的"贴出去就不管"的标签。
- `rid`（第 42 行）：**除端口声明外零引用**。没有任何 `if (rid == ...)`、没有 case、没有赋值给别的信号。→ 回程读 ID 是**死输入**。
- `bid`（第 49 行）：同上，**零引用**。→ 回程写 ID 也是**死输入**。

### 1.3 ddr_wr_buffer.v（写通道）

```
 28: output [5:0] 								awid,      ← 端口声明（输出）
 50: input [5:0] 								bid,       ← 端口声明（输入）
494: assign awid 		= 6'h0D;  // ...                               ← 唯一驱动
```

- `awid`：只有 494 行这一条 `assign`。
- `bid`（第 50 行）：**除端口声明外零引用**，死输入。
- 该模块**根本没有** `arid`/`rid` 端口（它是纯写模块）。

### 1.4 上层只是透传，没有任何 ID 逻辑

| 文件 | 行 | 内容 | 判定 |
|---|---|---|---|
| `rtl\frame_buffer\frame_buffer.v` | 44 / 59 | `output [5:0] awid` / `arid` | 声明 |
| | 78 / 85 | `input [5:0] rid` / `bid` | 声明 |
| | 216 / 227 / 246 / 252 | `.awid(awid)` `.arid(arid)` `.rid(rid)` `.bid(bid)` | 仅端口连线 |
| `rtl\frame_buffer\ddr_buffer.v` | 45 / 60 / 80 / 87 | 同上 4 个端口声明 | 声明 |
| | 139 / 191 | `.awid(awid)` / `.arid(arid)` | 仅端口连线 |
| | 203 / 210 / 158 | `.rid(rid)` / `.bid(bid)` / `.bid(bid)` | 仅端口连线（bid 同时接给读、写两个子模块） |

`frame_buffer.v` / `ddr_buffer.v` 内**没有任何** ID 相关的判断、计数或选择逻辑——检索命中全部是端口声明与端口连线。

### 1.5 顶层：截断去程、零扩展回程

`rtl\mmt\mmt_top.v`：

```
325: wire [5:0]  fb_awid;     341: wire [5:0] fb_bid;
344: wire [5:0]  fb_arid;     355: wire [5:0] fb_rid;

658:   frame_buffer #( ... ) checker0 (          ← 实例名 checker0
696:        .awid  (fb_awid),    707: .arid (fb_arid),
726:        .rid   (fb_rid ),    733: .bid  (fb_bid ),

745: wire [3:0] ic_bid_p0, ic_bid_p1, ic_bid_p2;
746: wire [3:0] ic_rid_p0, ic_rid_p1, ic_rid_p2;
747: assign fb_bid      = {2'b00, ic_bid_p0};   // 6 位：零扩展
749: assign fb_rid      = {2'b00, ic_rid_p0};

753: axi_interconnect u_ddr_axi_ic (
768:     .s_axi_awid  ({tml_awid[3:0],  soc_ddr_awid[3:0], fb_awid[3:0]}),   // 只取低 4 位
795:     .s_axi_arid  ({tml_arid[3:0],  soc_ddr_arid[3:0], fb_arid[3:0]}),
```

- **去程**：`fb_awid[3:0]` / `fb_arid[3:0]` —— 6 位里高 2 位被丢弃，只有低 4 位进互联。
- **回程**：`fb_bid` / `fb_rid` 由 4 位零扩展成 6 位，送进 `ddr_wr_buffer.bid` / `ddr_rd_buffer.rid`，而这两个输入**是死输入**（§1.2/§1.3）。
- 结论：**改 ID 不需要同步改任何比较值**——本项目里不存在任何 ID 比较逻辑。

### 1.6 判定

> **frame_buffer 的 AXI ID 是纯 tag。**
> 去程只往外发常量，回程 `rid`/`bid` 落进死输入，frame_buffer 从不校验响应 ID。
> ⇒ 改这两个常量**在 frame_buffer 内部零功能影响**；唯一影响是互联收到的 4 位 ID 值。

因此按 task-6 第 2 条执行修改（不是第 3 条的替代方案）。

---

## 2. 改动清单（本任务全部写操作）

| # | 文件 | 行 | 原值 | 新值 |
|---|---|---|---|---|
| 1 | `rtl\frame_buffer\ddr_rd_buffer.v` | 227 | `assign arid     = 6'h00;` | `assign arid     = 6'h0C;` |
| 2 | `rtl\frame_buffer\ddr_wr_buffer.v` | 494 | `assign awid 		= 8'd0;` | `assign awid 		= 6'h0D;` |

改后实际内容：

```verilog
// ddr_rd_buffer.v:227
assign arid     = 6'h0C;  // AXI 读 ID：低 4 位 = 0xC，非 0，与 TinyML(0) 互斥；本模块不使用 rid，ID 为纯 tag

// ddr_wr_buffer.v:494
assign awid 		= 6'h0D;  // AXI 写 ID：低 4 位 = 0xD，非 0，与 TinyML(0) 互斥；本模块不使用 bid，ID 为纯 tag
```

附带修掉一个既有小瑕疵：原 `ddr_wr_buffer.v:494` 用 `8'd0` 给 **6 位**端口赋值，是隐式位宽截断；新写法 `6'h0D` 与端口位宽一致，综合/仿真都不再产生位宽不匹配告警。

### 2.1 为什么读、写用两个不同的值（而不是同一个）

1. **功能上两者等价**：AXI4 的 B 通道（`bid`）与 R 通道（`rid`）是物理独立的响应通道，读写事务的响应路径不共享，同值不会造成歧义。
2. **选不同的理由**：互联 IP 内部（`efx_axi_interconnect_*`）是加密的，属于黑盒。给读、写用**不同**的 ID 后，任何"读响应错跑到写路径 / 写响应错跑到读路径"之类的残余异常在波形和日志里都能**直接看出来**（`arid=0xC` 却收到 `rid=0xD` 之类），诊断成本更低。代价只是多占用 4 位 ID 空间里的一个码点，相对"SoC ID 不可控"这个更大的残余风险可忽略。
3. 两值都 ≤ 0xF，见 §3。

---

## 3. 为什么不会撞 / 边界风险核对

### 3.1 三个主口的 4 位 ID 分布（修改后）

| 端口 | 主口 | 顶层取的低 4 位 | 依据 |
|---|---|---|---|
| s0 | frame_buffer | **0xC**（读）/ **0xD**（写） | 本次修改，`ddr_rd_buffer.v:227` / `ddr_wr_buffer.v:494`，经 `mmt_top.v:768/795` 取低 4 位 |
| s1 | Sapphire SoC | **不可控**（加密网表内部产生） | `docs\AXI互联仿真结论.md` §3.4 / §6.3 |
| s2 | TinyML（channels 包装） | **实质为 0** | `ip\tinyml\tinyml_accelerator_channels.v:203/223` 声明后无驱动无使用；`ip\tinyml\axi_interconnect_beta.sv:79/99` 只有 ID 输出、**没有 ID 输入**（端口表明文可读）→ 单通道下只能为 0 |

**已确认的冲突（task-6 的目标）**：修改前 s0=0、s2=0，**每一笔并发事务同 ID**。修改后 s0 = 0xC/0xD ≠ 0 = s2 ⇒ **冲突消除**。

**关键点**：这个修复**不依赖**厂商 IP 的响应路由策略。
- 若 IP 是 **BY_PORT**（按端口记账）→ 本来就安全，修改后依然安全（只改了标签值）。
- 若 IP 是 **BY_ID**（按 ID 记账）→ 修改前 7/16 用例失败、s0 死等；修改后 s0 与 s2 不再共享 ID 表项，错误配对不再发生。

### 3.2 为什么选 0xC / 0xD 而不是任务书建议的 0xA / 0xB（以及不是 0x1）

| 候选项 | 问题 |
|---|---|
| `6'h01`（上游文档 §7 P1 的建议） | 0x1 是 CPU AXI 主口顺序分配 ID 时**最先用到**的值之一，与不可控的 SoC 撞车概率最高 |
| `6'h2A` / `6'h2B`（本任务书建议，低 4 位 = 0xA/0xB） | 功能上可用，但 **0xA 会撞上现有仿真常量**：`sim\axi_ic\tb_axi_ic.v:56` 的 `localparam [7:0] ID2 = 8'h0A;`（TinyML 的测试 ID）。若 Lead 按修复后的 RTL 去更新仿真（只改 `ID0`）而忘记改 `ID2`，TC2/TC4 会**静默变成碰撞用例**，产生难以解释的 FAIL |
| **`6'h0C` / `6'h0D`（本次采用）** | ① 低 4 位非 0，与 TinyML 的 0 互斥；② 位于 4 位空间**高半区**，比 0x1/0x2 更不容易与 SoC 顺序分配的 ID 相撞；③ 与现有仿真已用常量 0x0/0x5/0xA **全不冲突**，仿真模型更新时不会引入额外变量；④ 都 ≤ 0xF |

### 3.3 核对"ID 超过 0xF 会被零扩展后认不回自己"这一边界风险

上游结论（`docs\AXI互联仿真结论.md` §5.5a、§6）指出：顶层只取低 4 位、回程零扩展，所以**任何 >0xF 的 ID 送出去就回不来**，主口会认不出自己的响应（实测：SoC 发 `0xA5` → 回程变 `0x05`）。

本次选择的值**规避了这条风险**：

- `6'h0C` 与 `6'h0D` 的**native 6 位值本身 ≤ 0xF**，所以
  `0x0C` --截断--> `0xC` --零扩展--> `0x0C`（**恒等**，信息零损失）。
- 对比任务书建议的 `6'h2A`：截断后 `0xA`，零扩展回来是 `0x0A ≠ 0x2A`。今天无害（因为 `rid` 是死输入，§1.2），但会留下一个**潜在陷阱**——将来谁给 frame_buffer 加上 ID 校验，就会立刻踩雷。用 `6'h0C/6'h0D` 直接把这个坑填掉了。
- **残留**：这条截断风险对 **SoC（8 位 ID）** 依然存在且未被本任务解决（SoC 内部 ID 分配不可见）。见 §6。

---

## 4. 验证记录（实测，含命令与退出码）

### 4.1 静态唯一性核对

```
Select-String -Path ddr_rd_buffer.v -Pattern "6'h00"   → 仅 1 处（227 行）
Select-String -Path ddr_wr_buffer.v -Pattern "8'd0;"   → 仅 1 处（494 行）
grep -i -E '\w*(awid|arid|bid|rid)\w*'                 → rd 4 处 / wr 3 处（见 §1.1）
```
改完后两个文件里 `arid`/`awid` **各只有一条 `assign`**，不存在多驱动。

### 4.2 iverilog 常量探针（实测，退出码 0）

**第一层：对真实文件直接编译**，确认改动行没有引入语法错误：

```
D:\iverilog\Library\bin\iverilog.exe -g2012 -t null -o NUL ^
    rtl\frame_buffer\ddr_rd_buffer.v rtl\frame_buffer\ddr_wr_buffer.v DC_FIFO.v ...
```
结果：退出码 4，**4 个 error 全部在 194 行与 262 行**（`ddr_arlen+1` / `ddr_awlen+1` 参与拼接时宽度不确定，`ddr_rd_buffer.v:194`、`ddr_wr_buffer.v:262`）。这是 iverilog 对既有写法的严格性限制，**与 227/494 两行无关**，且改动前就存在（同一文件同一行，未触碰）。

**第二层：临时副本 + DC_FIFO stub 做行为探针**（证明新常量的实际取值）：
把两个文件复制到 `%TEMP%`，仅对上面那处**无关的**拼接写法补上显式宽度（`(ddr_arlen+1)` → `({1'b0,ddr_arlen}+9'd1)`），再配一个 `DC_FIFO` 空壳，然后：

```verilog
module tb_id_probe;
  wire [5:0] arid, awid;
  ddr_rd_buffer u_rd (.arid(arid));
  ddr_wr_buffer u_wr (.awid(awid));
  initial begin #1;
    $display("PROBE arid=%h awid=%h", arid, awid);
    if (arid===6'h0C && awid===6'h0D) $display("ID PROBE: PASS"); else $display("ID PROBE: FAIL");
    $finish; end
endmodule
```

实测输出：
```
[compile exit code = 0]
PROBE arid=0c (expect c)  awid=0d (expect d)
ID PROBE: PASS
[vvp exit code = 0]
```

> 诚实说明：探针跑的是**临时副本**，与工程文件唯一差别是那处 iverilog 兼容性改写（第 194/262 行）加一个 DC_FIFO 空壳；`arid`/`awid` 的常量值直接来自被修改的真实行。工程原文件未做任何兼容性改写。

### 4.3 本任务**没有**做的事（明确边界）

- **未跑 Efinity 流程**：没有执行 `efx_map` / `efx_pnr` / `build.ps1` / `run_full_flow.ps1`（Lead 独占）。综合/时序/资源是否回归由 Lead 验证。
- **未跑 `sim\axi_ic\run_axi_ic.ps1`**：该脚本的 testbench 把 frame_buffer 的 ID 写死为 0（见 §5.1），在未同步更新前跑它不能验证本次修复。且 `sim\` 不在本任务写权限内。
- **未验证真 IP 的响应路由策略**：仍是 `docs\AXI互联仿真结论.md` §6 的未证实项（缺可解密 pragma protect 的仿真器）。

---

## 5. Lead 待办（本次修复的配套动作）

### 5.1 【必须】同步更新 AXI 互联仿真模型，否则仿真与 RTL 不一致

`sim\axi_ic\tb_axi_ic.v` 里 frame_buffer 的 ID 是**照旧 RTL 写死的 0**，现在已过时：

```
 11: //      s0 = frame_buffer   native ID 6 bits, hardwired 0
 12: //                          (frame_buffer/ddr_rd_buffer.v:227 arid = 6'h00,
 13: //                           frame_buffer/ddr_wr_buffer.v:494 awid = 8'd0)
 54: localparam [5:0]  ID0 = 6'h00;     // frame_buffer: hardwired 0
 56: localparam [7:0]  ID2 = 8'h0A;     // TinyML, fits in 4 bits
```

建议改法（`sim\` 是 Lead 的写权限，本任务未触碰）：
- 第 11–13 行注释与第 54 行：`ID0` → `6'h0C`；**读/写用例分开送值**（`tb_axi_ic.v:513/515/664` 等读调用传 `6'h0C`，写调用传 `6'h0D`）——`issue_p(port, is_write, addr, id, data)` 是**每次调用传 ID**，不需要改 BFM。
- 第 56 行：`ID2` 由 `8'h0A` 改为 **`8'h00`** —— 这才忠实于真实情况（`ip\tinyml\axi_interconnect_beta.sv` 没有 ID 输入，TinyML 的 ID 只能是 0）。**不改这一行就会出现"0xC 撞 0xA"之外的假象**。
- TC3b/TC3c（`tb_axi_ic.v:583/602` 显式写 `m_id0=6'h00; m_id2=8'h00`）**保持不变**——它们本来就是在测"万一 ID 撞了会怎样"，是有价值的负向用例。
- 预期：更新后 `run_axi_ic.ps1` 三种配置的结论应与 task-2 一致（baseline PASS=16/FAIL=0、idhazard FAIL、revprio PASS）；若不一致，说明模型另有问题，需重新检查。

### 5.2 【必须】重跑 Efinity 流程

```
efx_map  → 期望 exit 0
efx_pnr  → 期望 exit 0
```
本次只把两个常量从 `0` 改成 `0xC/0xD`，**不动任何逻辑/位宽**，预期资源（XLR / BRAM 222 / DSP 27）与时序（setup 无负 slack）**零变化**。若出现任何资源或时序差异，说明改动未按预期生效，需回查。

### 5.3 【建议】上板/波形抽查

在互联下游 `m_axi_arid` / `m_axi_awid` 上抓一次 frame_buffer 的读写：
- 读事务应带 `arid = 4'hC`；
- 写事务应带 `awid = 4'hD`；
- 且 frame_buffer 的视频流不出现卡顿（若真 IP 是 BY_ID，修复前应表现为周期性死等；修复后应消失）。

### 5.4 【可选，收益最大】把"未知"变"已知"

若 Lead 手上有 QuestaSim / Riviera-PRO / NCSim / VCS：按 `docs\AXI互联仿真结论.md` §7 P0 的方法，把 `sim\axi_ic\dut_axi_ic.v` 里的模型例化换成真 IP `axi_interconnect`，即可一次性确认**仲裁顺序**与**响应路由策略**。这决定了 §6 的 SoC 残余风险要不要进一步处理。

---

## 6. 残余风险与未证实项

1. **Sapphire SoC 的 4 位 ID 不可控（未证实，最高优先级残留）**
   SoC 是加密网表，其 DDR AXI 主口用的 ID 值读不到。若它也用 0xC 或 0xD，则 s0 与 s1 仍会撞。
   - 缓解：本次选了 4 位空间的**高半区**（0xC/0xD），比 0x1/0x2 更不容易与顺序分配的小 ID 相撞；但这只是**降低概率，不是消除**。
   - 彻底修法（**超出本任务写权限**，需 Lead 决策）：在互联前端给 SoC 的 `soc_ddr_awid/arid[3:0]` 加一级 ID 重映射（例如强制平移到 0x0 或拼一个专属前缀），或换成按端口记账的明文互联。位置在 `rtl\mmt\mmt_top.v:768/795` 附近。**前提**是先按 §5.4 证实 IP 确实是 BY_ID，否则是过度设计。
2. **TinyML 的 `m_axi_awid/arid` 恒为 0 属于强推断**，未 100% 断言（`axi_interconnect_beta.sv` 本体加密，只有端口表明文）。即便它非 0，只要不等于 0xC/0xD，本次修复依然成立。
3. **真 IP 在地址窗口外（≥0x1000_0000）的行为**未证实——与本任务无关，见 `docs\AXI互联仿真结论.md` §3.2/§5.5b。
4. **PRIORITY 模式下的饿死风险**未复现——与本任务无关。

---

## 7. 文件改动汇总（本任务）

| 文件 | 操作 | 说明 |
|---|---|---|
| `rtl\frame_buffer\ddr_rd_buffer.v` | **改 1 行**（227） | `6'h00` → `6'h0C` |
| `rtl\frame_buffer\ddr_wr_buffer.v` | **改 1 行**（494） | `8'd0` → `6'h0D` |
| `docs\AXI主口ID互斥修复.md` | **新建** | 本文档 |

**未触碰**：其它 `rtl\` 文件、`ip\`、`mmt.xml`、`constr\`、`sw\`、`sim\`（含 `sim\axi_ic\*`）、以及上游的 `docs\AXI互联仿真结论.md`。
**未执行**：任何 Efinity 流程（`efx_map` / `efx_pnr` / `build.ps1` / `run_full_flow.ps1`）。
**工程非 git 仓库**（`D:\FPGA\mmt\.git` 不存在），改动仅落盘，无提交动作。
