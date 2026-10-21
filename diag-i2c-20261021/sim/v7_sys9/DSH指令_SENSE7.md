# DSH 指令 · 构建 v7_SENSE7（I2C 地址扫描诊断版，只编译，不烧录）

来源：指挥官（Claude）。SENSE6 板上现象：FPGA 持续发 I2C 时钟，但 SHT30 与 MLX90640 都从未应答（A=0, N=0000）。接线已由 Kevin 用万用表核对无误。SENSE7 = SENSE6 + 新增 I2C 地址扫描探针：按住板上 KEY2 时 FPGA 接管总线，对 0x08..0x77 逐个探测，屏幕第三行右侧显示应答个数与前两个地址。不改任何决策逻辑。

## 文件（D:\FPGA\mmt\sim\v7_sys9\，只拷贝，不要改内容）
| 文件 | sha256 | 动作 |
|---|---|---|
| v7_mmt_core.v | 9e9d360199f812defc059037f4efe578a9e7fe18cfd814f03a72466fa14682b0 | 覆盖 rtl\mmt\ 同名文件 |
| v7_txt_fmt.v | cdf4ddc2598fa7e3317b12bf66635f78c0dfc214e721f3b54b9bd82aabe301a2 | 覆盖 rtl\mmt\ 同名文件 |
| v7_i2c_probe.v | 4005af821bc86f6323be46bf25c4544fcfc1849625a33f591e32c72349d4bb22 | 新增到 rtl\mmt\ |

## 步骤
1. 核对三个 sha256，不一致就停下报告。
2. 以 `D:\v7work\v7_SENSE6` 为源，复制为**新目录** `D:\v7work\v7_SENSE7`（纯 ASCII 路径；排除 out、work_syn、work_pnr、outflow、flow_console.log、*.gtkw；禁止复用已有目录）。
3. 覆盖两个文件，新增一个文件到 `rtl\mmt\`。
4. 编辑 `ti60f225_oob.xml`：在 `rtl/mmt/v7_pwr_ctl.v` 那一行**后面**加一行
   `        <efx:design_file name="rtl/mmt/v7_i2c_probe.v" version="default" library="default"/>`
   （缩进、LF 换行、编码与原文件一致，按字节安全方式改。）
5. 全树 diff 对 SENSE6：只应有四处变化（两个文件改、一个新增、xml 多一行）；debug_top.v 不变。
6. 用 `tools\v7_flow.ps1` 跑完整流程。

## 验收
- 5 步全 exit 0；`No valid pin(s) found for clock` = 0；`No clocks matched` = 87。
- 所有时钟域 setup/hold 全正；记录 hdmi_tx_slow_clk 内 setup/hold（SENSE6 参考 +0.308 / +0.029 ns）。
- 资源对照 SENSE6（XLR 31,668、Memory 118、DSP 15）：XLR 增加应在一两百以内（注意 gamma 校正有综合波动，请和 u_v7_mmt 子树增量分开归因）；Memory/DSP 变了就停下报告。
- **任何 setup 或 hold 为负：立即停下报告，不要改 RTL，不要烧录。**

## 证据与汇报
- 写 `D:\FPGA\mmt\out\evidence\v7_sense7_build.md`（diff、资源对照、时序表含 hdmi 域、位流路径、字节数、sha256）。
- 汇报用一段话：结果、时序是否全正、hdmi 域变化、证据路径。然后停下。

## 授权边界
**本指令只编译，不烧录**（烧录要等 Kevin 另行明确说"烧录"）；不 push；不删文件；不改 RTL/约束（本指令指定的除外）。所有结论带证据，不确定写"未验证"。
