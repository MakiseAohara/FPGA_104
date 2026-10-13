# FPGA_104 —— 2026 全国大学生嵌入式芯片与系统设计竞赛

**FPGA 创新设计赛道 · 易灵思（Efinix）企业赛道 · 赛题三「多模态 AI 智能终端」**

> 这份 README 是给**没用过 Efinity 的人**写的：从打开工程到烧进板子，照着做即可。
> 每一步都写了"你应该看到什么"，看到的不一样就停下来查第 9 节。

---

## 0. 先读这一条：这个仓库**不能直接编译**

| | 内容 |
|---|---|
| **仓库里有的** | 我们自己写的代码：`rtl/mmt/`（顶层与各子系统）、`sw/`（RISC-V 固件）、`sim/`（仿真）、`constr/`（时序约束）、`tools/`、工程描述文件 `mmt.xml` / `mmt.peri.xml` |
| **仓库里没有的** | **厂商 IP**（`ip/` 目录：SoC、AXI 互联、CSI 摄像头接收、TinyML 加速器）与**厂商 Demo 的 RTL**（DDR3 控制器、HDMI 编码、摄像头 I2C、debayer、帧缓冲等） |

原因：这些是 Efinix 的授权材料，不适合放公开仓库（详见第 11 节）。

**所以：想真正编译，请用队友手里的完整工程目录**（就是 `D:\FPGA\mmt` 整个目录），或者按第 2 节把厂商文件补回来。

---

## 1. 你需要准备什么

| 需要 | 版本 / 说明 | 从哪拿 |
|---|---|---|
| **Efinity** | **2026.1**（我们实际用的是 2026.1.132） | elitestek 官网，免费下载 |
| Efinity License | 免费申请，装完按向导导入 | 同上 |
| **开发板** | Efinix **Ti60F225I3-V4** DemoBoard | 淘宝「娅妮电子」（竞赛官方渠道） |
| 下载器 | **不需要**！板载 FT4232HL，"客户无需外接下载器" | — |
| 电源 | **不需要**！一根 **Type-C** 线同时供电 + 下载 + 串口 | — |
| RISC-V 工具链 | Efinity 自带（`riscv-none-elf-gcc 15.2.0`），不用另装 | Efinity 安装目录下 |
| 显示器 | 带 **HDMI 输入**（我们走 HDMI 输出，不用 MIPI 屏） | 自备 |
| 串口终端 | 任意（PuTTY / MobaXterm / VSCode 串口插件），**115200 8N1** | — |

传感器（温湿度 SHT30、红外 MLX90640）、蜂鸣器、QSE 转 2.54 排针子卡、杜邦线：**按需再买**。

---

## 2. 把工程凑齐（含厂商 IP）

任选一条：

1. **最省事**：从队友那里拷**整个 `mmt` 目录**（含 `ip/` 和厂商 RTL），跳过本节。
2. **从官方资料包补**：用 Ti60F225 DemoBoard 资料包 + MIPI CSI/DSI IP 包，把缺失文件放回 `ip/` 与 `rtl/` 对应位置（缺哪些见 `docs/` 里的说明）。
3. **自己用 Efinity 重新生成 IP**：Sapphire SoC / AXI Interconnect / CSI RX Controller 都有图形化生成器，参数记录在 `docs/` 里。

> ⚠️ **别乱换 IP 版本**：我们用的是 **CSI RX IP 5.15**（Efinity 2026.1 生成）。厂商 Demo 里那份是 5.6，两者行为不同（我们正在排查的一个问题与此有关）。换版本前先看 `docs/帧缓冲写通路根因-3.md`。

---

## 3. 在 Efinity 里打开工程（图形界面）

1. 启动 **Efinity**。
2. 菜单 **File → Open Project**，选 **`mmt.xml`**。
   - ⚠️ 选 **`mmt.xml`**，**不是** `mmt.peri.xml`（后者只是引脚配置）。
3. 左侧出现 design files 列表，说明打开成功。
   - 如果弹出 "missing file / IP out of date" 之类的警告 → 说明厂商 IP 没放齐，回第 2 节。
4. 上方是**流程按钮**，我们的顺序是：

```
Synthesis（综合） → Interface Designer（引脚） → Place & Route（布局布线） → Bitstream（生成烧录文件）
```

**每一步的预期结果**（我们实测的数字，供你对照）：

| 步骤 | 预期 |
|---|---|
| Synthesis | 成功，约 4 分钟；占用约 **4.3 万 / 6.08 万**逻辑单元 |
| Place & Route | 成功，约 5 分钟；占用 **235 / 256** 块 RAM、**24 / 160** 个乘法器 |
| Bitstream | 成功，产出 `out/mmt.hex`（约 **2.8 MB 的文本文件**，实际烧录数据约 **955 KB**） |

> ⚠️ **Interface Designer 有一个已知坑**：`mmt.peri.xml` 里带着厂商 Demo 遗留的 5 条 **DSI 屏**引脚（`mipi_dp_clk_RST` 等）。我们已经删掉了 DSI 屏电路，所以这 5 条必须去掉，否则 PnR 会报错：
> `ERROR : Required pin mipi_dp_clk_RST is not found`
> **命令行流程会自动帮你去掉**（见下节）；用图形界面的话，在 Interface Designer 里手动删掉这 5 条。

---

## 4. 命令行编译（推荐，我们一直用这条）

比点按钮更省事、结果可复现。**一条命令走完四步**（综合 → Interface Designer → 自动清理陈旧引脚 → 带引脚约束的布局布线）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\FPGA\易灵思\工作区\06_Efinity验证\run_full_flow.ps1"
```

跑完会打印占用情况，以及**未分配引脚列表 —— 正常情况下应该是 `none`**（应为 0 个）。

**额外生成烧录文件**（`out/mmt.hex`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\FPGA\易灵思\工作区\06_Efinity验证\build.ps1" `
  -Xml "D:\FPGA\mmt\mmt.xml" -Top "mmt_top" -Name "mmt" -Bitstream
```

**只跑仿真回归**（84 项检查，不需要板子）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\FPGA\mmt\sim\run_all.ps1"
```

三条脚本的作用：

| 脚本 | 作用 |
|---|---|
| `run_full_flow.ps1` | 完整编译：综合 → 引脚 → 清理 → 布局布线 |
| `build.ps1` | 综合 + 布局布线（可选 `-Bitstream` 出烧录文件、`-SkipSyn` 跳过综合） |
| `filter_interface.ps1` | 被上面两个自动调用：删掉 peri 里陈旧/冲突的引脚 |

---

## 5. 烧到板子上

### 5.1 两种模式（先搞清楚区别）

| 模式 | 效果 | 什么时候用 |
|---|---|---|
| **JTAG** | 烧到芯片内部 SRAM，**掉电就没了** | **第一次 bring-up 用这个**：快、不写 flash，改一版试一版 |
| **SPI Active** | 烧到板上 flash，**掉电保留**，上电自动加载 | 稳定之后、给评委演示时用 |

### 5.2 ⚠️ 前置条件（四条缺一不可 —— 2026-10-12 实测踩全了）

#### 5.2.1 FTDI 驱动版本必须**统一**（否则蓝屏 `0x000000FC`）
板载 FT4232H 有"总线"和"串口"两条通道。若 Windows 给它们装了**不同年代**的驱动（本例：`ftdibus` 2024 版 vs `ftdiport` 只有 2017 版），一访问 FTDI 就 **BSOD 0x000000FC**（我们实测撞了两次）。
**修法**：删掉全部旧包，只装 FTDI 官网 CDM 包（它同时含 `ftdibus.inf` + `ftdiport.inf`，同版本）：
```
pnputil /delete-driver oem114.inf /uninstall
pnputil /delete-driver oem118.inf /uninstall
pnputil /delete-driver oem119.inf /uninstall
pnputil /add-driver D:\FTDI\ftdibus.inf  /install      # CDM-v2.12.36.4-WHQL-Certified
pnputil /add-driver D:\FTDI\ftdiport.inf /install
```
判据：`USB Serial Converter A/B/C/D` 与 `USB Serial Port COMxx` 的驱动版本**都是 2.12.36.4**。
> 同类问题参考：<https://bigpig.ongridea.com/gha5jb>

#### 5.2.2 必须打开 `EFX_HIFTDI_ENABLE=1`
Efinity 默认只用 pyftdi(libusb) 后端，而板载 FT4232H 挂在 FTDI 驱动上 ⇒ 报 `No backend available` / `No Board Profile Selected`。
**D2XX 后端藏在开关后面**（源码依据 `pgm\bin\efx_pgm\usb_resolver.py:712`）：
```powershell
$env:EFX_HIFTDI_ENABLE = "1"
```
打开后能枚举到 `Usb Target: Quad RS232-HS, ID: 0403:6011` + `hiftdi://0x0403:0x6011/0..3`（**index 1 = JTAG**）。

#### 5.2.3 必须给 `efx_dbg\jcf.py` 打补丁（Efinity 自身 bug）
症状：D2XX 后端下**任何**模式（连只读 `read_flash`）都在 TAP 检测处抛
`TypeError: JtagEngine.configure() takes 2 positional arguments but 3 were given`（`efx_dbg\jcf.py:795`）。
原因：hiftdi 的底层 JTAG 引擎 `configure()` 只收 `(url)`，调用方无条件多传了 `init`。
**补丁**（两处 `else:` 分支；原文件先备份）：
```python
        else:
            try:
                _np = len(__import__('inspect').signature(
                    self._engine_provider.configure).parameters)
            except Exception:
                _np = 2
            if _np >= 2:
                self._engine_provider.configure(url, init)
            else:
                self._engine_provider.configure(url)
```
补完自检：`python -m py_compile jcf.py` → 退出码 0。

#### 5.2.4 必须指定板级 profile
`-b "Generic Board Profile Using FT4232H"`（对应 `pgm\bin\efx_pgm\efx_hw_common\boards\generic_ft4232h.json`；VID 0x0403 / PID 0x6011）。该 profile 定义 **通道 A = SPI、通道 B = JTAG（TCK/TDI/TDO/TMS）**。

---

### 5.3 实测可用的烧录命令（命令行，推荐）

```powershell
$efi = "D:\Efinity\2026.1"
$env:EFINITY_HOME = ($efi -replace '\\','/')
$env:EFINITY_USER_DIR = "C:/Users/<你>/.efinity"
$env:EFINITY_USER_DIR_INI = "$env:LOCALAPPDATA\efinity\user_dir.ini"
$env:EFXPGM_HOME="$efi\pgm"; $env:EFXDBG_HOME="$efi\debugger"; $env:EFXSVF_HOME="$efi\debugger\svf_player"
$env:PYTHONHOME="$efi\python311"; $env:PYTHONNOUSERSITE="1"
$env:PYTHONPATH="$efi\pgm\bin;$efi\debugger\bin"
$env:PATH="$efi\bin;$efi\python311\bin;$efi\scripts;"+$env:PATH
$env:EFX_HIFTDI_ENABLE = "1"

# JTAG 烧 SRAM（掉电即失）—— 注意必须是 .bit，传 .hex 会报格式错
& "$efi\bin\python3.bat" "$efi\pgm\bin\efx_pgm\ftdi_program.py" `
  "D:\FPGA\mmt\out\mmt.bit" -m jtag -b "Generic Board Profile Using FT4232H"
```

**成功判据（实测输出）**：
```
Connecting to JTAG_TAP: efx_ti
jtag programming started!
Programming 'D:\FPGA\mmt\out\mmt.bit' via JTAG at freq 6.0 MHz
Device ID read from JTAG: 0x10660A79          ← Ti60F225
... finished with JTAG programming
```

### 5.4 图形界面烧录
Efinity Programmer 与命令行**用同一套后端**，所以 5.2 的四条前置条件同样必须满足（否则只会看到 `No Board Profile Selected`）。GUI 里同样是 器件 Ti60F225 → 模式 JTAG → 文件 `.bit`。

### 5.5 串口与判据（不带屏幕也能判断设计活着）

- **端口：`COM19`**（115200 8N1；实测 COM17/18/20 无数据）
- **预期输出**（当前版本遥测）：
```
T=0.0C RH=0.0% IR=0.0C score=0.0
ALM=0 AUTH=0 EVT=0 ST=0x00000000 thr=154 hr=0 auth22-6
[WR] AW=0(d=0) W=0(d=0) st=0x00 FRM=367(d=11) [FS] raw=0x00000000 vis_bit=0x00 ... [VW] vis=0x00
[CAM] SCL=..(d=..) CK=..(d=..) PCLK=..(d=..) DE=..(d=..) HS=..(d=..) VS=..(d=..) st=0x.... wc=..(d=..) link=0x........
```
- **怎么读**：`[WR]` 的 `AW/W` 是**写通路握手累计数**（必须持续增长）；`[CAM]` 每个 `d=` 分别是 I2C / 字节时钟 / 像素时钟 / `de/hs/vs` 的**增量**（哪个恒 0 就是哪一段没动）；`link` 低 4 位非 0 = 探针确实进了这版位流。
- LED：不报警时 `led[0]` 闪（≈1.5Hz）= **DDR3 校准完成**；报警时两灯同相 2Hz。靠近 USB 口那个不规则闪的是 FT4232 串口活动灯，**忽略**。

### 5.6 ⚠️ 改了固件必须重新"装进 SoC"，否则烧的还是旧固件

固件不是靠 flash 里的文件生效，而是**烧进 SoC 的片内 RAM 初始化**（4 个 `$readmemb` symbol 文件）。改了 `sw\` 之后**必须**：
```powershell
powershell -File D:\FPGA\mmt\sw\build_sw.ps1            # 编译固件
powershell -File D:\FPGA\mmt\sw\hex2soc.ps1 -Install    # 转 4 个 RAM init 文件并装进 IP
```
再重编位流。`hex2soc.ps1` 会打印 `round-trip verify : OK`。**不跑这一步，板上跑的还是上一版固件**（这个坑我们踩过）。

### 5.7 flash 持久化烧录：暂未打通（现状与原因）

| 方式 | 结果 | 原因 |
|---|---|---|
| `-m jtag`（SRAM） | ✅ **通** | JTAG 直配 |
| `-m active`（直连 SPI 通道 A） | ❌ `Unknown error trying to read flash device` | 板子的 flash 不直连 FT4232 通道 A（该 profile 的 SPI 引脚映射对不上）|
| `-m jtag_bridge`（厂商默认的 flash 编程） | ❌ `NotImplementedError`（`efx_hw_common\manager.py:269`）| **hiftdi(D2XX) 后端未实现** JTAG Bridge |

**下一步方案**：用 Zadig 把 FT4232H 的 **JTAG 通道（通道 B / interface 1）绑成 libusbK/WinUSB**，改用 Efinity 默认的 pyftdi(libusb) 后端（此时**不要**设 `EFX_HIFTDI_ENABLE`），再试 `-m active` / `-m jtag_bridge`。这是厂商文档《炫览下载器说明及驱动安装》方法一描述的官方路径；属换驱动操作，动手前先建系统还原点。
**在此之前**：上板验证走 5.3 的 SRAM 烧录（每次上电后烧一次，约 20 秒）。

### 5.8 用户镜像（程序 + AI 模型）放着不动
用户镜像仍按原约定放 flash **0x380000**，布局自检：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\FPGA\mmt\sw\ddr\verify_flash_layout.ps1"
```
（实测：位流 0x0–0xE9380、镜像 0x380000–0x3CA68B、不重叠不越界、8MB flash 余 4.3MB；PASS 24 / FAIL 0 / WARN 2。）
> 合并单文件的工具 `multi_image_merger.py` 读我们的位流会报 `incorrectly formatted HEX file`（位流头有 9 行是"2 字节挤一行"，路径中文被转义），所以走**分两次烧**，或等 5.7 打通后再说。

---

## 6. 上板 bring-up 检查清单（按顺序做，出问题好定位）

**每一步先看"预期现象"，不对就停在那一步排查，不要往下走。**

| # | 做什么 | 预期现象 | 不对时先查 |
|---|---|---|---|
| 1 | 插 Type-C 线 | 板子上电、电脑识别出串口 | 换根线 / 换 USB 口 |
| 2 | 用 **JTAG** 模式烧位流 | Programmer 进度 100% | 器件型号是否选 Ti60F225 |
| 3 | 看 LED | 一个灯在闪（心跳） | 时钟没起来 / 复位没释放 |
| 4 | 打开串口 115200 | 看到 RISC-V 打印信息 | 串口脚分配（第 7 节第 4 条） |
| 5 | 接 HDMI 显示器 | 屏幕出画面（带 OSD 叠加） | HDMI 线 / 显示器输入源 |
| 6 | 接摄像头（22-pin FPC，插 **sensor** 那个座） | 屏幕出现摄像头画面 | 见第 7 节第 1 条（**已知问题**） |
| 7 | 接温湿度 / 红外传感器（I2C） | 串口打印温湿度、热成像数据 | 引脚是我们自选的，照 `mmt.peri.xml` 接 |
| 8 | 触发报警条件 | 蜂鸣器响 + LED 闪 | 蜂鸣器要**有源 3.3V** |

**目前没买的**（不影响第 1–6 步）：温湿度、红外、蜂鸣器、QSE 转接子卡、杜邦线。

---

## 7. 已知问题（重要，先看再动手）

1. **摄像头画面曾进不了内存（已用变通办法绕过，待上板验证）**
   帧缓冲的写通路在综合时被工具整段当成"没用"删掉了（写 FIFO 的 13 块 RAM 一块都没推断）。已用 8 个实验定位：给写通道的**输出寄存器**加 `(* preserve, syn_keep = 1 *)` 可让写通路复活（`ddr_wr_buffer.v` 的 `awvalid`/`wvalid`/`state`/`wr_req`）。
   - 代价：写 FIFO（13 块）+ CSI 摄像头接收（32 块）一起回来了，RAM 从 222 涨到 **263 > 256 装不下**，所以同时做了两处削减：`RD_FIFO_DEPTH 1024→512`（−6）、**暂时关掉 TinyML 片上缓存**（−22）→ **235/256**。
   - 副作用：AI 推理变慢（权重每次从 DDR 读）。后续用"SoC 片内 RAM 32KB→16KB"（−16）换回来后可以把缓存重新打开。
   - 现象与判据见 `rtl/frame_buffer/ddr_wr_buffer.v` 里的注释；上板若屏幕**不随摄像头变化**即为该问题复发。
2. **视频复位已修但要知道**：删掉 DSI 屏电路后，一段"等屏幕初始化完成"的逻辑会永远等不到 → 视频部分永远不出复位。**已修**（见 `rtl/mmt/mmt_top.v` 里 `dly_cnt` 的注释）。不修的话 HDMI 就是黑屏。
3. **RAM 余量只剩 13%**：256 块内存用了 222 块。再加功能可能装不下。削减方案见 `docs/BRAM资源优化方案.md`。
4. **引脚是我们自己选的**：UART、蜂鸣器、传感器 I2C 这几路，板子上**没有现成网络**，脚位是按空闲 3.3V IO 选的（记在 `mmt.peri.xml`）。上板接线要照它接，不能随便换。
   - SPI flash 那 4 根（M1/L1/N1/P1）是**板子固定的配置脚**，不用动。
5. **摄像头 FPC 排线**：板子上有两个 22-pin FPC 座（一个屏、一个摄像头），**别插错**。

---

## 8. 目录说明

| 路径 | 里面是什么 |
|---|---|
| `rtl/mmt/` | **我们写的 RTL**：顶层 `mmt_top.v`、SoC 封装、跨时钟同步器、I2C 主机、OSD 叠加、报警控制等 |
| `sw/` | RISC-V 固件（C + 汇编 + 链接脚本 + 编译/装载脚本） |
| `sw/ddr/` | "程序 + AI 模型放进 DDR 运行"的搬运程序、打包脚本、flash 布局校验脚本 |
| `sim/` | 仿真：传感器回归 84 项 + 三主口内存访问仿真（`sim/axi_ic/`） |
| `constr/` | 时序约束（SDC） |
| `tools/` | 辅助脚本（IP 重生成、固件打包等） |
| `mmt.xml` | **Efinity 工程文件（打开这个）** |
| `mmt.peri.xml` | 引脚配置文件（由 Interface Designer 使用） |

---

## 9. 编译报错怎么办（按报错原文查）

| 报错关键词 | 原因 | 处理 |
|---|---|---|
| `Required pin mipi_dp_clk_RST is not found` | peri 里 5 条 DSI 屏遗留引脚 | 用 `run_full_flow.ps1`（自动清理），或手动删 |
| `cannot open Verilog file 'ip/...'` | 厂商 IP 没放齐 | 回第 2 节 |
| `instantiating unknown module` | 缺文件（我们踩过：TinyML 需要厂商 `axi_interconnect_beta` 那 11 个文件） | 看 `docs/路线B-TinyML接入进度与已知问题.md` |
| `Unassigned Core Pins` 不为 0 | 引脚没分配 | 看 `docs/引脚分配补齐.md` |
| `Slack` 出现负值 | 时序没过 | 看 `docs/时序与CDC问题分析.md` |
| `unrecognised option '--work_dir'` | 位流命令参数写法不对 | 用 `build.ps1 -Bitstream`（已修正） |

---

## 10. 已经实测过的数据（Efinity 2026.1.132 / Ti60F225I3）

| 项 | 结果 |
|---|---|
| 综合 / 布局布线 | 都通过（约 4 + 5 分钟） |
| 逻辑单元 | 43,007 / 60,800（70.7%） |
| 块 RAM | 235 / 256（91.8%） |
| 乘法器 | 24 / 160 |
| 时序 | **全部满足**（最差余量 +0.394 ns，在 DDR3 高速侧；我们自己 100MHz 侧余量 +3.3 ns） |
| 未分配引脚 | **0** |
| 仿真回归 | 84 项全过 |
| 烧录文件 | 已生成，约 955 KB |
| flash 占用 | 位流 + 用户镜像共约 1.26 MB（8 MB flash 余量充足） |

---

## 11. 许可证与引用

- 本仓库只包含**我们自己写的**代码与文档。
- 未包含 Efinix 的 IP、厂商 Demo RTL 与加密文件（属授权材料，见第 0 节）。
- 对外引用/提交时请遵守竞赛与厂商的授权约定。

---

## 10. 我们改过的厂商 RTL（本仓库不含厂商源码，这里是补丁清单）

> 仓库只放**我们自研**的代码（`rtl/mmt/`、`sw/`、`sim/`、`constr/`、`tools/`），
> 厂商 IP 与厂商 demo RTL **不入库**。所以下面这些**对厂商源码的改动**请在本机维护，
> 换机器/重取厂商源码后必须照此重新打上，否则会出现"编译看着正常、行为却不对"的问题。

| # | 文件 | 改动 | 为什么（实测依据） |
|---|---|---|---|
| 1 | `rtl/frame_buffer/frame_buffer.v` | 例化 `ddr_buffer` 时补 `.FB_NUM(FB_NUM) .MAX_VID_WIDTH(MAX_VID_WIDTH) .MAX_VID_HIGHT(MAX_VID_HIGHT)` | 原样漏转发 ⇒ 用 1920×1080 默认值算帧步长（`0x7E9200`，应为 960 版 `0x3F4A00`）⇒ 三个 bank 基址错成 `0x02000000/0x027E9200/0x02FD2400`，**bank2 会覆盖 TinyML 张量区前 1.8MB**。详见 `docs/帧步长修复-DDR分区对齐.md` |
| 2 | `rtl/frame_buffer/ddr_wr_buffer.v` | 给 `awvalid`、`wvalid`、`state`、`wr_req` 加 `(* preserve, syn_keep = 1 *)` | Efinity 2026.1.132 会把写 FSM 整条**静默折成常量**（`optimized to 0`、写 FIFO 的 13 块 BRAM 消失）。9 个绕法实验全部无效，只有这个属性有效。最小复现件见 `工作区\08_Efinix复现件\`（`run_map.ps1 -Variant S2` 复现 / `-Variant S2C` 修复） |
| 3 | `rtl/frame_buffer/DC_FIFO.v:787` | （**建议，尚未改**）`always @(GrayIn)` → `always @(*)` | 敏感表不全：iverilog 下计数器停 X ⇒ **仿真里一个 AW 都不会有**（综合忽略敏感表，硬件无影响）。改了可消除仿真/综合不一致 |
| 4 | `rtl/frame_buffer/frame_info_det.v:93` | （**建议，尚未改**）把 1 位的 `frame_end_r0` 赋给 24 位的 `frame_len_d0`，疑为 `frame_cnt` 笔误 | 使"连续 3 帧等长"判据**恒真**（负对照实测：帧长不一致也照样写）。**先别改**：改严后若相机帧长有抖动，可能反而永不触发写通路 |

> 自研部分的关键修复（在库内可见）：显示通路 R/B 交叉（`rtl/mmt/mmt_top.v`，全屏紫的根因）、
> 视频复位去掉 `w_confdone` 门控、`RD_FIFO_DEPTH` 512、心跳 1.5Hz、摄像头 I2C SCL 探针改接 `io_cam_scl_OE`。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/如何运行.md](docs/如何运行.md) | **从零到板子跑起来**：编译两步、仿真、烧录四前提与判据、串口判读、寄存器表、上板顺序、9 条判读避坑 |
| [docs/代码学习地图.md](docs/代码学习地图.md) | **从大到小读懂整个设计**：三条数据通路、顶层阅读法、各子系统、软件层、寄存器表、阅读顺序与常见坑 |
