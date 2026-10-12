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
| Synthesis | 成功，约 3 分钟；占用约 **4.5 万 / 6.08 万**逻辑单元 |
| Place & Route | 成功，约 3 分钟；占用 **222 / 256** 块 RAM、**27 / 160** 个乘法器 |
| Bitstream | 成功，产出 `out/mmt.hex`（约 **2.8 MB 的文本文件**，实际烧录数据约 **0.92 MB**） |

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

### 5.2 用 Efinity Programmer 烧（图形界面）

1. 开始菜单打开 **Efinity Programmer**（或在 Efinity 里 Tools → Programmer）。
2. 选择器件：**Ti60F225**。
3. 选择模式：第一次用 **JTAG**。
4. 选择文件：`D:\FPGA\mmt\out\mmt.hex`。
5. 点 **Start**，等进度条走完。
6. **预期**：板子上电后 LED 有心跳闪烁；串口（115200）能看到 RISC-V 打印。

### 5.3 把"程序 + AI 模型"也烧进 flash（正式演示用）

固件和 AI 模型打包成一个**用户镜像**，放在 flash 的 **0x380000** 偏移处（由片内的一小段搬运程序负责搬进 DDR 运行）。我们已经准备好**合成好的单文件**，烧一次就行：

**方案 A（推荐）**：用合成文件
```
D:\FPGA\mmt\sw\ddr\build\flash_combined.hex
```
在 Programmer 里选 **SPI Active** 模式，把这个文件烧进去即可（它已包含"位流 @0x0 + 用户镜像 @0x380000"两部分）。

**方案 B**：分两次烧（厂商 readme 的原始做法）
1. 位流 `out/mmt.hex` → 地址 **0x0**
2. 用户镜像 `sw/ddr/ddr_image.bin` → 地址 **0x380000**

**校验**：自检脚本会解码位流、检查两者有没有重叠/越界：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\FPGA\mmt\sw\ddr\verify_flash_layout.ps1"
```
（实测：位流 0x0–0xEA59C、镜像 0x380000–0x3CA68B、不重叠不越界、8MB flash 还剩 4.3MB。）

> ⚠️ **以上烧录步骤我们还没在真板上跑过**（写这份文档时板子刚到）。第一次请**先按 5.1/5.2 的 JTAG 模式试**，把现象记下来；有偏差记下报错原文。

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

1. **⚠️ 摄像头画面目前进不了内存**（正在排查）
   这条通路在综合时被工具整段当成"没用"删掉了。现象：屏幕一直显示内存里的残留画面、**不随摄像头变化**。已用 5 个实验确认"改输入 / 改时钟 / 加保留标记"都无效，最可能是 **Efinity 2026.1 对这个厂商模块的误优化**。进展见 `docs/帧缓冲写通路根因*.md`。
   → 板子到了之后，**第 6 节第 6 步大概会卡在这里**，属于已知问题，不是你接错线。
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
| 综合 / 布局布线 | 都通过（约 3 + 3 分钟） |
| 逻辑单元 | 45,541 / 60,800（74.9%） |
| 块 RAM | 222 / 256（86.7%） |
| 乘法器 | 27 / 160 |
| 时序 | **全部满足**（最差余量 +0.394 ns，在 DDR3 高速侧；我们自己 100MHz 侧余量 +3.3 ns） |
| 未分配引脚 | **0** |
| 仿真回归 | 84 项全过 |
| 烧录文件 | 已生成，约 0.92 MB |
| flash 占用 | 位流 + 用户镜像共约 1.2 MB（8 MB flash 余量充足） |

---

## 11. 许可证与引用

- 本仓库只包含**我们自己写的**代码与文档。
- 未包含 Efinix 的 IP、厂商 Demo RTL 与加密文件（属授权材料，见第 0 节）。
- 对外引用/提交时请遵守竞赛与厂商的授权约定。
