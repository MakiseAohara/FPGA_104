# DSH 指令 · 构建并烧录 v7_SENSE6（I2C 诊断版）

来源：指挥官（Claude）。Kevin 已在聊天中明确授权：**SENSE6 时序全正后烧录一次**（仅 JTAG 临时加载）。

## 背景
板上 SENSE4 的 OSD 显示 T=00.0 RH=00.0 IR=00.0 SNS=ER，传感器接线和供电已由 Kevin 用万用表核对无误。SENSE6 = SENSE5 + 只读的 I2C 诊断逻辑，OSD 空闲列显示：SCL/SDA 电平、从机是否拉低 SDA（A=）、各总线错误标志、主机发出的 SCL 次数（O=）、从机拉低次数（N=）。不改任何决策逻辑。

## 文件（D:\FPGA\mmt\sim\v7_sys7\，只拷贝，不要改内容）
| 文件 | sha256 | 动作 |
|---|---|---|
| v7_mmt_core.v | f656bae1600193ea5c6547b22c64fe8465853bdca549c260fa92d7367a20c061 | 覆盖 rtl\mmt\ 同名文件 |
| v7_txt_fmt.v | 2fbb11acc7b6d52e548530a66e2fda07070607ca0da4bc9ec1f7eafee5be01b4 | 覆盖 rtl\mmt\ 同名文件 |

## 步骤
1. 核对两个 sha256，不一致就停下报告。
2. 以 `D:\v7work\v7_SENSE5` 为源，复制为**新目录** `D:\v7work\v7_SENSE6`（纯 ASCII 路径；排除 out、work_syn、work_pnr、outflow、flow_console.log、*.gtkw；禁止复用已有目录）。
3. 覆盖上述两个文件。xml 不用改（没有新增文件）。
4. 全树 diff 对 SENSE5：应只有这两个文件不同，debug_top.v 不变。
5. 用 `tools\v7_flow.ps1` 跑完整流程。

## 验收（全部达到才进入烧录）
- 5 步 exit 0；`No valid pin(s) found for clock` = 0；`No clocks matched` = 87。
- 所有时钟域 setup/hold 全正；记录 hdmi_tx_slow_clk 内 setup/hold（SENSE5 参考 +0.323 / +0.027 ns）。
- 资源对照 SENSE5（XLR 31,407、Memory 118、DSP 15）：XLR 增加应在几十到两百以内；Memory/DSP 变了就停下报告。
- **任何 setup 或 hold 为负：立即停下报告，不要改 RTL，不要烧录。**

## 烧录（仅在上面验收全部通过后）
- 位流 `D:\v7work\v7_SENSE6\out\v7_SENSE6.bit`，记录字节数与 sha256。
- 用 `D:\FPGA\mmt\tools\flash_vendor.ps1`（JTAG，易失加载），**只烧一次**，不改脚本，不写 SPI。
- 成功判据：日志同时出现 `Device ID read from JTAG: 0x10660A79` 与 `finished with JTAG programming`。失败（如 No USB target）：如实报告，不要自行重试超过一次。
- 烧完停下，由 Kevin 看屏幕并调白平衡。

## 证据与汇报
- 写 `D:\FPGA\mmt\out\evidence\v7_sense6_build.md`（diff、资源对照、时序表含 hdmi 域、位流 sha256 与字节数、烧录日志路径）。同时补写 `v7_sense5_build.md`（若尚未写，数字来自 SENSE5 构建日志并注明路径）。
- 汇报用一段话：结果、时序是否全正、是否已烧录、证据路径。然后停下。

## 授权边界
不 push；不删文件；不改 RTL/约束；除上面这一次 SENSE6 烧录外不烧录任何东西。所有结论带证据，不确定写"未验证"。
