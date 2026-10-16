# 路线 B（TinyML + DDR）接入进度与已知问题

> 写作时间：2026-10-09 深夜 | 作者：DeepSeek harness 会话（另一个 AI 协作者）
> 用途：给 Claude（学习辅导那位）看，让它在没有我解释的情况下能准确讲这个工程当前的状态。
> 规矩：每条结论都标**实测 / 推断 / 未做**，不要把"没上过板"说成"能工作"。

---

## 一、已完成并且有实测证据的

### 1. Sapphire SoC 重生成（命令行，不是 GUI 手改）
工具：`工作区\_工具\regen_soc.py`（用 Efinity 的 `ipm_api_service.design.IPMDesignAPI`，命令行生成 IP）

| 参数 | 值 |
|---|---|
| CustomInstruction | `1'b1` |
| DDR / DDR_AXI4 | `1'b1` / `1'b1`（**全双工 AXI4**，不是半双工） |
| LDSize | 16380（KB → 16 MB 应用区） |
| OCRSize | 32768（片内 RAM 32 KB） |
| DDRWidth / DDR_IdWidth | 128 / **8**（DDR3 控制器只有 4 位，顶层截断，见 §1.3） |

- 端口：**91 → 173（新增 82 个，丢失 0 个）**
  - `io_ddrA_*` 39 个：AXI4 主口（128 位数据、32 位地址），SoC 访问 DDR 就走这里
  - `io_ddrMasters_0_*` 41 个：带独立 `clk`/`reset`，是给**外部主口经 SoC 访问 DDR** 用的（本方案不用）
  - `io_memoryClk` / `io_memoryReset`：SoC 内 DDR 通路的时钟/复位域
- 证据：`ip\sapphire_soc\settings.json`、`ip\sapphire_soc\source\soc_config`

### 1.1 地址与大小（**从新 IP 的 `soc_config` + 网表核实**）
| 区域 | 基址/大小 | 依据 |
|---|---|---|
| 片内 RAM | **0xF9000000 / 0x8000（32 KB）** | 网表 `ram_symbol0 [0:8191]`×4 lane = 32768 B；复位向量 `32'hf9000000`；窗口比较 `~0x7fff == 0xf9000000` |
| DDR 域 | `--ddrASize 0xe0000000`（3.5 GB 窗口） | `soc_config`（**基址 0 属推断**，见下） |
| APB 桥 | 0xF8000000（APB slave0 偏移 +0x100000） | `soc_config` |
| AXI slave | 0xE1000000（16 MB） | `soc_config` |
| UART / I2C / SPI / GPIO | 0x010000 / 0x016000 / 0x014000 / 0x015000（相对 APB 桥） | `soc_config` |

- **固件装载实测**：重编固件 → `hex2soc.ps1 -Install`，`RAM 32768 bytes, 3089 used`，round-trip 校验逐字节 OK
- ⚠️ **`link.ld` 还没改**：固件仍链接在 0xF9000000 / 32K。当前固件不访问 DDR，所以能跑；要"固件搬进 DDR 运行"必须另做（见 §3）
- ⚠️ 待核实：给 CPU 看的 **DDR 区基址**。`--ddrASize 0xe0000000` 说明 DDR 占低 3.5 GB，但基址=0 是**推断**——依据是官方 EVSOC 把视频缓冲放在 0x01100000 并注明"不能和 default.ld 给 RISC-V 程序的空间重叠"
- ⚠️ 注意：`soc_config` 里 `--ramHex ...bootloader_124K.hex`（124K 变体的 bootloader），与 LDSize=16380 不一致。走"bootloader 把 app 从 flash 拷进 DDR"这条路之前必须先查清这个

### 1.2 AXI 互联（3 主口 → 1 从口）
- IP：`efx_axi_interconnect` **5.6**（`efinixinc.com / axi_infra`），命令行生成（`工作区\_工具\regen_ip.py`）
- 参数：`S_PORTS=3`、`M_PORTS=1`、`DATA_WIDTH=128`、`ID_WIDTH=4`、`ADDR_WIDTH=32`；下游地址窗口 0x00000000 宽 28 位（256 MB，正好整片 DDR3）
- 端口分配：**s0 = frame_buffer（视频实时路径）、s1 = SoC、s2 = TinyML**
- ⚠️ **`ARB_MODE` 与 `PROTOCOL` 无法从命令行下发**（任何取值都 `GENERIC_ERROR`，实测），只能用默认：**ARB_MODE=PRIORITY、PROTOCOL=AXI4**。所以"端口 0 是否真的优先"**还没验证**
- 互联源码是 `pragma protect` 加密的，**ID 内部怎么处理看不到** —— 所以必须靠仿真验，不能靠读

### 1.3 ID 与位宽怎么对接（三个主口宽度都不一样）
| 主口 | 数据 | ID | 处理 |
|---|---|---|---|
| frame_buffer | 128 | **6 位** | 去程截成低 4 位；回程零扩展回 6 位 |
| SoC `io_ddrA` | 128 | **8 位** | 去程截成低 4 位；回程零扩展回 8 位 |
| TinyML | 128 | **无 ID** | `awid/arid/wid` 全接 0；回程 ID 不接 |
| DDR3 控制器从口 | 128 | **4 位** | 互联 m 口直接对接 |

- 8 位 → 4 位截断是**照厂商自己的 `ddr_demo_ti60` 做的**：那份官方 DDR demo 就是 8 位 SoC ID 直连 4 位控制器（Verilog 静默截断）
- ⚠️ 已知风险：frame_buffer 与 TinyML 的 ID **都是 0**，互联能否正确按端口分发响应属于未验证项 → 计划用仿真证（§3）

### 1.4 帧缓存搬迁
`frame_buffer.START_ADDR`：`0x00000` → **`0x02000000`**（3 个 bank × ~4.15 MB → 0x02BDDDFF），**避开 SoC 的 16 MB 应用区**
（`bank_switch.v` 里三个 bank 地址都由 `START_ADDR` 推出，所以顶层改一行即可）

### 1.5 TinyML RTL 搬入 `ip\tinyml\`
| 文件 | 说明 |
|---|---|
| `tinyml_top.v` | 9.4 KB，命令口 + 128 位 AXI 主口 + 响应口，内部例化加密核 |
| `tinyml_accelerator.v` | **1.1 MB，IEEE-1735 加密核**（QuestaSim 2023.1 加密，keyowner=Efinix Inc.） |
| `tinyml_core0_define.v` | 层配置（来自官方 mobilenetv1 那份） |
| `tinyml_defines.v` | 通道数（单通道） |
| `common_*.v` ×6 | 官方 `source/common/` 的基础模块（见 §2 为什么需要） |

- 例化位置：`rtl\mmt\mmt_top.v`（`tinyml_top #(.AXI_DW(128)) u_tinyml_accel`）
- 命令口 ←→ SoC 的 `cpu0_customInstruction_*`（8 根，方向按 `sapphire_soc.v` 实测：cmd_valid/function_id/inputs_0/1/rsp_ready 是 SoC 输出）
- 配置：`CONV_DEPTHW_MODE=STANDARD`（IN_PARALLEL=8、OUT_PARALLEL=1）、`ADD/LR/FC/MUL/MIN_MAX=DISABLE`、**`TINYML_CACHE=ENABLE`、`CACHE_DEPTH=512`**、`AXI_DW=128`
- 时钟：`clk`=core_clk，`reset`=`~w_arstn`（高有效）；`m_axi_clk`=core_clk，`m_axi_rstn`=w_arstn

### 1.6 顺手修掉的两个真 bug
1. `rtl\mmt\soc\mmt_soc_subsystem.v`：`soc_system_reset` 原来是**没被驱动的线**（悬空 z 直接送进 SoC 的 `io_systemReset`）→ 现在 `assign soc_system_reset = ~rst_n;`
2. 互联的 `s_axi_bid` / `s_axi_rid` 是**输出端口**，原来把常量拼进表达式 → `VERI-1180 constant is not allowed here`（实测踩到）→ 改成中间线 + 零扩展

---

## 二、当前**卡住**的地方（唯一 blocker）

```
ERROR : ip/tinyml/tinyml_accelerator.v(5093): instantiating unknown module '**' [VERI-1063]
INFO  : ip/tinyml/tinyml_accelerator.v(5093): ** '**' remains a black box due to errors in its contents
INFO  : ip/tinyml/tinyml_accelerator.v(6115): ** '**' remains a black box ...
```

工具把保护区里的标识符**打码成 `**`**（本工程其它加密文件也这样），看不到真实模块名。

**已经排除的可能**（都是实测，不是猜）：

| 假设 | 结论 |
|---|---|
| 我们工程上下文有问题 | **排除**：用只含 tinyml 文件的最小探针工程（顶层直接是 `tinyml_top`）复现**完全相同**的错误 |
| 缺 `tinyml_defines.v` | 排除，补了没用 |
| 缺 FIFO 包装 `common_efx_fifo_wrapper` | 排除：它与工程已有的 `efx_fifo_wrapper` **IP_UUID 完全相同**（`_6ceb0421…`），整份加进去会"重复定义"，说明工程已提供 |
| 缺官方 `source.f` 的其它文件 | 排除：把官方 `source.f` 全部 45 个文件 + 官方 `ip/` 下 7 个 IP 源码**全加进来**，错误一模一样 |
| 综合参数差异（`hdl-compile-unit` 等） | 排除：官方工程同样是 `hdl-compile-unit=1`、`blackbox-error=1` |

**已知进展**：加官方 `source/common/` 那批基础模块后，未知模块**从 3 个减到 2 个**（第 4795 行解决了，日志显示它实例化的正是 `common_simple_dual_port_ram(DATA_WIDTH=128)`）。

**推断（未证实）**：这个加密核在当前 **Efinity 2026.1** 下可能有一个内部实例化的模块没随包提供；官方 EVSOC 工程是 **2024.2** 生成的（`settings.json` sw_version=2024.2.294）。
下一步计划：① 改走官方那条路——例化 `tinyml_accelerator_channels`（官方例化的是它，不是 `tinyml_top`）② 试 hello world 那份 `tinyml_core0_define.v`（配置不同 → 内部结构可能不同）③ 找厂商要这个文件在 2026.1 下的编译说明。

---

## 三、验证现状（**不要读成"完成了"**）

| 项 | 状态 |
|---|---|
| RTL 仿真回归 `sim\run_all.ps1` | **84 项检查全 PASS**（改动后重跑过） |
| Efinity 综合 | **未通过**（§2 的 blocker），**没有**新的资源数字 |
| 三主口 AXI 仲裁 / ID 路由仿真 | **未做**（计划中） |
| DDR 带宽预算表 | **未做** |
| BRAM 实测（TinyML 缓存是大头） | **未做**（要等综合过） |
| 上板 | 板子还没到 |

---

## 四、给 Claude 的五个问题的直接回答

1. **重生成后 RAM/DDR 基址大小、link.ld 更新了吗？**
   片内 RAM **0xF9000000 / 32 KB**（网表核实）、DDR 域 3.5 GB 窗口（`--ddrASize 0xe0000000`，基址 0 属推断）；**link.ld 还没更新**，固件仍跑片内 RAM。bootloader 变体（124K）与 LDSize 不一致这点待查。
2. **DDR 带宽预算表、读端优先级怎么保证？**
   **还没有预算表**。互联 `ARB_MODE` 只能吃默认 `PRIORITY`（命令行设不了，实测报错），端口顺序 s0=frame_buffer / s1=SoC / s2=TinyML。**"端口 0 是否优先"未验证**，要靠仿真。
3. **无 ID 的加速器怎么接到 4 位 ID 的从机？**
   见 §1.3：TinyML 侧 ID 接 0；SoC 8 位截断成 4 位（照厂商 DDR demo 的做法）；回程 ID 零扩展。**ID 全 0 的冲突风险未验证**。
4. **TinyML / SoC / DDR 控制器的 AXI 口各在哪个时钟域？跨域用了什么？**
   三者的 AXI 都在 **core_clk = 100 MHz**（来自 `MIPI_TX_PLL`，SDC 里 10 ns）；SoC 的 `io_memoryClk` 也接 core_clk。所以这条路径**不跨域、没加 CDC**。注意 SDC 把 core_clk/axi_clk/sdram_clk 声明为 exclusive，工具不检查它们之间的路径（同网所以无影响，但要知道这个前提）。
5. **那 5 个文件里有没有 `for` 循环写大 RAM？综合后 BRAM 多少？**
   综合还没过，**BRAM 数字还没有**。加速器侧最吃 BRAM 的是 `TINYML_CACHE=ENABLE + CACHE_DEPTH=512`。本工程有条硬规矩：**资源数字必须变化**才算真接上了（防"文件进了 XML 但没实例化 → 整块被优化掉"），这条靠它抓过 4 个真 bug。
