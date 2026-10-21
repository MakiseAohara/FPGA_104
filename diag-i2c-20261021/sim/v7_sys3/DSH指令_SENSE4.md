# DSH 指令 · 构建 v7_SENSE4（只编译，不烧录）

来源：指挥官（Claude）。上一轮 v7_SENSE3 已验收通过，本轮在 SENSE3 基础上只改"视觉背景自动重学 + 红外热点门控"两处逻辑，用来解决"板上蜂鸣器一直响"。

## 背景（为什么改）
1. 帧差背景在"判定有运动"时被冻结：场景永久变化（开机曝光未稳、开灯、相机被挪）→ 运动永远为真 → 背景永不更新 → 永远报警。现场照片 `MOTION=1 AREA=4850`（静止场景）与此吻合。
2. 夜间模式 + SHT30 正常 + 运动面积足够大，不需要红外看到人，得分就能到 190（阈值 154）→ 直接报警，不符合赛题"人体出现+体温正常（排除热源）"的判据。

## 新增/改动文件（已放在 D:\FPGA\mmt\sim\v7_sys3\，你只管拷贝，不要改内容）
| 文件 | sha256 |
|---|---|
| v7_mmt_core.v（覆盖 rtl\mmt\ 同名文件） | 6bf3fd4ae62afccc57097eee2c79833e2c167b2a725c3a93b17ab563b063e618 |
| v7_freeze_ctl.v（新增到 rtl\mmt\） | 87b2e2416156adf9933f5304c7d54ee17cd6ae5c0488debcc715413a320e411b |

仿真证据（指挥官已做）：
- 单元仿真 tb_fz：旧行为下运动标志从第 6 帧起永远为 1；新行为在 FREEZE_MAX 后自动重学，运动清零。
- 整机仿真另有两组（有热点应报警/无热点不应报警），结果由指挥官另行确认，你不用跑。

## 步骤
1. 先核对上面两个 sha256 与 `D:\FPGA\mmt\sim\v7_sys3\` 里文件一致，不一致就停下报告。
2. 以 `D:\v7work\v7_SENSE3` 为源，复制为**新目录** `D:\v7work\v7_SENSE4`（纯 ASCII 路径；排除 out、work_syn、work_pnr、outflow、flow_console.log、*.gtkw；禁止复用任何已有变体目录）。
3. 把 `v7_mmt_core.v` 覆盖到 `D:\v7work\v7_SENSE4\rtl\mmt\`，把 `v7_freeze_ctl.v` 拷到同目录。
4. 编辑 `D:\v7work\v7_SENSE4\ti60f225_oob.xml`：在 `rtl/mmt/v7_frame_diff.v` 那一行**后面**加一行
   `        <efx:design_file name="rtl/mmt/v7_freeze_ctl.v" version="default" library="default"/>`
   （缩进、换行符、文件编码都保持与原文件一致，按字节安全方式改，别用会改编码或换行符的编辑方式。）
5. 对 SENSE3 做全树 diff，确认**只有三处变化**：v7_mmt_core.v 改、v7_freeze_ctl.v 新增、ti60f225_oob.xml 多一行。debug_top.v 的 G='h110、B='h188 保持不变（继承自 SENSE3）。
6. 用 `tools\v7_flow.ps1` 跑完整流程（efx_map → efx_pnr → efx_run -f interface → filter_interface → efx_pnr --sync_file → efx_pgm）。

## 验收（全部达到才算过）
- 5 步全 exit 0。
- `No valid pin(s) found for clock` = 0；`No clocks matched` = 87。
- 所有时钟域 setup/hold 全正；记录 hdmi_tx_slow_clk 内 setup/hold。SENSE3 参考：setup +0.164 ns、hold +0.026 ns；SENSE2 参考：+0.320 / +0.027。
- 资源对照 SENSE3：XLR 30,812、Memory 118、DSP 15。新增逻辑很小，XLR 预期只多几十到一两百；BRAM 和 DSP 应不变。若 BRAM 或 DSP 变了，说明有意外推断，停下报告。
- **只要有任何一条 setup 或 hold 为负：立即停下，如实报告，不要自行改 RTL 去修时序。**

## 证据与汇报
- 写 `D:\FPGA\mmt\out\evidence\v7_sense4_build.md`：diff、资源对照表、时序对照表（含 hdmi 域）、位流 sha256 与字节数、四项验收结果。
- 汇报用一段话：结果、时序是否全正、与 SENSE3 的 hdmi 域 setup/hold 变化、证据路径。然后停下。

## 授权边界（沿用）
- 不烧录（除非 Kevin 或指挥官明确写"烧录"）；不 push；不删文件；不改 RTL/约束（本指令指定的除外）。
- 所有结论带证据；不确定写"未验证"。
