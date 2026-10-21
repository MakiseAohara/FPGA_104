# 交接 · I2C 传感器全部不应答（2026-10-21 夜，指挥官 Claude 整理）

## 一句话现状
板上 v7_SENSE6：HDMI 画面、OSD、帧差运动检测都正常；SHT30 与 MLX90640 **一次应答都没有**（OSD：`SNS=ER`，`T=00.0 RH=00.0 IR=00.0`）。入侵检测要求"运动 + 红外热点"，所以现在**永远不会报警**，这是 10/26 端到端门槛的唯一卡点。

## 已核实（有证据）
- 接线（Kevin 用万用表通断档实测）：J28 pin1=3.3V→两模块 VCC；pin32=SCL→两模块 scl；pin34=SDA→两模块 sda；pin36=GND；pin32/34 相互、对 pin36/35 均不通；模块 VCC/GND 电压正常；SCL/SDA 空闲约 3.27 V。原理图（Ti60F225A_V4_SCH.pdf，J7 页）：32=GPIOL_11、34=GPIOL_09、35/36/30 为 GND。
- 约束：`io_sns_scl`=GPIOL_11、`io_sns_sda`=GPIOL_09，3.3 V LVCMOS，inout，OUT/OE/IN 三线，弱上拉，drive_strength=2（与摄像头 I2C 的 peri 写法一致）。
- SENSE6 屏幕读数（照片）：`SCL=1 SDA=1 A=0 E=1 IE=1 SV=0 IV=0 C=0 K0 O=004B→00CB→00E6 N=0000`
  - O 在涨 ⇒ 主机一直在发 SCL 时钟；N=0000、A=0 ⇒ 从没有任何从机拉低 SDA；K0 ⇒ 总线没被外部拉死。
- 仿真（iverilog，自写行为模型）：同一套 I2C 主机对 0x44/0x33 的假从机全通（`SNS=OK T=25.2 RH=48.1`）。**仿真不能证明真芯片会应答**：模型是我们按数据手册写的，不是厂家模型。

## 未确认 / 开放问题
1. 黑色红外模块（丝印 VIN GND SCL SDA，镜头）是否真是 MLX90640 —— 项目文档这么写，我没有看到任何型号字样。
2. SHT30 模块（板上印 SHT3X-DIS，两个 10k 上拉）实际地址是 0x44 还是 0x45：未知。
3. 两个模块都不应答，更像共用的因素（主机侧时序/驱动、上拉、总线）而不是单个模块坏，但**没有示波器/逻辑分析仪证据**。
4. 主机 SCL 推挽驱动（scl_o 为 1 时 oe=1 推高）而非纯开漏；SDA 在发送"1"时同样推高。对没有时钟拉伸的从机问题不大，但值得核对。

## 下一步（已准备）
- **SENSE7**（`D:\FPGA\mmt\sim\v7_sys9\`）：在 SENSE6 上加 `v7_i2c_probe.v`——按住板上 KEY2 时接管总线，对 0x08..0x77 逐地址探测，OSD 第三行右侧显示 `P=应答个数 A=首地址 B=第二地址 S=轮数`（十六进制）。纯开漏，仿真通过（0x44+0x33 → P=02 A=33 B=44；SHT 改 0x45 → B=45；无设备 → P=00）。已有 `DSH指令_SENSE7.md`，构建完成后需 Kevin 明确说"烧录"再上板。
- 如果扫描 P=00：重点看模块本身/供电/上拉；如果能扫到地址：按真实地址改 RTL 参数（`mmt_sensor_subsystem` 的 SHT30_ADDR/MLX90640_ADDR）。
- 最有价值的外部证据：一台示波器或 8 通道逻辑分析仪，直接抓 pin32/pin34 在 SENSE6 上的波形（看起始条件、地址字节、第 9 位）。

## 文件地图（D:\FPGA\mmt\sim\）
- `v7_sys3\`：SENSE3/4（freeze_ctl、IR 门控）源码与指令；`v7_sys5\`：SENSE5（低功耗）；`v7_sys7\`：SENSE6（I2C 诊断）；`v7_sys9\`：SENSE7（地址扫描）；`v7_merge1\`：与队友 SoC+TinyML 合并工程生成脚本和 zip（只编译，未上板）。
- 证据：`D:\FPGA\mmt\out\evidence\v7_sense{3,4,5,6}_build.md`、`v7_sense{4,6}_flash.md`。
- 核心 RTL：`v7_mmt_core.v`（传感器+决策）、`mmt_i2c_master.v`、`mmt_sht30_ctrl.v`、`mmt_mlx90640_ctrl.v`、`mmt_sensor_subsystem.v`（均在 `rtl\mmt\`）。

## 纪律（沿用）
Efinity 构建在纯 ASCII 短路径 `D:\v7work\<名字>` 下做，禁止复用变体目录；时序出现负 slack 立即停下报告、不改 RTL 凑时序；烧录要明确授权，只用 `tools\flash_vendor.ps1`（JTAG 易失加载）；不 push main、不 force push。
