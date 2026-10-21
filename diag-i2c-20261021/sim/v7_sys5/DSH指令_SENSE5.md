# DSH 指令 · 构建 v7_SENSE5（只编译，不烧录）

来源：指挥官（Claude）。SENSE4 已验收通过。本轮在 SENSE4 基础上新增"低功耗场景管理"（赛题任务3 ⑤）的最小实现。

## 改了什么
- 新增模块 `v7_pwr_ctl.v`：无人（无运动且无红外热点）连续 900 个视频帧（约 15 秒 @60Hz）→ 进入低功耗模式；低功耗时视觉处理只处理每 4 帧中的 1 帧；检出运动或红外热点立即恢复。
- `v7_mmt_core.v`：接入该模块；帧差的帧起始脉冲改为由它抽稀；低功耗时 LED0 慢闪作为指示。
- `v7_txt_fmt.v`：OSD 第三行 EVT 词增加 `SLEEP`（报警 INTRUDE / 低功耗 SLEEP / 正常 NORMAL）。
- 温湿度和红外监测频率不变（对应"保留温度监测"）。注意：降低的是视觉处理帧率，不是摄像头传感器输出帧率。

## 文件（已放在 D:\FPGA\mmt\sim\v7_sys5\，只管拷贝，不要改内容）
| 文件 | sha256 | 动作 |
|---|---|---|
| v7_mmt_core.v | 8e35786dbc39c760eaaaae3c4b01b0985173264d1ecbcce23227ce470c3071e3 | 覆盖 rtl\mmt\ 同名文件 |
| v7_txt_fmt.v | ac7c711cbc898b95155a044d735f106db234a186072301ae9dd5d0a9501a0d54 | 覆盖 rtl\mmt\ 同名文件 |
| v7_pwr_ctl.v | 7624d821dd9e3f4086ce12f19e66513b4469f10c5ae25e007a995da33f1cb3ea | 新增到 rtl\mmt\ |

`v7_freeze_ctl.v` 沿用 SENSE4 的，不动。

## 步骤
1. 核对上面三个 sha256 与文件一致，不一致就停下报告。
2. 以 `D:\v7work\v7_SENSE4` 为源，复制为**新目录** `D:\v7work\v7_SENSE5`（纯 ASCII 路径；排除 out、work_syn、work_pnr、outflow、flow_console.log、*.gtkw；禁止复用任何已有变体目录）。
3. 覆盖两个文件、新增一个文件到 `rtl\mmt\`。
4. 编辑 `ti60f225_oob.xml`：在 `rtl/mmt/v7_freeze_ctl.v` 那一行**后面**加一行
   `        <efx:design_file name="rtl/mmt/v7_pwr_ctl.v" version="default" library="default"/>`
   （缩进、LF 换行、编码都与原文件一致，按字节安全方式改。）
5. 全树 diff 对 SENSE4：确认只有四处变化（两个文件改、一个新增、xml 多一行）；debug_top.v 不变。
6. 用 `tools\v7_flow.ps1` 跑完整流程（同 SENSE4）。

## 验收
- 5 步全 exit 0；`No valid pin(s) found for clock` = 0；`No clocks matched` = 87。
- 所有时钟域 setup/hold 全正。记录 hdmi_tx_slow_clk 内 setup/hold。SENSE4 参考：setup +0.411 ns、hold +0.029 ns。
- 资源对照 SENSE4：XLR 31,624、Memory 118、DSP 15。新增逻辑很小，XLR 预期上下波动在一两百以内（注意 gamma 校正模块有 ±几百的综合波动，请和 u_v7_mmt 子树增量分开归因）；Memory 和 DSP 应不变，变了就停下报告。
- **只要有任何 setup 或 hold 为负：立即停下，如实报告，不要自行改 RTL。**

## 证据与汇报
- 写 `D:\FPGA\mmt\out\evidence\v7_sense5_build.md`（diff、资源对照、时序对照含 hdmi 域、位流 sha256 与字节数）。
- 汇报用一段话：结果、时序是否全正、hdmi 域变化、证据路径。然后停下。

## 授权边界（沿用）
- **不烧录**（Kevin 当前明确说先不上板）；不 push；不删文件；不改 RTL/约束（本指令指定的除外）。
- 所有结论带证据；不确定写"未验证"。
