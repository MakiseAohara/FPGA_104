# Efinity Debugger + VIO 在线调增益 —— Kevin 操作手册

> 面向非专业用户。每个小节都标明信息**从哪来**：
> - **【读到的】** = 实际打开文件/目录看到的原文（附路径与行号）
> - **【推断】** = 由读到的内容推出来的结论
> - **【未验证】** = 没上板、没启动过 GUI，需要现场实测确认
>
> 写作时间：2026-10-19。工程：`D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2`
> ⚠️ 本文档**没有**做烧录、没有上板验证、没有构建。所有"应该"都要现场试。
> ⚠️ 本文档**已修正**三个常见误传：① Debugger 里没有 board profile 下拉框；② Hex 模式不能填 `0x118`；
> ③ 不传 `--profile_file` 时 Debugger 启动后**什么都不加载**（不是自动读 `debug.json`）。

---

## 0. 一分钟版（先看这个）

1. 确认板上已经跑着目标位流（`.bit` 通过 JTAG 临时加载，断电即失效）。
2. 启动 `D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat --project_home "...\v7_work2"`。
3. Profile 页点 **`Import Profile`**，选 **`v7_work2\debug.json`**（不是 wizard 那个，更不是 `out\debug_profile.mark_debug.json`）。
4. Debug 页：**USB Target** 选 FT4232H → 指令选 **`USER1`** → 点 **`Configure`**。
   （Debugger **没有** "Board Profile" 下拉框；`Generic Board Profile Using FT4232H` 是烧录器那一侧的板档。）
5. 在 `vio0` 面板：`Radix` 列选 **Hex**，`Value` 列填**裸十六进制** `118`（**不要**写 `0x118`）。
6. 上电默认值就是 `0x118 / 0xff / 0x15e`（1.094× / 0.996× / 1.367×），**当前画面已经是带默认增益的结果**，不是 1.0×。

---

## 1. 怎么启动 Efinity Debugger 【读到的】

`D:\Efinity\2026.1\debugger\bin` 目录实际内容：

| 文件 | 大小 | 是什么 |
|---|---|---|
| `efinity_dbg.bat` | 242 B | **Debugger GUI 启动器（Windows，首选）** |
| `efinity_dbg.sh` | 1066 B | Linux 版启动器（本机不用） |
| `jtag_daemon_cmd.bat` | 284 B | JTAG 后台守护进程启动器（Windows，一般不用手动开） |
| `jtag_daemon_cmd.sh` | 837 B | 同上，Linux |
| `dark.qss` / `light.qss` | 4405 / 2196 B | GUI 主题样式，不是程序 |
| `_version.py` | 27 B | 版本字符串 |
| `efx_dbg\` | 目录 | 真正的 Python 实现：`gui.py` / `jtag.py` / `openocd_manager.py` / `Ui_*.py` … |

**这个目录里没有 `.exe`。** 所以"双击一个 exe"行不通，要用 `.bat`。

### 1.1 首选：`D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat`

脚本原文（**【读到的】**，9 行）：
```bat
@echo off
if not defined EFINITY_HOME (
        call "%~dp0\..\..\bin\setup.bat"
)
setlocal
set PYTHONPATH=%EFINITY_HOME%/debugger/bin;%EFINITY_HOME%/pgm/bin;%PYTHONPATH%
@"%EFINITY_HOME%\bin\python3.bat" -m efx_dbg.gui %*
endlocal
```
即：没设 `EFINITY_HOME` 时它自己 `call setup.bat`，然后用内置 python 跑 `efx_dbg.gui`。

### 1.2 两种启动方式

**A. 从 Efinity GUI 里进（最稳，工程/器件信息自动带过去）**
`D:\Efinity\2026.1\bin\efinity.exe` → 打开工程 → Debugger 入口。
Efinity 会以 `--project_home <工程目录>` 传给 `efx_dbg.gui`（**【读到的】** `gui.py:4262-4268` 的帮助文本：`Path of project directory when starting Debugger GUI from Efinity`）。

**B. 命令行直接开（推荐，Kevin 少点几下）**

```bat
D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat ^
  --project_home "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2" ^
  --profile_file "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2\debug.json" ^
  --device ti60f225 --family Titanium
```

参数依据 **【读到的】** `gui.py:4259-4295`：`--project_home`（默认 `.`）、`--profile_file`（**默认空串**）、`--device`、`--family`（默认 `Titanium`）、`--netdb`、`--no_save`、`--debug`。

> **别搞混**：`D:\Efinity\2026.1\bin\dbg_wizard.exe`（21.7 MB）是 **Debug Wizard**（生成 debug 核 / 把 VIO 插进 RTL 的工具），**不是** Debugger GUI。我们这次不改 RTL、不重新生成 profile，用不到它。

---

## 2. 用哪个 debug profile？—— 用 `v7_work2\debug.json`

工程里有三个长得很像的 JSON，内容完全不同。逐个读原文对比：

### 2.1 `v7_work2\debug_profile.wizard.json`（60,551 B）【读到的】—— 不要用

顶层键：`debug_cores` / `connections` / `vdbs` / `session`。

```json
"debug_cores": [
    {
        "name": "la0",
        "type": "la",
        "uuid": "96a95a874f72490e96be82b47cdb6c02",
        "trigin_en": false, "trigout_en": false, "auto_inserted": true,
        "capture_control": false, "data_depth": 2048, "input_pipeline": 1,
        "probes": [ 27 个探针 ... ]
    }
]
"session.wizard.jtag_user" = "USER2"
"vdbs" = {"file":"debug_top.post.vdb","instance":"edb_top_autodbg_inst__"}
```

四个致命不符（每一条都足以否决它）：
1. **只有 `la0` 一个核，没有 `vio0`** → 加载它根本不会出现 VIO 窗口，改不了增益。
2. `la0` UUID 是 `96a95a87…6c02`，当前 RTL/`debug.json` 是 `40fc40c1…2a4c`（见 §5）→ 不是同一份设计。
3. `jtag_user` = **`USER2`**，而当前是 `USER1`。
4. 27 个探针全是 MIPI/CSI2 信号（`w_mipi_rx_*`、`Rx_HS_D_*`、`mdebug_*`），当前 `la0` 只有 4 个（`ch0_g/ch0_b/ch0_de/cal_done`）。

它的 mtime 是 2026/9/17，比 `debug.json`/`debug_top.v`（2026/8/13）新，但内容和当前设计不符 → 这是 9/17 那次另做的实验留下的**过期中间产物**。

### 2.2 `v7_work2\out\debug_profile.mark_debug.json`（331 B）【读到的】—— 不能用

**全文**（一个 debug_core 都没有）：
```json
{
    "session": {
        "wizard": {
            "capture_control": false,
            "data_depth": 1024,
            "input_pipeline": 1,
            "jtag_user": "USER1",
            "selected_nets": [
            ],
            "src": "elaborate",
            "top_module": "ti60f225_oob_top"
        }
    }
}
```

**它不只是"不太好用"，而是加载必然报错**，代码链条：
- 加载走 `DebugProfileDecoder`（**【读到的】** `D:\Efinity\2026.1\pgm\bin\efx_pgm\efx_hw_manager.py:319-323`）。
- 解码器**只把含 `debug_cores` 的字典**当 `DebugProfile`；没有 `debug_cores` 只有 `session` 时，它原样返回普通 `dict`（**【读到的】** `D:\Efinity\2026.1\debugger\bin\efx_dbg\define.py:652-683`）。
- GUI 拿到返回值后第一句就是 `debug_profile.equal_valid()`（**【读到的】** `gui.py:3713`）→ 普通 dict 没这方法 → 抛异常 → 走 `except Exception` → 弹错误框（`gui.py:3756-3757`）。

→ 它是 build/mark_debug 流程的会话记录，**不是给 Debugger 的 profile**。

### 2.3 `v7_work2\debug.json`（1,883 B）【读到的】—— 用这个

```json
"debug_cores": [
    { "name": "vio0", "type": "vio",
      "uuid": "d2d3643a7f1e49a3a7f48b242e104fdd",
      "probes": [ r_gain/16, g_gain/16, b_gain/16, gamma_sel/1 ] },
    { "name": "la0", "type": "la",
      "uuid": "40fc40c15a7b4e5392113defb86d2a4c",
      "probes": [ ch0_g/8, ch0_b/8, ch0_de/1, cal_done/1 ],
      "data_depth": 1024, "input_pipeline": 1 }
],
"session": { "debug_widget": [], "wizard": {} },
"jtag_user": "USER1"
```

### 2.4 结论：加载 `debug.json`

判断依据（三条独立证据，都是**【读到的】**）：

| 证据 | `debug.json` | `debug_profile.wizard.json` | 硬件里真实的（`debug_top.v`） |
|---|---|---|---|
| vio0 UUID | `d2d3643a7f1e49a3a7f48b242e104fdd` | **没有 vio0** | 第 97 行 `128'hd2d3643a7f1e49a3a7f48b242e104fdd` ✅ |
| la0 UUID | `40fc40c15a7b4e5392113defb86d2a4c` | `96a95a87…6c02` ❌ | 第 260 行 `128'h40fc40c15a7b4e5392113defb86d2a4c` ✅ |
| `jtag_user` | `USER1` | `USER2` ❌ | USER1 |

**⇒ Debugger 实际要加载的是 `v7_work2\debug.json`。**

### 2.5 重要：默认启动其实**什么都不加载**（已核实）

- `--profile_file` 默认是空串（**【读到的】** `gui.py:4280-4283`）。
- 于是 `PROFILE_FILE` 变成 `project_home` 这个**目录**本身（`gui.py:3283-3286`）。
- 启动时 `on_startup()` 先 `os.path.isfile()` 判断（**【读到的】** `gui.py:3588-3591`）——目录不是文件 → **什么也不加载**。

**所以必须手动导入**：Profile 页 → **`Import Profile`** → 选 `...\v7_work2\debug.json`；
或者按 §1.2 方式 B 用 `--profile_file` 直接带上（更省事、更稳）。

导入成功的标志：标题栏变成 `... Debugger - <文件路径>`（`gui.py:3369-3371`），且 `Add Debug Core` / `Generate` 按钮**仍然可用**（因为 `debug.json` 的 `session.wizard` 是空对象，只有 wizard 非空才会禁用这几个按钮，见 `gui.py:3715-3719`）。这是正常现象。

---

## 3. 连接 FT4232H

### 3.1 Debugger 里到底选什么（**不是** board profile）

**Debugger 主窗口没有 "Board Profile" 下拉框**，只有两组控件（**【读到的】** `D:\Efinity\2026.1\debugger\bin\efx_dbg\Ui_DebuggerMainWindow.py`）：

| 位置 | 控件（对象名） | 你要做的 |
|---|---|---|
| Profile 页 | `USB Target`（`cb_usb_target`，行 105）+ 刷新（`pb_refresh_usb_target`）+ `USB Info` | 选中你的 FT4232H；没有就点刷新 |
| Debug 页 | `USB Target`（`cb_debug_target`，行 232）+ `USER1..USER4`（`cb_user_instr`，行 235/375-378）+ `Configure`/`Unconfig`（行 380-383） | 选同一个 target → 指令 **`USER1`** → `Configure` |

`Generic Board Profile Using FT4232H` 是**烧录器（Programmer / efx_pgm）**那一侧的板级配置，来源：
```
D:\Efinity\2026.1\pgm\bin\efx_pgm\efx_hw_common\boards\generic_ft4232h.json
  "name": "Generic Board Profile Using FT4232H"
  "usb": { "vid": "0x0403", "pid": "0x6011", "device_type": "ft4232h" }
  "pinout": TCK=FTDI_BDBUS0, TDI=FTDI_BDBUS1, TDO=FTDI_BDBUS2, TMS=FTDI_BDBUS3  （即 FT4232H 的 B 通道）
  "supported_mode": ["SPI Active","SPI Passive","JTAG","SPI Active using JTAG Bridge"]
```
（`boards\` 下另有 `generic_ft4232ha.json` / `generic_ft4232hp.json`，烧录时别选错；**Debugger 里不需要选这些**。）

Debugger 侧不需要你填 pinout —— 它内部用 OpenOCD + 模板自动生成 FTDI 配置：
```
D:\Efinity\2026.1\debugger\bin\efx_dbg\openocd_cfg\ftdi_template.cfg
  adapter driver ftdi
  ftdi vid_pid 0x{vid} 0x{pid}
  ftdi channel {jtag_channel_no}
  transport select jtag
```

**结论**：Debugger 里认不到 FT4232H，是**驱动/USB 占用**问题，不是"板档选错"。

### 3.2 步骤

1. 板子**上电**，USB 线插好（设备管理器里应看到 FTDI，VID/PID = `0403:6011`）。
2. 先把目标 `.bit` 通过 JTAG 灌进去（`flash_vendor.ps1`，或已有位流直接跳过）。
3. 烧完**保持上电、不要断电、不要按复位**，启动 `efinity_dbg.bat`。
4. 导入 `debug.json`（§2.5）→ Debug 页选 USB Target → **`USER1`** → `Configure`。
5. 成功后 Console 会打印器件 ID（**【未验证】**具体文案），可以与烧录时的
   `Device ID read from JTAG: 0x10660A79` 对照，**同一个 ID 就说明连的是同一颗片子**。
6. 主界面应出现 `vio0`（4 个探针）和 `la0`（4 个探针）。

### 3.3 烧录与 Debugger 冲突吗？——冲突，同一时刻只能一个【推断，强依据】

- 两者都通过 **FT4232H 的 B 通道 JTAG**（`TCK/TDI/TDO/TMS`，见 §3.1 的 pinout）访问同一颗 Ti60，物理上只有一个 JTAG 口。
- Debugger 后台起 OpenOCD（`efx_dbg\openocd_manager.py`），烧录跑 `ftdi_program.py` —— **同一时刻只能一个持有该 USB 设备**。
- 代码侧的设计也能看出：Programmer 运行期间 Debugger 会**主动禁用** `Configure / Unconfig / 刷新 USB Target`，等 Programmer 停了再恢复 —— **【读到的】** `gui.py:3451-3474` 的 `programmer_watcher_start` / `programmer_watcher_stop`（内部调 `hw_backend.is_programmer_running`）。

**固定顺序**：
1. 关 Efinity GUI 的 Programmer 页 / 结束所有烧录进程。
2. 确认没有残留 `python` / `openocd`（见 §3.4 的命令）。
3. 开 Debugger → 导入 profile → `Configure` → 调增益。
4. 要换位流时：Debugger 点 `Unconfig` → **关掉 Debugger** → 再烧录。

反过来说：`.bit` 若是 `-m jtag` **临时加载**，**断电就没了**。板子一断电/复位，Debugger 会看到"设备没响应"——必须**重新灌位流**再重连。

> **【未验证】** 两个同时开着时具体报什么错（OpenOCD 侧一般是 USB 打不开 / libftdi 占用）。结论"必须串行"来自架构与代码，未上板实测。

### 3.4 要不要先关别的程序？——要

| 要关的 | 为什么 |
|---|---|
| `flash_vendor.ps1` / `efx_pgm` 的任何残留进程 | 占着 JTAG |
| **Efinity GUI 的 Programmer 页面**（开着且已连接时） | 同样占 JTAG |
| 上一次没退干净的 Debugger 窗口 | `jtag_daemon` 还挂着 |
| 残留 `openocd` / `python` | JTAG 被锁 |

`jtag_daemon_cmd.bat` 跑的是（**【读到的】**）：
```bat
@"%EFINITY_HOME%\bin\python3.bat" "%EFINITY_HOME%\debugger\bin\efx_dbg\openocd_manager.py" %*
```
先看有没有残留：
```powershell
Get-Process | Where-Object { $_.ProcessName -match 'openocd|python|efx' } | Select-Object Id,ProcessName,StartTime
```

---

## 4. 在 vio0 里改 r_gain / g_gain / b_gain

### 4.1 vio0 的 4 个探针【读到的】—— `v7_work2\debug.json:4-28` 原文

```json
{
    "name": "vio0",
    "type": "vio",
    "uuid": "d2d3643a7f1e49a3a7f48b242e104fdd",
    "probes": [
        { "name": "r_gain",    "width": 16, "init": "0x118" },
        { "name": "g_gain",    "width": 16, "init": "0xff"  },
        { "name": "b_gain",    "width": 16, "init": "0x15e" },
        { "name": "gamma_sel", "width": 1,  "init": "0x0"   }
    ]
}
```

| 探针 | 位宽 | 类型 | 默认初值 | 含义（Q8.8） |
|---|---|---|---|---|
| `r_gain` | 16 | probe_out（输出到逻辑） | `0x118` | 红增益 1.09375× |
| `g_gain` | 16 | probe_out | `0xff` | 绿增益 0.99609× |
| `b_gain` | 16 | probe_out | `0x15e` | 蓝增益 1.36719× |
| `gamma_sel` | 1 | probe_out | `0x0` | gamma 通路选择（0=直通，1=走 gamma） |

### 4.2 上电默认值从哪来【读到的】—— `v7_work2\debug_top.v:94-105` 原文

```verilog
`DBG_MODULE_NAME(edb_vio_top) #(
    .NUM_PROBE_IN           ( 0 ),
    .NUM_PROBE_OUT          ( 4 ),
    .UUID           ( 128'hd2d3643a7f1e49a3a7f48b242e104fdd ),
    .PROBE_OUT0_WIDTH       ( 16 ),
    .PROBE_OUT1_WIDTH       ( 16 ),
    .PROBE_OUT2_WIDTH       ( 16 ),
    .PROBE_OUT3_WIDTH       ( 1 ),
    .PROBE_OUT0_INIT_VAL    ( 'h118 ),
    .PROBE_OUT1_INIT_VAL    ( 'hff ),
    .PROBE_OUT2_INIT_VAL    ( 'h15e ),
    .PROBE_OUT3_INIT_VAL    ( 'h0 )
) vio0 (
```

对应关系（**【推断】**，按声明顺序 0→3 对着 `debug.json` 的顺序）：
`PROBE_OUT0 = r_gain = 0x118`、`OUT1 = g_gain = 0xff`、`OUT2 = b_gain = 0x15e`、`OUT3 = gamma_sel = 0x0`。

**⇒ 上电默认就是 `0x118 / 0xff / 0x15e`（1.094× / 0.996× / 1.367×），不是"1.0 白点"。**
**你现在看到的画面，已经带上这套默认增益。** 想回到三通道相等（1.0×），要手动填 `0x100 / 0x100 / 0x100`。

### 4.3 Q8.8 定点怎么换算

RTL 写死了（**【读到的】** `v7_work2\rtl\debayer\rgb_gain_v1.v:3`）：
```verilog
parameter	Q_WIDTH			= 16	// Q8.8定点
```
乘法与右移（同文件 70-90 行附近）：
```verilog
mul_high = pix_high * gain_g;
...
//Q8.8 右移8位 + 10bit饱和
wire [P_DEPTH-1:0] out_high = (|mul_high[Q_WIDTH+P_DEPTH-1:P_DEPTH+8] ) ? 2**P_DEPTH-1 : mul_high[P_DEPTH+8-1:8];
```

即 **寄存器值 ÷ 256 = 实际倍数**（低 8 位是小数）：

| 十六进制 | 十进制 | 倍数 | 说明 |
|---|---|---|---|
| `0x080` | 128 | 0.500× | 减半 |
| `0x0ff` | 255 | 0.996× | g_gain 上电默认 |
| **`0x100`** | 256 | **1.000×** | 基准，三通道都填它 = 不变色 |
| **`0x118`** | **280** | **1.094×** | **r_gain 上电默认** |
| `0x140` | 320 | 1.250× | |
| **`0x15e`** | **350** | **1.367×** | **b_gain 上电默认** |
| `0x180` | 384 | 1.500× | |
| `0x1ff` | 511 | 1.996× | |
| `0x200` | 512 | 2.000× | |

可调范围 `0x000`~`0xFFFF`（0×~255.996×），实用区 0x080~0x200 足够。

两个容易踩的点（都在 RTL 里查得到）：
1. **填 0 不会黑屏**：`rtl\ti60f225_oob_top.v:783` 是 `.r_gain (|r_gain? r_gain:255)` —— 三路为 0 时按 255 处理（≈1.0×）。
2. **会饱和**：乘积超过 8 位就钳到最大值（`2**P_DEPTH-1`），所以增益调大后先"白掉/断色"是正常的，不是坏了。

### 4.4 输入框到底怎么填（**已核实，别写 `0x`**）

VIO 表 7 列：`Name / Type / Width / Radix / Value / Control / Comparator`（**【读到的】** `Ui_VioDebug.py:34,72-85`）。

**【读到的】** `D:\Efinity\2026.1\debugger\bin\efx_dbg\gui.py` + `widgets.py`：
- `RADIX_TO_BASE = {'Dec':10,'Hex':16,'Bin':2}`（`gui.py:132`）。
- `Radix` 列是下拉框，宽度 >1 时可选 `Bin / Hex / Dec`（`gui.py:258-268`）。
- `Value` 列编辑器是 `HexLineEdit`，按 `Radix` 设显示进制（`gui.py:286-288`）。
- **Hex 模式的输入校验正则只接受裸十六进制字符**（`widgets.py:150-161`，形如 `[0-9a-f]{1,4}$`）。
  → **打 `0x118` 会被校验器拒收**；`HexLineEdit` 在 hex 显示时反而会把 `0x` 前缀剥掉（`widgets.py:196-202`）。

**正确操作：**

> 双击 `r_gain` 这行的 **`Radix`** → 选 **`Hex`**
> 双击 **`Value`** → 直接打 **`118`**（**不要写 `0x118`**）→ 回车 / 点开别处提交
> 想用十进制：`Radix` 选 **`Dec`**，`Value` 填 **`280`**。两者等价。

其余列：
- `Control` 列：16 位探针只有 **`Hex`** 一个选项（`gui.py:293-305`，宽 >1 时 `addItems(["Hex"])`）→ 保持默认不动。
- `gamma_sel`（1 位）：`Control` 列会多出 `Active-High Button / Active-Low Button / Toggle`（`gui.py:296-299`）→ **别动它**，默认 0。
- `Comparator` 列：留空即可（允许 empty，`gui.py:307-313`）。

**【未验证】**：
- 改完 `Value` 后是立刻写进 FPGA，还是要再点一次 `Apply/Update`（不同版本行为可能不同）。
  **建议：改完看画面变不变；没变就按回车再点一次该单元格，或看 Console 有没有写操作记录。**
  实在不行把 `Radix` 换成 `Dec` 再试（有些版本对 hex 提交更挑剔）。
- `vio0_clk = vid_clk_dvi2`（**【读到的】** `rtl/ti60f225_oob_top.v:1045`），所以**必须有时钟在跑**
  （HDMI 输出活跃 / 摄像头在出图），VIO 写入才会被逻辑真正采到。没有像素时钟时"写进去不生效"是正常的。
- `gamma_sel=1` 走 gamma 通路（**【读到的】** `rtl/ti60f225_oob_top.v:1006-1011` 的三目选择），
  切过去画面可能整体变化，调增益时保持 0 即可。

### 4.5 建议的验证动作

1. 先拍照/记下当前画面（默认 `1.094 / 0.996 / 1.367`）。
2. `r_gain` 从 `118` 改成 `100`（1.0×）→ 红应**略变弱**。
3. 改成 `1a0`（416，1.625×）→ 红应**明显增强**（高光可能先白）。
4. 三路一起设 `100` → 回到"无增益"基准画面。
5. 想复现默认：`118 / ff / 15e`。

---

## 5. 位流里的 debug 核 UUID 和 `debug.json` 一致吗？

### 5.1 结论：**RTL 层面完全一致；位流层面"未验证"（因为 `v7_work2` 目前没有位流）**

### 5.2 RTL 层面的比对（可以确证）

**【读到的】** `v7_work2\debug_top.v`：

```verilog
// 第 97 行，vio0
.UUID           ( 128'hd2d3643a7f1e49a3a7f48b242e104fdd ),

// 第 260 行，la0（edb_la_top 实例，NUM_PROBES=4 / DATA_DEPTH=1024）
.UUID   ( 128'h40fc40c15a7b4e5392113defb86d2a4c ),
```

与 `debug.json` **逐字符一致**。

并且 `debug_top.v` 确实编进了工程：**【读到的】** `v7_work2\ti60f225_oob.xml:54`
```xml
<efx:design_file name="debug_top.v" version="default" library="default"/>
```

顶层实例（**【读到的】** `v7_work2\rtl\ti60f225_oob_top.v:1033` 起）：
```verilog
debug_edb_top debug_edb_top_inst (
    .bscan_CAPTURE ( jtag_inst1_CAPTURE ), ...
    .vio0_clk       ( vid_clk_dvi2 ),
    .vio0_r_gain    ( r_gain ),
    .vio0_g_gain    ( g_gain ),
    .vio0_b_gain    ( b_gain ),
    .vio0_gamma_sel ( gamma_sel ),
    .la0_clk        ( vid_clk_dvi2 ),
    .la0_ch0_g      ( ch0_g ), ... .la0_cal_done ( cal_done )
);
```
这个实例**本身没有 UUID 参数**——`debug_edb_top` 模块定义在 `debug_top.v:14-316`，里面才例化带 UUID 的 `vio0` / `la0`。
旁证：**【读到的】** `v7_work2\out\ti60f225_oob.route.rpt` 里有 `debug_edb_top_inst/bscan_TCK_buffered` 这个时钟域 → 布局布线真的带着 debug 核。

### 5.3 位流层面：**没有可比对象，所以"未验证"**

**【读到的】** 目录现状：
- `v7_work2\outflow` 里**没有 `.bit`**。最新产物是 2026-10-19 20:51~20:54 的 interface/PnR 文件，
  `ti60f225_oob.log` 最后一行是 `Stage completed: interface` —— **位流生成那一步没完成**。
- 有 `.bit` 的是别的目录：`Ti60f225_sc431hai2hdmi_v7\...\outflow\ti60f225_oob.bit`（2,654,763 B，2026-09-18）、
  `v7_work\outflow\ti60f225_oob.bit`（同尺寸/同时间）。
- `.bit` 是压缩配置数据，**不能直接 grep 出 UUID**；要么反解位流，要么在 Debugger 里实测。我没有做（不构建、不上板）。

**因此**：
- "命令行编出来的位流里的 debug 核 UUID 是否等于 `debug.json`" → **未验证**
  （`v7_work2` 压根没编出位流；厂商那份 `.bit` 无法从文件层面读出 UUID）。
- 能确证的只有：`debug_top.v` / `debug.json` / 工程文件列表三者一致。
- 实际识别机制：Debugger `Configure` 后通过 JTAG 读 debug hub，再按 profile 里的 UUID 找核
  （UUID 被存成 8 个 16 位寄存器供读出，**【读到的】** `debug_top.v:1328`、`1433-1455`）。
  **所以 UUID 不匹配的典型表现是"Configure 成功但 vio0 不出现 / 读回全 0"，而不是报语法错**
  （具体文案 **【未验证】**）。

---

## 6. 连不上怎么办（排错清单）

### 6.1 USB Target 列表是空的

看哪里：Debug 页 `USB Target` 下拉、`USB Info` 文本、点 `Configure` 的报错。

代码里的硬证据：没有可用 USB target 时会断言
`assert usb_target >= 0 and usb_target < len(resolved_usb), 'No programming cable detected'`（**【读到的】** `gui.py:4086`）
→ 会看到/记录到 **`No programming cable detected`**。

按概率排：
1. **板子没上电**（USB 只提供 JTAG，不给目标板供电）。
2. **FTDI 驱动不对**。本机已知可用版本 `2.12.36.4`；版本混杂会蓝屏 `0x000000FC`（`flash_vendor.ps1` 的检查③ 就是防这个）。
   设备管理器里应看到 VID `0403` / PID `6011` 的 FT4232H。
3. **被别的进程占着**：Efinity Programmer、没退干净的 `ftdi_program.py`、残留 `openocd.exe` → 全结束再刷新。
4. **选错 target**：机器上不止一个 FTDI 设备时，选带 `0403:6011` 的那个。

### 6.2 点了 `Configure` 之后没反应 / 报错（扫不到链路）

1. **JTAG 被占用**（§3.3）——最常见。
2. **目标板没电或复位被拉住**（TDO 恒 0）。
3. **JTAG 速率太高/线太长**：OpenOCD 的 `adapter speed {jtag_khz}`（`openocd_cfg\ftdi_template.cfg`），排线长时降速。
4. **板上跑的不是这份设计**（没配置过 FPGA，或跑的是别的工程位流）→ 能扫到器件但读不到 debug hub。
5. **`.bit` 丢了**：断电/复位后 JTAG 临时加载的位流就没了，必须重灌（日志要有 `finished with JTAG programming`）。

### 6.3 Configure 成功但看不到 `vio0`

- **profile 选错**：导入了 `debug_profile.wizard.json`（没有 vio0）或 `out\debug_profile.mark_debug.json`（直接报错）。
  → 换成 `v7_work2\debug.json`。
- **UUID 不匹配**：位流是用别的 `debug_top.v` 生成的（§5.3）。
- **JTAG 指令选错**：必须是 **`USER1`**（`debug.json:68` `"jtag_user": "USER1"`），USER2/3/4 连不上 debug hub。

### 6.4 加载 profile 时弹错误框

- **`InvalidJsonError: ...`** → JSON 语法坏/文件拷了一半（**【读到的】** `gui.py:3062` 的 `MSG_W004`、`3752`）。
- **`Empty debug_cores list in DebugProfile.`** → 有 `debug_cores` 但列表空（`MSG_W001`，`define.py:485`）。
- **其它异常文本** → 多半"这不是 profile 文件"（§2.2 的 `mark_debug.json` 就是这样）。

### 6.5 看到 vio0 但"写进去不生效"

- `vio0_clk`（`vid_clk_dvi2`）没在跑：没图像/HDMI 无输出时，VIO 写入不会被采进寄存器（§4.4）。
- 输入格式不对：Hex 下写成了 `0x118`（被校验器拒收）→ 改成裸 `118`，或 Radix 换 `Dec` 填 `280`。
- 改完没提交（回车/点开别处）。

### 6.6 想看日志（最有用的一招）

- Debugger 自己的 **Console 面板**（GUI 下方）带时间戳打印关键动作。
- 落盘日志：`C:\Users\<你>\.efinity\log\<YYYYMMDDTHHMMSS>\`
  （规则：`EFINITY_USER_DIR` + `log/<时间戳>`，**【读到的】** `D:\Efinity\2026.1\pgm\bin\efx_pgm\util\gen_util.py:196-204`；
  本机 `EFINITY_USER_DIR = C:\Users\18915\.efinity`，来自 `%LOCALAPPDATA%\efinity\user_dir.ini`）。
  常见文件：`efinity_console.log`、`efinity.log`、`efxIP_grpc.log`。
- 命令行加 `--debug`（`gui.py:4270-4272`）开详细 stdout 日志：
  ```bat
  efinity_dbg.bat --debug --project_home "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2"
  ```

### 6.7 Debugger 一开就卡住 / 白屏

- 多半是上次进程没退干净：结束所有 `python*` / `efinity_dbg` 后重启（§3.4）。
- `QT_PLUGIN_PATH` 被别的软件污染也可能白屏 —— 直接用 `efinity_dbg.bat`（它会 `call setup.bat` 设好环境），别自己拼 python 命令。

---

## 7. 明确标注"未验证"的清单

1. **位流内部 UUID 无法从 `.bit` 读出**；`v7_work2` 目前没有位流（`outflow` 下无 `.bit`），所以"位流 UUID == `debug.json` UUID" **未验证**。
2. `--device ti60f225 --family Titanium` 是否必须、名字是否正好这么写，**未验证**（参数本身存在，`gui.py:4289-4291`）。
3. VIO `Value` 改完是否需要额外点 `Apply/Update` 才落到 FPGA，**未验证**。
4. 烧录与 Debugger 同时开时的具体报错文案，**未验证**；"必须串行"按架构与代码判断。
5. 按钮/菜单的**中文界面文案**未核对（本文用 `.py` 里的英文原文：`Import Profile` / `Configure` / `Unconfig` / `USB Target`）；装了中文语言包时文字可能不同，按位置找。
6. 本文档**没有上板、没有烧录、没有构建**，纯静态调研。

---

## 附：一页速查卡（打印/截图用）

```
【启动】
D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat --project_home "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2" --profile_file "...\v7_work2\debug.json"

【导入】Profile 页 → Import Profile → v7_work2\debug.json
        （不要用 debug_profile.wizard.json；更不要用 out\debug_profile.mark_debug.json）

【连接】Debug 页 → USB Target 选 FT4232H → USER1 → Configure
        （没有 Board Profile 下拉框；那是烧录器那边的档）

【改增益】vio0 表：Radix 选 Hex，Value 填裸十六进制（不写 0x！）
        r_gain = 118  (280  = 1.094×)
        g_gain = ff   (255  = 0.996×)
        b_gain = 15e  (350  = 1.367×)
        基准   = 100  (256  = 1.000×)
        想用十进制：Radix 选 Dec，填 280 / 255 / 350

【纪律】烧录前先关 Debugger；换位流时 Unconfig → 关 Debugger → 再烧。
        每次重灌/重配置，VIO 回到 118 / ff / 15e。
        必须有像素时钟在跑（HDMI 有输出），VIO 写入才会生效。
```

## 附：本文引用的关键文件

| 文件 | 用途 |
|---|---|
| `D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat` | Debugger GUI 启动器（唯一 Windows 入口） |
| `...\debugger\bin\efx_dbg\gui.py` | GUI 主逻辑（参数 / profile 导入 / VIO 表格） |
| `...\debugger\bin\efx_dbg\widgets.py` | `HexLineEdit` 进制与校验（决定能不能填 `0x`） |
| `...\debugger\bin\efx_dbg\openocd_cfg\ftdi_template.cfg` | Debugger 的 FTDI/JTAG 模板 |
| `D:\Efinity\2026.1\pgm\bin\efx_pgm\efx_hw_common\boards\generic_ft4232h.json` | 烧录器侧的 FT4232H 板档 |
| `...\v7_work2\debug.json` | **要加载的 debug profile**（vio0 + la0，UUID 与网表一致） |
| `...\v7_work2\debug_profile.wizard.json` | 旧 Wizard 会话（无 vio0、la0 UUID 不同、USER2），**不要用** |
| `...\v7_work2\out\debug_profile.mark_debug.json` | 空草稿（无 `debug_cores`），**加载会报错** |
| `...\v7_work2\debug_top.v` | VIO/LA 例化与 `INIT_VAL`（94-105 行）、UUID（97 / 260 行） |
| `...\v7_work2\rtl\ti60f225_oob_top.v` | 顶层例化 `debug_edb_top`（1033 行）、增益接线（783 行）、`gamma_sel`（1006-1011 行） |
| `...\v7_work2\rtl\debayer\rgb_gain_v1.v` | Q8.8 定点与饱和实现 |
| `...\v7_work2\out\ti60f225_oob.route.rpt` | 旁证：PnR 结果里有 `debug_edb_top_inst` |
