# 赛题三「多模态AI智能终端」—— 工程骨架

> 建立时间：2026-09-20　|　工具：Efinity 2026.1.132（`D:\Efinity\2026.1`）
> 器件：Titanium **Ti60F225**（225-ball FBGA），定时模型 I3，总容量 **60,800 XLR / 256 BRAM / 160 DSP**

---

## 〇、从这里开始（给接手的人）

### 这是什么

2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 易灵思企业赛道，**赛题三「多模态 AI 智能终端」**。
硬件是 **Ti60F225** 开发板（Elitestek/易灵思 Ti60F225I3-V4），外挂一个 SC431HAI 摄像头（MIPI CSI-2）
和 SHT30 温湿度、MLX90640 红外阵列两个 I2C 传感器，输出到 HDMI。

**当前形态**：一条完整的「摄像头 → MIPI CSI-2 → 去马赛克 → DDR3 帧缓存 → 缩放 → 叠加 OSD → HDMI」图像链路，
加上自己写的 I2C 分时复用控制器（带 SHT30 / MLX90640 驱动）、帧差法运动检测、
60/25/15 加权融合决策、报警（LED + 蜂鸣器），以及一颗 **Sapphire RISC-V 软核**跑决策固件。

### 需要装什么

| 工具 | 位置（本机现状） | 用途 |
|---|---|---|
| Efinity 2026.1 | `D:\Efinity\2026.1` | 综合 / 布局布线 / IDE |
| iverilog 11.0 | `D:\iverilog`（micromamba 装的） | RTL 仿真 |
| xpack riscv-none-elf-gcc 15.2 | `D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1` | 编 RISC-V 固件 |
| Python 3.11+ | 系统自带 | 跑校验脚本 |

iverilog 的 PATH 要同时有 `D:\iverilog\Library\bin` 和 `D:\iverilog\Library\mingw-w64\bin`，少一条会报含糊的 DLL 错误。

### 三条命令

```powershell
# 1) RTL 仿真回归（4 个 testbench，84 项检查）
cd D:\FPGA\mmt ; powershell -File sim\run_all.ps1

# 2) 综合 + 布局布线（含引脚约束）
powershell -File 工作区\06_Efinity验证\run_full_flow.ps1     # 注意路径在 D:\FPGA\易灵思\ 下

# 3) 编 RISC-V 固件，并装进 SoC 的片内 RAM
cd sw ; powershell -File build_sw.ps1 ; powershell -File hex2soc.ps1 -Install
```

另有裸机固件的**指令级仿真**（没有板子也能真正跑固件）：
```powershell
cd sw ; powershell -File run_rv32_tests.ps1
```

### 目录

```
mmt\
├── mmt.xml            主工程（Efinity 用；顶层 mmt_top）
├── mmt.peri.xml       引脚约束（Interface Designer 的状态文件）
├── open_project.cmd   双击这个用 IDE 打开工程
├── constr\            .sdc 时序约束 + 厂商原始的 peri/interface
├── rtl\               RTL。厂商复用的在子目录里，我们新写的全在 rtl\mmt\
│   └── mmt\           sensors\ algo\ osd\ alarm\ soc\ video\ common\
├── ip\                csi_rx_controller（MIPI CSI-2 RX）+ sapphire_soc（RISC-V）
├── sw\                RISC-V 固件 + 裸机测试 + 外部库（Melexis MLX90640）
├── sim\               iverilog 测试平台 + 一键回归
├── _hist\             开发过程中建过的几个子工程 XML（留档，不参与构建）
└── README.md          本文件
```

### 现在做到哪了 / 还差什么

**已验证**（不是"能编译"，是有实测数据）：
- RTL 仿真 **84 项检查全绿**（I2C 主机 39 / hub 9 / SHT30 15 / MLX90640 21）
- 综合 + 布局布线通过：**20,833 XLR / 60,800（34.26%）**、140 / 256 BRAM、12 / 160 DSP
- 固件编译通过并已装进 SoC 片内 RAM；软硬件地址全部按生成网表核实过
- 厂商 Melexis MLX90640 库**在 RISC-V 上真跑通**，27 项参数与独立 Python 重算逐位一致
- 引脚约束打通，只剩 8 个新增引脚待定（板子上 J7 扩展口的 3.3V 脚）

**还没做**：
- **没上过板子**（板子未到），所有结论都止于仿真/综合层面
- TinyML 加速器：已取得官方平台并确认资源装得下，但 RTL 还没接进设计
- 逐点温度换算还没进固件（库已验证可跑）

细节和踩过的坑都写在 `D:\FPGA\易灵思\协作日志.md`（约 1900 行），以及本文件下半部分。

---

## 一、这个工程从哪来

底子取**板卡包 10 号 demo**（`10_Ti60f225_sc431hai2hdmi_demo`）——它是厂商已实测跑通的
「SC431HAI 摄像头 → MIPI CSI-2 → DDR3 帧缓存 → HDMI 输出」链路，**干净构建实测 16,830 XLR / 138 BRAM**（2026.1 复现，见 `协作日志.md`）。

我们不重造这条链路，只做两件事：
1. **嫁接** Sapphire RISC-V 软核 + TinyML 加速器（从 08 号 soc demo / 官方 TinyML 平台来）
2. **新增** 多传感器、算法、OSD、报警这些赛题要求的模块

---

## 二、目录结构

```
mmt\
├── rtl\                       复用的 66 个源文件（来自 10 号 demo，路径与内容原样未改）
│   ├── ti60f225_oob_top.v     ★ 原顶层（34 KB 单体），最终会被 mmt\mmt_top.v 取代
│   ├── ddr3_controller\       DDR3 控制器（AXI4 接口）
│   ├── frame_buffer\          三缓冲帧缓存 + DDR 读写缓冲
│   ├── debayer\               RAW → RGB
│   ├── cam_i2c_ctrl\          摄像头 I2C 寄存器配置（含 i2c_master）
│   ├── dvi_tx\                HDMI TMDS 编码（dvi_encoder）
│   ├── mipi_config\           MIPI 屏参数
│   └── mmt\                   ★★ 【我们新写】
│       ├── sensors\           MLX90640 / SHT30 驱动 + I2C 分时复用控制器
│       ├── algo\              帧差法运动检测、60/25/15 融合决策
│       ├── osd\               显示叠加（热力图小窗 + 环境参数文字 + 报警红框）
│       └── alarm\             LED 闪烁 + 蜂鸣器
├── ip\
│   ├── csi_rx_controller\     MIPI CSI-2 RX IP（复用）
│   └── sapphire_soc\          Sapphire RISC-V 软核（efx_soc 3.4.0，已开 CustomInstruction、片内 RAM 32KB）
├── constr\                    ti60f225_oob.sdc（时序）+ 厂商原始 peri/interface
├── sw\                        RISC-V 固件（融合决策 + 外设驱动）+ 裸机测试 + Melexis 库
├── sim\                       iverilog 测试平台 + 一键回归 run_all.ps1
├── _hist\                     开发中建过的几个子工程 XML（留档，不参与构建）
└── out\ work_syn\ work_pnr\   构建产物（可再生，已从交付包里清掉）
```

**源文件清单的来源**：`rtl\` 下 66 个厂商文件是从原工程 XML 的 `<efx:design_file>` 列表精确提取的，**不是整目录拷贝**——原 `rtl\` 目录 193 MB 里有 36 个属于其他 demo 的死代码 + 大量仿真波形垃圾（`wlf*`/`vcd`），实际有效源码只有 1.4 MB。

> `ip\dsi_tx\`（26 MB）已删除：本设计不用 MIPI 屏，输出走 HDMI，DSI TX 已从顶层摘掉。

---

## 三、当前实测资源基线（Efinity 2026.1.132，干净构建）

| 指标 | 占用 |
|---|---|
| XLR | **16,830 / 60,800 (27.68%)** |
| BRAM（内存块） | **138 / 256 (53.91%)** |
| DSP | 0 / 160 |
| 全局时钟 | 15 / 32 |

> 注：厂商随包那份报告写的 22,762 XLR / 213 BRAM 是**带自动调试插桩**的构建（PnR 用的是 `ti60f225_oob.dbg.vdb`），不是发布基线。

### ★ 已识别的最大可砍项：DSI TX
`inst_efx_dsi_tx` 与 HDMI 通路（`dvi_encoder_m0`）是**两路并列且互不依赖**的显示输出 ——
`dvi_encoder_m0` 的输入是 `hdmi_tx_rdata/gdata/bdata/hs/vs/de`，**完全不经过 dsi_tx**。
赛题只要求 "HDMI/LCD 显示"（二选一即可），所以：

```
砍掉 inst_efx_dsi_tx  →  省 5,089 XLR + 76 BRAM
预计：XLR 16,830 → ≈11,741　　BRAM 138 → 62
```

BRAM 从 138 降到 62 尤其关键 —— **BRAM 才是这个设计里最紧的资源**（已用 54%，而 TinyML 的权重和激活缓冲全吃 BRAM）。

---

## 四、赛题要求对照（任务1 / 任务2 / 任务3）

| 任务 | 要求 | 本工程对应 | 状态 |
|---|---|---|---|
| **1** | MIPI 摄像头 ≥720p@30fps | CSI2 RX + frame_buffer（实测链路 1920×1080） | 复用 ✅ |
| **1** | I2C 接 MLX90640 红外测温 | `rtl\mmt\sensors\mmt_mlx90640_ctrl.v` | RTL ✅ 仿真已验证（21 项检查） |
| **1** | I2C 接 SHT30 温湿度 | `rtl\mmt\sensors\mmt_sht30_ctrl.v` | RTL ✅ 仿真已验证（15 项检查） |
| **1** | I2C 多设备分时复用 | `rtl\mmt\sensors\mmt_i2c_hub.v` | ✅ 仿真已验证（9 项检查） |
| **1** | FPGA 内滑动平均/异常值剔除/时间戳对齐 | `rtl\mmt\algo\`（帧差背景 1/32 更新、面积/质心） | 部分（滑动平均未做） |
| **1** | HDMI 叠加显示（视频+热力图小窗+环境参数） | `rtl\mmt\osd\mmt_osd_overlay.v` | RTL ✅ 未上板 |
| **2** | RISC-V 跑 TinyML 人体检测 | `ip\sapphire_soc\`（CustomInstruction 已开）+ TinyML 加速器 | **加速器已取得、资源已核算，RTL 未接** |
| **2** | 帧差法运动分析 | `rtl\mmt\algo\mmt_frame_diff.v` | ✅ |
| **2** | 60/25/15 加权融合决策 | `rtl\mmt\algo\mmt_fusion_vote.v` | ✅ 与浮点原型偏差 <0.61% |
| **2** | 场景三选一（暂定**入侵检测**） | RISC-V 固件 `sw\main.c` | ✅ 固件已编译、已装进 SoC |
| **2** | LED + 蜂鸣器 + HDMI 红框 + 事件置信度 | `rtl\mmt\alarm\` + OSD | ✅ RTL 完成 |
| **3** | 至少实现 2 项（7 选 2） | 已选 **② RISC-V 软核决策控制** + **⑤ 低功耗场景管理** | 进行中 |

---

## 五、注意事项 / 已踩过的坑

1. **`EFINITY_HOME` 必须是正斜杠**（`D:/Efinity/2026.1`）。反斜杠路径里的 `\2026` 会被 Tcl 当八进制转义吃掉，PnR 直接崩。
2. **`.cmd`/`.bat` 里不要写中文注释** —— cmd 用 OEM 代码页解析，UTF-8 中文会把后面的行拆坏。批处理一律纯 ASCII。
3. **构建脚本**：`工作区\06_Efinity验证\build.ps1`（含完整环境变量设置与 efx_map/efx_pnr 调用），
   用法 `.\build.ps1 -Xml <工程.xml> -Top <顶层> -Name <工程名>`。
4. Efinity 的 GUI 启动器是 `D:\Efinity\2026.1\bin\start_efinity.cmd`（官方 tar 包没安装器，必须靠 `setup.bat` 设环境变量）。
5. **工程的源文件清单不只是 XML 里的 `design_file`**（建骨架时踩了三次）：
   - 还有 `\`include` 的头部文件（如 `timescale.v` / `i2c_master_defines.v`）
   - 还有内存初始化文件（如根目录的 `Panel_1080p_reg.mem`）
   - 工具：`工作区\_工具\check_includes.js`（自动扫并补）
6. **XML 的 `last_run_state` / `*_ood` 不能改成非枚举值** —— 会让 efx_map 报
   `The file format is unexpected` 拒绝解析整个工程。
7. **★ 只把文件列进工程 XML 不等于检查过** —— 没有实例化，综合器会整块优化掉，
   表现是"exit=0 且资源数字一个字节没变"。**必须真正实例化再综合**，这条已经抓出 4 个真 bug。
8. **★ RTL 仿真的环境配方**（iverilog 是用 micromamba 装的，免安装免管理员）：
   ```
   安装: micromamba create -y -p D:\iverilog -c conda-forge iverilog bzip2
   运行: 用封装好的 工作区\06_Efinity验证\sim.ps1
         .\sim.ps1 -Tb sim\tb_xxx.v -Src rtl\... -IncDir @('rtl')
   ```
   三个必须处理的坑（少一个都跑不起来，且报错信息**不说**缺哪个 DLL）：
   - PATH 须同时含 `D:\iverilog\Library\bin` 与 `D:\iverilog\Library\mingw-w64\bin`
   - conda 包只带 `zlib.dll` / `libbz2.dll`，但 `system.vpi` 认的是
     `zlib1.dll` / `libbz2-1.dll` → 各建一个同名副本
   - 官方 Inno 安装器（bleyer.org）**静默安装会卡死在 UAC**，别走那条路

---

## 六、已完成模块与实测资源

### 汇总（全部为 Efinity 2026.1.132 实测，非估算）

| 子系统 | XLR | BRAM | DSP | 对应工程 |
|---|---|---|---|---|
| 视频链路（**已剥 DSI TX**） | **11,737**（19.30%） | 62 | 0 | `mmt_nodsi.xml` |
| 传感器采集侧 | **479**（0.79%） | 2 | 0 | `sensor_subsystem.xml` |
| 算法与决策 | **756**（1.24%） | 20 | 3 | `algo_subsystem.xml` |
| **合计** | **≈12,972（21.3%）** | **84** | **3** |
| **剩余给 TinyML 加速器 + RISC-V** | **47,828** | **172** | **157** |

> 对照：原始 10 号 demo 干净构建是 16,830 XLR / 138 BRAM；
> 砍掉 DSI TX 后降到 11,737 / 62（实测节省 **−5,093 XLR / −76 BRAM**，
> 与预测的 −5,089 / −76 几乎精确吻合）。

### 模块清单
```
rtl\mmt\sensors\
  mmt_i2c_master.v        通用 I2C 字节级主机（START/重复START/连续读/开漏三态/4 字节寄存器写）
  mmt_i2c_hub.v           ★ I2C 分时复用控制器（赛题任务1 明确要求）
  mmt_sht30_ctrl.v        SHT30 温湿度（1Hz，CRC-8 校验）
  mmt_mlx90640_ctrl.v     MLX90640 红外原始帧 → BRAM（温度计算留给 RISC-V 跑 Melexis 官方库）
  mmt_dpram.v             ★ 双口 RAM 模板（能正确推断 BRAM 的写法，见下方坑）
  mmt_sensor_subsystem.v  传感器子系统封装（可独立综合/验证）
rtl\mmt\algo\
  mmt_frame_diff.v        帧差法运动检测（背景 BRAM + 阈值 + 面积/质心 + 背景 1/32 更新）
  mmt_fusion_vote.v       60/25/15 加权投票 + 非授权时段 → 报警（Q8 定点）
  mmt_algo_subsystem.v    算法子系统封装
rtl\mmt\alarm\
  mmt_alarm_ctrl.v        LED 闪烁 + 蜂鸣器（2kHz 方波 + 500ms 断续）+ 事件类型/置信度
rtl\mmt\mmt_top.v         ★ 新顶层（= 10 号 demo 顶层剥掉 DSI TX）
```

### 已验证的正确性（不只是"编译过了"）
- **融合模块定点实现 vs 浮点原型**：60 帧逐帧得分最大偏差 **0.00613**（0.61%），
  报警结论**零处不一致**，10 个关键场景（含 30.0/38.0°C 边界）全部一致。
  脚本 `工作区\_工具\verify_fusion_q8.py`。
- **SHT30 的 CRC-8**：`CRC(0xBEEF)=0x92`，与数据手册测试向量一致。
- **I2C 子系统四个 testbench 全绿，84 项检查**：一条命令回归
  `powershell -File sim\run_all.ps1`

  | testbench | 检查数 | 覆盖 |
  |---|---|---|
  | `tb_i2c_master` | 39 | 写 2/4 字节、纯读 6 字节、写地址+重复起始+读、NACK 错误路径、req/done 竞争、done 单周期脉冲、**请求相位遍历** |
  | `tb_i2c_hub` | 9 | 单客户端、两客户端轮询、grant/done 同拍、三客户端无饿死、NACK 只通知被授权者 |
  | `tb_sht30_ctrl` | 15 | 正常测量（20.62°C / 50.00%RH）、CRC 失败保留旧值、NACK 报错不卡死、恢复 |
  | `tb_mlx90640_ctrl` | 21 | 初始化读-改-写、每帧只清一次标志、整帧 832 字的顺序与内容、`ta_raw`=RAM 字 800、NACK 后恢复 |

  其中 `tb_i2c_master` 的 T8 和 `tb_mlx90640_ctrl` 的数据校验都做过**反向验证**
  （把修复撤掉 / 把字节序颠倒，确认测试真的会报 FAIL），不是空测试。

### 接口契约要点（改动需同步）
- `mmt_i2c_master` 的 tx 接口：`tx_data[31:0]`（**右对齐**字节串）+ `tx_len[2:0]`（0..4 字节）
  - `tx_len=2` → 先 `tx_data[15:8]` 后 `tx_data[7:0]`
  - 写寄存器（4 字节）→ `tx_data=32'h800D_0000, tx_len=4`
- **客户端必须"看到 done 之后才撤销 req"**，master/hub 用**边沿重新武装**保证不会误判重发
- `mmt_i2c_master` 的 `ST_IDLE` **只在分相时钟位边界（`ph==0 && div_cnt==0`）接受请求**，
  这条不能改 —— 去掉它 START 条件有 50% 概率被丢掉（见下方 bug 表第 9 条）

### 已修的真 bug（全部靠"实例化后综合"或仿真抓出，没有一个是读代码看出来的）
| # | 位置 | 问题 | 抓法 |
|---|---|---|---|
| 1 | `mmt_i2c_master.v` | `scl_o` 被两个 always 块**多驱动**（VDB-1000） | 实例化后综合 |
| 2 | `mmt_i2c_hub.v` | `c_done` 比 `c_grant` 晚一拍 → 客户端**永远等不到结束**（死锁） | 实例化后综合 |
| 3 | `mmt_sensor_subsystem.v` | 3 个客户端却按 `2*` 声明扁平向量 | 实例化后综合 |
| 4 | `mmt_i2c_master.v` + hub | **`req`/`done` 竞争** → 用残留参数多发一次事务 | Claude 逐拍推演复审 |
| 5 | `mmt_i2c_master.v` | **`bit_cnt` 只有 3 位**，`3'd8` 被截断成 0 → ACK 判断从根上错 | iverilog 编译 warning |
| 6 | `mmt_i2c_master.v` | **START 后多一个 SCL 上升沿** → 从机错一位 → NACK | testbench 波形 |
| 7 | `mmt_frame_diff.v` | **`for` 循环给 RAM 赋初值** → 背景 RAM 推断成 **153,909 个触发器**，综合一步跑 475 秒不结束 | 实例化后综合（`Clock Network 'clk' with 153909 loads`） |
| 8 | `mmt_frame_diff.v` | **读写挤在同一 always 块** → Efinity 报 `EFX-0657`，RAM 又被映射成逻辑单元 | 实例化后综合 |
| 9 | `mmt_i2c_master.v` | **`ST_IDLE` 在任意相位接受请求 → START 条件丢失**。表现为"复位后第一笔事务成功、之后每一笔都 NACK"：`ST_START1` 靠 `act_sda(ph==1)` 拉低 SDA 产生 START、靠 `act_next(ph==3)` 推进状态；若进入时 `ph` 已越过 1（坏窗口占整个位周期的一半），这个位周期内 `act_sda` 不再出现而 `act_next` 照样推进 → SDA 从未拉低，从机不激活 | 新写的 SHT30 testbench（T8 请求相位遍历） |

**第 7、8 条的教训**：RAM 必须写成 `mmt_dpram.v` 那种形式 —— **读写分两个独立 always 块、
读口无条件寄存读、绝不用 for 循环赋初值**，否则 BRAM 会退化成触发器，综合直接爆炸。

**第 9 条的教训**：分相时钟驱动的状态机，**任何"可能在任意相位进入"的状态都必须先对齐到位边界**。
这个 bug 在老测试下 100% 不可见（固定时刻发请求 = 固定相位 = 恰好落在安全区），
必须专门扫相位才抓得到；而且**加了测试不等于测到了**，必须把修复撤掉反向验证一次。

---

## 七、软硬件接口地址（★ 三处曾经全错，已按生成的网表纠正）

固件要访问的地址**不能信 `ip\sapphire_soc\settings.json`** —— 那份文件自相矛盾
（它把 UART 写在 4096，而 `source\soc_config` 和厂商 demo 固件都用 0x10000，差 16 倍）。
以 `soc_config` + 生成的网表 + 反汇编 demo 固件三条独立证据为准：

| 名字 | 正确值 | 依据 |
|---|---|---|
| 片内 RAM 基址 / 大小 | **0xF9000000 / 32 KB (0x8000)** | 网表复位向量 + `~0x1FFF`→`~0x7FFF` 窗口掩码；大小由 SoC 参数 `OCRSize=32768` 决定 |
| CPU 复位向量 | 0xF9000000 | 网表 `IBusCachedPlugin_fetchPc_pcReg <= 32'hf9000000` |
| 自定义寄存器基址 | **0xF8100000** | APB 解码 `==0x100000`；APB 桥在 `0xF8000000` |
| UART | **0xF8010000** | APB 解码 `==0x010000`；demo 固件里也出现 `0xF8010000` |
| I2C | 0xF8016000 | APB 解码 `==0x016000`；demo 固件里也出现 `0xF8016000` |
| UART 波特率 | **115200 8N1（复位默认，无需配置）** | 分频器 `tick=clk/(div+1)` + 复位值 107 + 每 8 tick 一位 → 100MHz/108/8 ≈ 115.7k |

`sw\mmt_regs.h`、`sw\uart.c`、`sw\link.ld` 已按上表修正，并在文件头写清了每条依据。

### ★ SoC 参数与实际内存大小的对应关系（曾经在这里栽过跟头）

| 参数 | 含义 | 备注 |
|---|---|---|
| **`OCRSize`** | **片内 RAM 字节数** | 4096→4 KB、8192→8 KB、32768→32 KB。**这才是 RAM 大小** |
| `LDSize` | 应用区大小（链接脚本的 memory region） | **只在 `DDR=1` 时才存在/可编辑**（`isPresentGUI/enable: ${DDR}==1`） |

⚠️ 原来的 `link.ld` 写了 `LENGTH = 124K`，根源是**读了一个 `DDR=0` 时根本不生效的 `LDSize=124`**，
而真实片内 RAM 只有 8 KB —— 链接能过、一跑就飞出 RAM。
**教训：读 IP 参数之前先确认它在你当前的配置下是否生效。**

### SoC 从命令行重新生成（不必开 GUI）

```powershell
# 环境必须先设（等价于 bin\setup.bat；PYTHONHOME 必须在解释器启动前设好）
$env:PYTHONHOME = 'D:/Efinity/2026.1/python311'
$env:EFINITY_HOME = 'D:/Efinity/2026.1'
python 工作区\_工具\regen_soc.py --out <临时工程目录> `
       --param CustomInstruction=1 --param DDR=0 --param OCRSize=32768
```
目标目录里**必须存在一个工程 XML**（生成器要读工程名），否则会 `AssertionError`。
生成完先**比对端口列表**再替换 `ip\sapphire_soc`，工具的备份放在 `_backup\sapphire_soc_2.2.9\`。

---

## 七之二、TinyML（赛题"多模态 AI"的核心）

**平台是公开的**：[Efinix-Inc/tinyml](https://github.com/Efinix-Inc/tinyml)；
国内 GitHub 不通，用 Gitee 镜像 `https://gitee.com/uesoft/tinyml`（已克隆到 `D:\FPGA\tinyml`）。
仓库里含 **Ti60F225 的完整参考工程**（hello_world + mobilenetv1/yolo 人体检测 + 人脸关键点）。

**资源估算（用官方估算库 `resource_lib.py` 无头跑出来的，不是手算）**：
```
TINYML_ACCELERATOR   14106 LUTs  9143 FFs  2472 ADDs  59 RAM Blocks  12 DSP
设计当前             20372 XLR / 140 BRAM / 12 DSP
接入后预计           ≈43.6k XLR(71.7%) / 199 BRAM(77.7%) / 24 DSP   → FITS（BRAM 余量只剩 57 块）
```
估算工具：`工作区\_工具\tinyml_res_estimate.py`

**接入方式**（读参考工程得到）：
- 命令/响应口直连 SoC 的 `cpu0_customInstruction_*`（所以 SoC 必须 `CustomInstruction=1` ✅ 已做）
- 数据口是 **AXI4 主口**（Ti60 默认 128 位），经 AXI 互联读模型权重与张量

**还差**：AXI 互联（把 frame_buffer / SoC / TinyML 三个主口汇到 DDR3）、实例化 `tinyml_top.v`、
以及**模型放哪的路线选择**（真实模型编进固件需要 SoC 开 DDR；不开 DDR 只能跑很小的模型）。

---

## 八、固件构建与装载

```
cd sw
powershell -File build_sw.ps1              # 编译链接 -> build\mmt_fw.{elf,hex,bin,map}
powershell -File hex2soc.ps1               # 转成 SoC RAM 初值文件 + 往返校验
powershell -File hex2soc.ps1 -Install      # 装进 IP（覆盖原厂 demo 固件，已备份）
# 然后重跑 Efinity 全流程，BRAM 初值才会更新
```

**装载格式不需要官方 `EFX_HEX` 工具**：SoC 网表用 `$readmemb` 直接吃 4 个文本文件
`EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{0..3}.bin`，
每个 **RAM字节数/4** 行、每行 8 个 `'0'`/`'1'` 字符（LF 换行，无 CR），
**地址 `4*i+N` 处的字节 → `symbolN[i]`**。`hex2soc.ps1` 生成后会解回来逐字节比对，
不通过就非零退出。

⚠️ 装的时候**两处副本都要覆盖**（`ip\sapphire_soc\` 和
`ip\sapphire_soc\source\hardware\netlist\`），脚本已经处理 —— 只换一处会出现
"明明换了固件但烧进去还是旧的"这种极难查的问题。原厂镜像备份在
`ip\sapphire_soc\_vendor_ram_init_backup\`。

---

## 九、下一步

- [x] 用 iverilog 给 I2C 主机 / hub / 两个传感器控制器写自检测试平台 ✅（84 项检查全绿）
- [x] 砍掉 DSI TX，验证资源节省 ✅（−5,093 XLR / −76 BRAM）
- [x] 引入 Sapphire RISC-V ✅
- [x] 写算法层 `rtl\mmt\algo\` + OSD + 报警 ✅
- [x] 写新顶层 `rtl\mmt\mmt_top.v` 取代 `ti60f225_oob_top.v` ✅
- [x] RISC-V 固件骨架 `sw\` ✅（编译通过、已装进 IP、地址全部核实）
- [x] **获取 Efinix TinyML 加速器** ✅（公开仓库 + Ti60F225 参考工程；资源实测装得下）
- [x] **SoC 打开 `CustomInstruction`** ✅（TinyML 命令口的前提；SoC 2.2.9→3.4.0，只多 9 个 XLR）
- [x] **片内 RAM 8 KB → 32 KB** ✅（解封 Melexis 逐点温度）
- [x] **引脚约束打通** ✅（原来完全没生效；现在只剩 8 个新增引脚待定，见第十节）
- [ ] **TinyML 接入**：AXI 互联（frame_buffer / SoC / TinyML → DDR3）+ 实例化 `tinyml_top.v`
      + 定"模型放哪"的路线（真实模型需 SoC 开 DDR；否则只能跑小模型）
- [ ] **移植 Melexis 官方库做逐点温度**（32 KB 已够；需定点化 + Python 黄金模型交叉验证）
- [ ] AXI 主口接 DDR3（目前悬空）
- [ ] **上板验收**（板子未购）：串口 115200 看启动打印、`MMT_ID==0x4D4D5401`、寄存器读写、图像链路

---

## 十、引脚约束与 Interface Designer（★ 曾经完全没生效）

**症状**：`out\mmt.place.rpt` 里整个设计一百多个 I/O 全是 `Unassigned Core Pins` ——
`mmt.peri.xml` 虽然在工程根目录，但 `mmt.xml` 里没有任何东西引用它。

**约束链**（`efx_map`/`efx_pnr` 都不直接读 peri 文件）：
```
<project>.peri.xml          ← 由工程 XML 的 <efx:interface_info><efx:peri_file .../> 指定
   ↓  efx_run -f interface
outflow\<design>.interface.csv
   ↓  filter_interface.ps1（剪掉设计上已不存在的引脚，见下）
out\<design>.interface.csv
   ↓  efx_pnr --sync_file
```
**一条命令跑完全部**：
```powershell
powershell -File 工作区\06_Efinity验证\run_full_flow.ps1
```

### 现在的引脚状态

已正确分配：DDR3 全套、CSI-2 摄像头全套、HDMI TMDS ×4、`LED[3:0]`、`CLK_25M`、
**JTAG_USER1**、各 PLL 复位。

**剩下 8 个未分配，全部是本设计新增的信号**（板子到手后填进 `mmt.peri.xml` 即可）：

| 未分配 | 说明 |
|---|---|
| `i_uart_rxd` / `o_uart_txd` | 串口。**优先走板上 FT4232HL 的 USB 串口**，就不用外接 |
| `o_sensor_scl` `_oe` / `o_sensor_sda` `_oe` | 传感器 I2C（输出 + 输出使能） |
| `o_buzzer` | 蜂鸣器 |
| `pll_inst4_RSTN` | peri 里缺条目（原有 PLL 复位，无害） |

### 两个必须知道的坑

1. **不能删 peri 里的 MIPI DPHY 块**：我们删了 DSI TX，但 peri 里那块还在，会生成
   `required ... mipi_dp_*_RST` 这些设计上不存在的必需引脚，PnR 直接失败。
   而**把整块删掉会让 Interface Designer 自己崩**（`pt/bin/design/service.py:2537`
   缺 None 判断）。所以方案是保留 peri、**过滤生成的 CSV**——
   `filter_interface.ps1` 会从顶层 HDL 解析真实端口表，只删设计上不存在的 `required` 行，
   并逐行打印删了什么（实测恰好 5 行）。
2. **JTAG 端口名不能自己起**：peri 声明了 Interface Designer 的 `JTAG_USER1` 硬块，
   要求顶层有 `jtag_inst1_TDI/TDO`（标 required）。原来 `mmt_top` 把这 8 个信号
   全端接成常量，等于**主动放弃软核调试**，而且 PnR 会失败。现已按官方 demo 的命名引出。
