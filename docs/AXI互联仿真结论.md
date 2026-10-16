# AXI 互联仿真结论（三主口 → DDR3 从口）

- 工程：`D:\FPGA\mmt`（Efinix Efinity 2026.1.132，Ti60F225I3，顶层 `mmt_top`）
- 任务：task-2 —— 验证 ① 三主口并发时的实际仲裁顺序；② frame_buffer 与 TinyML 低 4 位 ID 都为 0 时，响应会不会被错配到别的主口
- 日期：2026-10-11
- 仿真目录：`D:\FPGA\mmt\sim\axi_ic\`

---

## 0. 结论先行（TL;DR）

| 问题 | 结论 | 证据等级 |
|---|---|---|
| 能否用 iverilog 直接仿真厂商 IP？ | **不能**。`ip/axi_interconnect/axi_interconnect.v` 是 `pragma protect` 加密的，iverilog 在 251 行直接语法错误退出（exit 2）。本机未找到任何支持 pragma protect 解密的三方仿真器 | **实测** |
| 厂商 IP 的仲裁顺序是什么？ | **未证实**。ARB_MODE 确定为 `PRIORITY`（实测配置），但 PRIORITY 模式下"哪个端口优先"官方文档没有写，加密源码读不到，本机也没有能解密它的仿真器 | 静态证据 + **未证实** |
| 三主口并发时"优先级仲裁"的行为 | 用行为级模型实测：`ARB_ORDER=0` 时顺序为 **s0 → s1 → s2**；`ARB_ORDER=1` 时为 **s2 → s1 → s0**。说明本测试用例能区分优先级顺序，但**不能证明厂商 IP 用的是哪一种** | **模型替代** |
| 三个主口的低 4 位 ID 会冲突吗？ | **一定会冲突，而且是硬连线冲突**：frame_buffer 的 AWID/ARID 被硬接成 0；TinyML 侧根本没有 ID 源，其 8 位 m_axi_awid/arid 只能由 IP 内部产生（单通道下几乎必然为 0）。所以 s0 与 s2 **每一笔并发事务都同 ID** | **静态实测（文件:行）** |
| ID 冲突会不会导致响应错配？ | **取决于厂商 IP 的响应路由策略，本轮未能证实**。用行为级模型把两种策略都跑了一遍：按端口记账（BY_PORT）→ 16/16 全通过；按 ID 记账（BY_ID）→ 立即复现错配：s0 的响应被送到 s2、s0 超时死等。这说明**测试用例是灵敏的**，但**厂商 IP 属于哪一种仍未知** | **模型替代 + 敏感性已证** |
| 附带发现 1 | 顶层把 ID 从 6/8 位截成低 4 位、回程再零扩展（`mmt_top.v:747-750,768,795`）。因此**任何主口只要发出 >0xF 的 ID，收到响应时就无法与自己发出的 ID 匹配** | **模型实测** |
| 附带发现 2 | 互联下游地址窗口只有 **1 个**：base `0x0000_0000`、宽 28 位 = **256 MB**（`axi_interconnect.vh:1-2`）。超出 `0x0FFF_FFFF` 的访问会命中地址解码失败 | 静态证据 + 模型实测 |

**给 Lead 的一句话**：ID 冲突是**确定存在的**（不是"可能"），但"是否真的错配"卡在加密 IP 上，本轮无法给出确定答案；必须先在一个能解密 pragma protect 的仿真器（QuestaSim / Riviera / NCSim / VCS）里把本目录的 testbench 指向真 IP 跑一次才能定论。建议同时按 P1 做防御性修改（见第 7 节）。

---

## 1. 证据分级说明（重要）

本文所有结论都标注了等级，请勿混用：

- **实测**：本机真实执行过命令，退出码与输出可复现。
- **静态证据**：直接读取工程/厂商文件并给出 `文件:行`，非推断。
- **模型替代**：用一个行为级模型复现互联的**关键语义**后实测。**它不代表厂商 IP 的行为**，只代表"如果 IP 是这样实现的，会发生什么"，以及证明测试用例能分辨这些情形。
- **未证实**：无法确认，明确写出卡在哪里。

---

## 2. 为什么不能直接仿真（实测，含命令与退出码）

### 2.1 现象

```
D:\iverilog\Library\bin\iverilog.exe -g2012 -o probe.vvp ^
    D:\FPGA\mmt\ip\axi_interconnect\axi_interconnect.v
```
输出：
```
D:\FPGA\mmt\ip\axi_interconnect\axi_interconnect.v:251: syntax error
I give up.
D:\FPGA\mmt\ip\axi_interconnect\axi_interconnect.v:577: Include file axi_interconnect.vh not found
[exit code: 2]
```

第 251 行正是：

```
249: /* Encryption Envelope */
251: `pragma protect begin_protected
252: `pragma protect version = 1
253: `pragma protect encrypt_agent = "QuestaSim" , encrypt_agent_info = "2023.4"
254: `pragma protect key_keyowner = "Efinix Inc." , key_keyname = "EFX_K01"
255: `pragma protect key_method = "rsa"
264: `pragma protect data_method = "aes256-cbc"
266: `pragma protect data_block
```

iverilog 不支持 `pragma protect`，把加密块当普通 Verilog 解析 → 语法错误。**没有绕过办法**：RSA 密钥块（`EFX_K01`）只能由持有 Efinix 授权密钥的仿真器解开。

### 2.2 厂商提供的 5 个"变体"全部是加密的（逐个查过）

`D:\Efinity\2026.1\ipm\ip\efx_axi_interconnect\` 下按目标仿真器分了目录，**没有任何一个是明文**：

| 目录 | 加密方式 | 主文件行号 |
|---|---|---|
| `source_efinity/` | `pragma protect begin_protected` + data_block | `efx_axi_interconnect.v:120-140` |
| `source_aldec/` | 同上（Aldec 密钥） | 同上 |
| `source_ncsim/` | 同上 | 同上 |
| `source_synopsys/` | 同上 | 同上 |
| `source_modelsim/` | `` `protected ... `endprotected ``（IEEE 1735-2014 风格） | `efx_axi_arbiter.v:3-43` |

工程里实际用的 `ip/axi_interconnect/axi_interconnect.v` 就是这些的同族加密版本。

**唯一可读的是外层包装模块**（`axi_interconnect.v:49-244`）——它只是把端口原样透传给加密的 `efx_axi_interconnect_df80af4417c44bd79d843abf5befe014`，不含任何逻辑。这一点很有价值（见第 3.3 节）。

### 2.3 本机没有任何能解密它的仿真器（已搜索）

用 `Get-Command` 在 PATH 上找过 `vsim / vlog / vlib / riviera / xrun / ncsim / vcs / modelsim / questa`，并检查了常见安装目录（`C:\questasim*`、`C:\modeltech*`、`C:\intelFPGA*`、`C:\aldec*`、`D:\questasim*`、`D:\modeltech*`、`D:\aldec*`）——**均未找到**。`D:\Efinity\2026.1\` 下只有 `sim_models`（原语仿真库），不带仿真器；Efinity 的 Simulation 流程本身也要求外挂三方仿真器。

> 限制说明：这是"按上述方式未找到"，不等于"全世界都不存在"。若 Lead 手上有 QuestaSim/ModelSim 或 Riviera，第 8 节给出直接用本 testbench 打真 IP 的方法。

### 2.4 也排除了两条替代路径

- **post-synthesis 网表**：`D:\FPGA\mmt\out\mmt.netlist`（3.36 MB）是**二进制**格式（magic `EFX.NETLIST!`），且层次名被抹掉——全文搜索 `u_ddr_axi_ic` 命中 **0** 次，无法从中还原互联结构。
- **第三方明文实现能否代表 Efinix**：`D:\FPGA\易灵思\工作区\03_EVSoC源码\evsoc-main\...\source\axi\axi_interconnect.v` 是 **Alex Forencich 的 MIT 明文互联**（`axi_interconnect.v:1-21` 版权头），**不是** Efinix IP，不能当作厂商行为的证据。官方 TinyML 工程里的 `axi_interconnect_beta.sv`（34567 字节）同样是加密的。

---

## 3. 从明文部分能确定的硬事实（静态证据）

### 3.1 参数

| 参数 | 值 | 出处 |
|---|---|---|
| `ARB_MODE` | `"PRIORITY"` | `ip/axi_interconnect/settings.json:16`、`axi_interconnect_define.vh:46`、`axi_interconnect.v:143` |
| `S_PORTS` / `M_PORTS` | 3 / 1 | `axi_interconnect_define.vh:47,50` |
| `DATA_WIDTH` / `ADDR_WIDTH` | 128 / 32 | `axi_interconnect_define.vh:48,49` |
| `ID_WIDTH` | 4 | `axi_interconnect_define.vh:51` |
| `PROTOCOL` | `"AXI4"` | `axi_interconnect_define.vh:53` |

官方 `axi-interconnect-core-params.html` 说明 `ARB_MODE` 有 `PRIORITY / ROUND_ROBIN_1 / ROUND_ROBIN_2` 三种，默认 PRIORITY，但**没有写 PRIORITY 下哪个端口优先**。`axi-interconnect-fd.html` 只说明内部由 Arbiter + Skid Buffer + Address decoder 三块组成，**完全没有提 ID 如何参与响应路由**。→ **仲裁顺序与 ID 路由这两点，文档也答不了。**

### 3.2 下游地址窗口只有 256 MB

`ip/axi_interconnect/axi_interconnect.vh:1-2`：
```verilog
localparam M_BASE_ADDR  = {32'h41000000,32'h40000000,32'h30000000,32'h20000000,32'h11100000,32'h11000000,32'h10000000,32'h0};
localparam M_ADDR_WIDTH = {32'd20,32'd24,32'd28,32'd28,32'd20,32'd12,32'd24,32'd28};
```
`M_PORTS=1`，生效的是最后一个元素：**base `0x0000_0000`、宽 28 位 → 覆盖 `0x0000_0000`–`0x0FFF_FFFF`（256 MB）**。其余 7 项是 M_PORTS=1 时用不到的生成器默认值。

**含义**：任何 ≥ `0x1000_0000` 的访问都落在窗口外。当前帧缓存 `0x0200_0000`–`0x02BD_DDFF` 在窗口内没问题；但如果后续 TinyML 张量/模型放到 `0x1000_0000` 以上就会踩到解码失败。这一条与 task-3 的 DDR 内存图规划直接相关，**建议 Lead 交叉核对**。

### 3.3 顶层把 ID 截断，且**没有把端口号拼进 ID**

`ip/axi_interconnect/axi_interconnect.v`（明文包装，51-140 行）：
```
112:    input  [11:0] s_axi_awid,      // = S_PORTS(3) × ID_WIDTH(4) = 12 位
116:    output [3:0]  m_axi_awid,      // = M_PORTS(1) × ID_WIDTH(4)  =  4 位
```
下游 ID 宽度 **等于** 上游单口 ID 宽度，**没有加宽**——也就是说互联**没有**把端口号追加到 ID 上（Xilinx 那类做法会加宽 ID）。所以"下游 ID 能唯一标识端口"这件事，在这个配置里**不成立**，除非互联自己是按端口/请求记账的。

顶层截断与回程零扩展（`rtl/mm/mmt_top.v`）：
```verilog
 768:    .s_axi_awid  ({tml_awid[3:0],  soc_ddr_awid[3:0], fb_awid[3:0]}),
 795:    .s_axi_arid  ({tml_arid[3:0],  soc_ddr_arid[3:0], fb_arid[3:0]}),
 747:    assign fb_bid      = {2'b00, ic_bid_p0};   // 6 位
 748:    assign soc_ddr_bid = {4'h0,  ic_bid_p1};   // 8 位
 749:    assign fb_rid      = {2'b00, ic_rid_p0};
 750:    assign soc_ddr_rid = {4'h0,  ic_rid_p1};
 751:    // ic_bid_p2 / ic_rid_p2：TinyML 侧没有 ID 消费者，留着不接
```

### 3.4 三个主口实际发出的 ID（关键）

| 端口 | 主口 | ID 位宽 | **实际值** | 证据 |
|---|---|---|---|---|
| s0 | frame_buffer | 6 位 | **硬连线 0** | `rtl/mm/frame_buffer/ddr_rd_buffer.v:227` → `assign arid = 6'h00;`<br>`rtl/mm/frame_buffer/ddr_wr_buffer.v:494` → `assign awid = 8'd0;` |
| s1 | Sapphire SoC | 8 位 | 由 SoC 内部产生，**顶层不可控** | `rtl/mm/mmt_top.v:768/795` 接 `soc_ddr_awid/arid`；SoC 是加密 IP 网表 |
| s2 | TinyML（channels 包装） | 8 位 | **实质上必然是 0** | 见下 |

TinyML 侧的证据链：

1. `ip/tinyml/tinyml_accelerator_channels.v` 的例化（363-432 行）**根本没有连 `.s_axi_awid/.s_axi_arid`**；
2. 该文件 203/223 行声明了 `wire [NUMBER_OF_CHANNELS*8-1:0] s_axi_tinyml_awid/arid;`，但**全文再无引用（无驱动、无使用）**；
3. 被例化的 `ip/tinyml/axi_interconnect_beta.sv` 的端口里**没有任何 `s_axi_*id` 输入**（只有 `output wire [7:0] m_axi_awid` 在第 79 行、`m_axi_arid` 在第 99 行）。

→ 既然连 ID 输入都不存在，`m_axi_awid/arid` 只能由该 IP 内部生成；在 `NUMBER_OF_CHANNELS=1` 时它没有别的信息来源，**几乎必然是常数 0**。（`axi_interconnect_beta.sv` 本体加密，无法 100% 断言，但端口表是明文。）

**结论：s0（frame_buffer）与 s2（TinyML）的低 4 位 ID 都是 0，这是硬连线导致的必然冲突，不是"可能冲突"。**

---

## 4. 仿真做了什么（模型替代，明确区分）

因为真 IP 不可仿真，本目录交付的是一套**接口完全对齐真 IP 的 testbench + 行为级模型**：

| 文件 | 作用 |
|---|---|
| `sim/axi_ic/axi_master_bfm.v` | 行为级 AXI4 主口模型，**复刻顶层的 ID 处理**：主口原生 6/8 位 ID，出线截成 4 位，回程零扩展后再比对 |
| `sim/axi_ic/axi4_slave_model.v` | 行为级 AXI4 从口（DDR3 控制器替身）：可配延迟、多笔 outstanding、按 ID 回 B/R、背后是真实 CAM 存储器（按 32 位全地址索引，**响应送错主口时数据比对必然失败**） |
| `sim/axi_ic/axi_ic_semantic_model.v` | 3→1 互联模型，复刻官方文档描述的结构（Arbiter + Address decoder + Skid-buffer 数据通路）与本节参数；两个未知项做成参数（见下） |
| `sim/axi_ic/dut_axi_ic.v` | **适配插座**：端口表逐字照抄真 IP 的明文包装（`ip/axi_interconnect/axi_interconnect.v:49-140`） |
| `sim/axi_ic/tb_axi_ic.v` | 测试用例 + 计分板；**通过在 `s_axi_*valid/ready` 上做握手监测来测仲裁顺序**，因此这个监测逻辑对真 IP 同样有效 |
| `sim/axi_ic/run_axi_ic.ps1` | 一条命令跑完 3 种配置 |

模型把两个未知项参数化：
- `ARB_ORDER`：`0` = s0 最高优先；`1` = s2 最高优先
- `ROUTE_POLICY`：`0` = **BY_PORT**（响应跟随排队时记录的端口，安全）；`1` = **BY_ID**（响应查 `id_owner[ID]` 表，该表被每次 grant 覆写 → 经典 ID 表危害）

模型保留了每方向深度 4 的 outstanding 队列，**这样两笔同 ID 事务才可能同时在飞**——这是 ID 表危害能暴露出来的前提条件。

---

## 5. 实测结果

### 5.1 运行命令与退出码（实测）

```
cd D:\FPGA\mmt
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\axi_ic\run_axi_ic.ps1
```
```
[CONFIG RESULT: PASS]  (vvp exit=0)  expected=PASS  log=...\axi_ic_baseline.log
[CONFIG RESULT: FAIL]  (vvp exit=1)  expected=FAIL  log=...\axi_ic_idhazard.log
[CONFIG RESULT: PASS]  (vvp exit=0)  expected=PASS  log=...\axi_ic_revprio.log
=== AXI_IC REGRESSION: ALL CONFIGURATIONS AS EXPECTED ===
[script exit code = 0]
```

单配置手工编译命令（与脚本内一致）：
```
D:\iverilog\Library\bin\iverilog.exe -g2012 -s tb_axi_ic ^
  -o sim\axi_ic\_run\axi_ic_baseline.vvp -DARB_ORDER_VAL=0 -DROUTE_POLICY_VAL=0 ^
  sim\axi_ic\axi_master_bfm.v sim\axi_ic\axi4_slave_model.v ^
  sim\axi_ic\axi_ic_semantic_model.v sim\axi_ic\dut_axi_ic.v sim\axi_ic\tb_axi_ic.v
D:\iverilog\Library\bin\vvp.exe sim\axi_ic\_run\axi_ic_baseline.vvp
```
> 注意：必须带 `-s tb_axi_ic`。不带时 iverilog 会自动挑根模块，会挑错、仿真 0 输出但退出码为 0（本轮踩过这个坑，已固定）。

### 5.2 用例清单与通过计数

| 用例 | 内容 |
|---|---|
| TC1a–f | 单主口读/写正确性（s0/s1/s2 各一遍，共 6 项） |
| TC2a/b | 三主口**同时**发起读/写，采集 `m_axi` 侧实际事务顺序 |
| TC3a | ID 冲突场景的准备（用不冲突的 ID 预写数据） |
| **TC3b** | **s0 与 s2 原生 ID 都=0，并发读** —— 最关键的一条 |
| **TC3c** | **s0 与 s2 原生 ID 都=0，并发写** |
| TC4a | 三主口混合读写（读写通道交叉）的正确性 |
| TC5a/b | 窗口外地址访问（`0x1000_0000`）行为 |
| TC6a/b | ID 截断保真度（`0x05` 可往返 / `0xA5` 有损） |
| TC7a | PRIORITY 下的公平性探测（s0 连续背靠背读） |

| 配置 | 结果 |
|---|---|
| `baseline`（ARB_ORDER=0, BY_PORT） | **PASS=16  FAIL=0  NOTE=2** |
| `idhazard`（ARB_ORDER=0, **BY_ID**） | **PASS=9  FAIL=7  NOTE=2** |
| `revprio`（ARB_ORDER=1, BY_PORT） | **PASS=16  FAIL=0  NOTE=2** |

### 5.3 仲裁顺序（模型实测）

握手监测发生在 `s_axi_arvalid/arready` 与 `s_axi_awvalid/awready` 上，逐拍记录 grant 顺序：

```
[ARB_ORDER=0]  [ARB] TC2-read  AR: s0 s1 s2      [ARB] TC2-write  AW: s0 s1 s2
[ARB_ORDER=1]  [ARB] TC2-read  AR: s2 s1 s0      [ARB] TC2-write  AW: s2 s1 s0
```
读通道与写通道的仲裁顺序一致；改一个参数就翻转 → **TC2 对仲裁顺序是灵敏的**。

TC7（s0 连续背靠背读 6 次 + s1/s2 各 1 次）实测顺序：
```
[ARB_ORDER=0] [ARB] TC7-s0hog AR: s0 s1 s2 s0 s0 s0 s0 s0
[ARB_ORDER=1] [ARB] TC7-s0hog AR: s2 s1 s0 s0 s0 s0 s0 s0
```
**这条要如实说明**：单 outstanding 的 BFM 在每笔完成到重新发起之间有间隔，s1/s2 恰好在这个空隙里被服务了，所以**本次激励没有复现"饿死"**。它只证明"hog 有间隙时低优先级口仍能被服务"，**不能**用来否定 PRIORITY 模式无公平性保证这一架构事实。要做严格的饿死测试需要一个能连续不断断言的 BFM。

### 5.4 ID 冲突场景的实测（最关键的证据）

**BY_ID 配置下，TC3b（并发读，s0 与 s2 原生 ID 都是 0）** —— `_run\axi_ic_idhazard.log`：

```
[IC] 1875 ns  R ROUTE  m_rid=0x0 policy=1 -> s2 (queued port s0)
[IC] 1935 ns  R ROUTE  m_rid=0x0 policy=1 -> s2 (queued port s2)
```
读法：`queued port s0` 表示这笔响应**本来属于 s0**，但因为策略是 BY_ID、`id_owner_r[0]` 已被后到的 s2 覆写成 2，于是被送到了 **s2**。下一笔（本来属于 s2）也送到 s2。

**BY_ID 配置下，TC3c（并发写，同 ID）**：

```
[IC]  13965 ns  B ROUTE  m_bid=0x0 policy=1 -> s2 (queued port s0)
[SLAVE] 14005 ns  B  DRIVE  bid=0x0
[BFM0] 25905 ns  *** TIMEOUT in state 3 (addr=0x00002000) -- no response ***
```
s0 的写响应被送到 s2 → **s0 一直等不到 B，超时死等**；同时 s2 收到了一笔不属于它的握手（BFM2 报 `DONE`）。

**同一批用例在 BY_PORT 配置下全部通过**（`axi_ic_baseline.log`，PASS=16 FAIL=0），说明模型本身没问题，差别纯粹来自响应路由策略。

**结论**：
- 如果真实 efx_axi_interconnect 是**按端口记账**的 → s0/s2 同 ID 无害，ID 冲突只是"不好看"；
- 如果是**按 ID 记账**的（ND 表现就是上面这样）→ **每一笔 s0 与 s2 的并发事务都会错配**，后果是其中一个主口永久挂死 + 另一个主口收到脏数据。
- **本轮无法判定真 IP 属于哪一种**。但有一个可用的推理：下游 ID 宽度与上游单口宽度相同（4 位、无端口号拼接，§3.3）——在这种配置下，一个"只靠 ID 识别端口"的实现本身就是不成立的，因此**按端口记账是更可能的实现**。这属于**推断**，不能替代实测。

> 诚实性提醒：`idhazard` 配置里 TC4/TC5/TC6/TC7 也报了 FAIL，但那是**第一次错配之后读通道被卡死产生的连带后果**（模型忠实保留了"响应发不出去就一直占着通道"这一行为），**不是 7 个独立发现**。真正独立的是 TC3b 与 TC3c。

### 5.5 附带发现（实测）

**(a) ID 截断是有损的。** `_run\axi_ic_baseline.log`：
```
[BFM1] 2765 ns  ID TRUNCATION LOSS on R: native id 0xa5 -> 4-bit 0x5 -> zero-ext 0x5
[BFM1] 2775 ns  DONE  errcode=0x20 resp_id=0x5
```
主口（SoC）发出 ID `0xA5`，回程因为 `mmt_top.v:750` 的零扩展变成 `0x05` → **主口认不出自己的响应**。当前三个主口用到的 ID（0/5/0xA）都 ≤ 0xF 所以暂时没问题，但**一旦 SoC 用了 >0xF 的 ID（例如用它自己的多 outstanding 计数），SoC 会挂死**。SoC 的 ID 分配在加密网表里，**本轮无法确认**，建议列为一个待验证项。

**(b) 地址窗口 256 MB。** `_run\axi_ic_baseline.log`：
```
[NOTE] TC5b_model_flags_decode_err_ar=1 for 0x10000000 (outside 0x0/2^28)
```
对 `0x1000_0000` 的访问被模型标记为地址解码失败（这与 `axi_interconnect.vh` 的窗口一致）。真 IP 在窗口外是走默认从口还是返回 DECERR，**未证实**。

---

## 6. 未被证实、不能下结论的项（明确列出）

1. **真 IP 在 PRIORITY 模式下的端口优先级顺序** —— 未知。
2. **真 IP 的响应路由是按端口还是按 ID** —— 未知，这是全项目最大的功能未知项。
3. **Sapphire SoC 在 DDR AXI 主口上实际使用的 ID 取值范围**（是否 ≤ 0xF）—— 未知，SoC 是加密网表。
4. **TinyML 的 `m_axi_awid/arid` 是否恒为 0** —— 端口表证明"没有 ID 输入"，常数 0 是强推断，但 `axi_interconnect_beta.sv` 加密，未能 100% 断言。
5. **真 IP 在地址窗口外的行为**（透传 / DECERR）—— 未知。
6. **PRIORITY 模式下的饿死风险** —— 架构上无公平性保证，但本轮激励未复现。

---

## 7. 建议修法（按优先级）

### P0 — 先把"未知"变成"已知"（成本最低、收益最大）

本 testbench **接口与真 IP 完全一致**，把 `sim/axi_ic/dut_axi_ic.v` 里的这一行：

```verilog
axi_ic_semantic_model #(.ARB_ORDER(ARB_ORDER), .ROUTE_POLICY(ROUTE_POLICY), .VERBOSE(VERBOSE)) u_model (
```
换成（其余端口名逐一对得上，不用改）：
```verilog
axi_interconnect u_model (        // 真 IP 明文包装模块
```
然后在**任意一台装了 QuestaSim / ModelSim / Riviera-PRO / NCSim / VCS 的机器**上编译运行（`sim/axi_ic/_run/*.vvp` 换成 `vsim` 工作库即可，源码集不变）。观察两件事：
- `[ARB] TC2-read AR:` 打印的顺序 → 得到**真仲裁顺序**；
- TC3b / TC3c 是 PASS 还是 FAIL → 得到**真路由策略**。

这一步做完，第 6 节里的第 1、2 条就都有答案了。

### P1 — 防御性修改（不管 P0 结果如何，都建议做）

既然 s0（frame_buffer）与 s2（TinyML）**硬连线同 ID=0**，最省事的确定性修法是**让 4 位 ID 在三个主口之间互斥**：

- `rtl/mm/frame_buffer/ddr_rd_buffer.v:227`：`assign arid = 6'h00;` → 改成一个**非 0 的固定值**，例如 `6'h01`；
- `rtl/mm/frame_buffer/ddr_wr_buffer.v:494`：`assign awid = 8'd0;` → 同样改成 `8'h01`。

改完后 s0 用 `0x1`、s2 用 `0x0`、s1（SoC）用它的内部值 → **只要 SoC 不发 0x1，三者就互不冲突**，BY_ID 与 BY_PORT 两种实现都安全。
副作用检查（已验证过逻辑）：回程 `mmt_top.v:747/749` 是零扩展，`0x1` 能正确往返 6 位，frame_buffer 侧无需改动别的。（注意：RTL 修改属于 Lead 的写权限范围，本任务只给建议，未改动任何 `rtl/` 文件。）

**残留风险**：SoC 的 ID 值不可控（第 6 节第 3 条）。若 P0 证实真 IP 是 BY_ID，还需要在顶层给 SoC 的 `awid/arid` 加一级"ID 平移/隔离"垫片，或直接换成按端口记账的实现。

### P2 — 若 P0 证实是 BY_ID（按 ID 记账）

那就不能只靠"改常数"兜底（SoC 不可控），建议二选一：
1. 用**明文、按端口记账**的 N→1 互联替换该 IP。工作区里已有一份 MIT 许可的明文实现可直接用：`D:\FPGA\易灵思\工作区\03_EVSoC源码\evsoc-main\cam_single\Ti60F225_dsi\source\axi\axi_interconnect.v`（Alex Forencich，`S_COUNT/M_COUNT/DATA_WIDTH/ID_WIDTH` 都是参数，可直接配成 3→1、128 位、4 位 ID）。注意它是第三方实现、**不是 Efinix 原厂 IP**，替换后需要 Lead 重新跑 Efinity 流程验证资源与时序。
2. 或在 Efinity IP 里重新生成互联，尝试别的 `ARB_MODE`（`ROUND_ROBIN_1/2`），并**用 P0 的方法复测**其响应路由是否符合预期。

### P3 — 两个独立的健壮性问题

- **ID 截断有损**（§5.5a）：确认 SoC 的 DDR AXI ID 是否恒 ≤ 0xF；若不是，需要把互联的 `ID_WIDTH` 加宽到 6 或 8 位并重生成（同时得确认 IP 是否会把端口号拼进去，见 §3.3）。
- **256 MB 地址窗口**（§3.2/§5.5b）：请 task-3 的 DDR 内存图规划**不要使用 ≥ `0x1000_0000` 的地址**，否则会踩到窗口外。

---

## 8. 复现方式（照抄可跑）

```powershell
# 1) 全部 3 种配置（约 1 分钟），退出码 0 表示三种配置都符合预期
powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\sim\axi_ic\run_axi_ic.ps1

# 2) 只看 baseline 的详细日志
Get-Content D:\FPGA\mmt\sim\axi_ic\_run\axi_ic_baseline.log

# 3) 复现"加密 IP 不能用 iverilog 仿真"这一结论
D:\iverilog\Library\bin\iverilog.exe -g2012 -o $env:TEMP\probe.vvp `
    D:\FPGA\mmt\ip\axi_interconnect\axi_interconnect.v     # 期望 exit 2，第 251 行 syntax error
```

前置条件（与 `sim\run_all.ps1` 相同）：PATH 里要有
`D:\iverilog\Library\bin` 与 `D:\iverilog\Library\mingw-w64\bin`。

---

## 9. 文件清单（本任务新增，均未触碰 `rtl/`、`ip/`、`constr/`、`sw/`、`mmt.xml`、`sim/` 已有文件）

| 文件 | 说明 |
|---|---|
| `sim/axi_ic/axi_master_bfm.v` | AXI4 主口行为模型（含顶层 ID 截断复刻） |
| `sim/axi_ic/axi4_slave_model.v` | AXI4 从口行为模型（DDR3 替身） |
| `sim/axi_ic/axi_ic_semantic_model.v` | 3→1 互联行为模型（ARB_ORDER / ROUTE_POLICY 可配） |
| `sim/axi_ic/dut_axi_ic.v` | 真 IP 端口表的适配插座（换 1 行即可指向真 IP） |
| `sim/axi_ic/tb_axi_ic.v` | testbench（TC1–TC7，PASS/FAIL 计数，失败则非零退出码） |
| `sim/axi_ic/run_axi_ic.ps1` | 一键回归脚本（3 种配置） |
| `sim/axi_ic/_run/*.log` | 三种配置的完整运行日志（实测证据） |
| `docs/AXI互联仿真结论.md` | 本文档 |

**未修改**：`sim/run_all.ps1` 及其它已有仿真文件、`rtl/`、`ip/`、`constr/`、`sw/`、`mmt.xml`。未执行任何 Efinity 流程（未跑 `build.ps1` / `run_full_flow.ps1` / `efx_map` / `efx_pnr`），全程只用 iverilog。
