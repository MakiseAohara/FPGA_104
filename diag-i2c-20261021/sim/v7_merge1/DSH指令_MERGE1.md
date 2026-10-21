# DSH 指令 · 构建 v7_MERGE1（队友 SoC+TinyML 工程 + 我们的传感器/决策核心/OSD，只编译，不烧录）

来源：指挥官（Claude）。Kevin 已授权由我负责合并；本轮只编译，Kevin 当前明确说先不上板。

## 这是什么
- 底座：队友 GitHub 分支 `feat/live-tinyml-20261020`（HEAD 2d27567）里的 `project/v7_camera_ai`（SapphireSoc + TinyML 加速器 + 厂商 v7 视频通路），保持原样。
- 加入：我们的"多模态感知+决策"核心 `v7_mmt_core`（帧差、SHT30、MLX90640、融合投票、报警保持、低功耗管理、OSD 文字/热力图/红框）。
- 唯一的行为接口：队友固件写的 APB reg9 bit0（原来只驱动红框，信号名 `osd_alarm_v2`，已在 hdmi_tx_slow_clk 域双级同步）现在接到我们核心的 `ai_person`（TinyML 人体判决）。核心参数 `AI_MODE=1`：视觉置信度取 TinyML 判决，报警门控 = 融合得分过阈 且 非授权时段 且 TinyML 判有人 且 红外有热点。
- 队友原来的 `mmt_osd_demo` 实例被替换为我们的 `v7_osd_top`，OSD 前的像素输入逻辑（gamma 选择与 R/B 交叉）逐字保持一致。
- 新增引脚（均 3.3V LVCMOS）：io_sns_scl=GPIOL_11（inout）、io_sns_sda=GPIOL_09（inout）、sns_buzzer=GPIOR_13（output）、key_night_n=GPIOR_22（input）、key_learn_n=GPIOR_21（input）。已核对：队友 peri.xml 与 rtl 中没有使用这些引脚，也没有模块名冲突。

## 文件（已放在 D:\FPGA\mmt\sim\v7_merge1\）
- `v7_MERGE1_src.zip`：完整的合并后工程源码（不含位流），sha256 = b562da76d1305cfd54d26c0e98bc16e7203123251c669f31269db48382e93d80
- `apply_merge.py`：生成这个 zip 的脚本（仅供审计，你不需要运行）
- 关键文件 sha256（解压后核对）：
  - rtl/ti60f225_oob_top.v = f6a54535492b9ee4a417bd5c90f698b29443e7c072708edace13032de65aa121
  - ti60f225_oob.xml = 8ec07e149fa80959ea6894ff73750cd66a8416ecfc953d925a424eb497f7655a
  - ti60f225_oob.peri.xml = 07423aef14c899eef0af2cb7e7472c4b261485c7064907efe817c2335dc42d1a
  - rtl/v7/mmt/v7_mmt_core.v = dd3c7a0566ac652bf6043de87939844663172434a4708c825679281651938cc6
  - v7_font8x16.hex = dbf48a788166882997b78b93e7398578847fa461c20c8a9d6dd71f5ced524957
- 注意：队友 top.v 里含非 UTF-8 字节（GBK 乱码注释，行尾含 0x85），ti60f225_oob.xml 是 CRLF 换行。我已按字节处理；**你解压后不要用会改编码或换行符的方式打开保存任何文件**。

## 步骤
1. 核对 zip 的 sha256；解压到**纯 ASCII 短路径** `D:\v7work\v7_MERGE1`（队友文档提示：路径过长会触到 260 字符限制；`$readmemh` 在中文路径下会失败）。禁止复用已有目录。
2. 核对上面 5 个关键文件的 sha256。
3. 检查（只读）：队友工程根目录下的 `EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol*.bin`、`osd_demo_text.hex`、`font8x16.hex`、`yuvpattern_mif.memh`、`Panel_1080p_reg.mem` 都在；`v7_font8x16.hex` 是我们字库（队友的 `font8x16.hex` 与它不同，所以我们改名避免覆盖）。
4. 用 `tools\v7_flow.ps1` 跑完整流程（efx_map → efx_pnr → efx_run -f interface → filter_interface → efx_pnr --sync_file → efx_pgm）。若队友工程需要额外步骤（如 ip 目录里的 SoC/TinyML 需要先生成），按队友 `docs\交接-实时TinyML推理-2026-10-20.md` 的构建说明处理，并如实记录与我们标准流程的差异；**不要为了通过而改动 RTL、约束或 IP 配置**。

## 验收与汇报
- 记录：5 步 exit 码；`No valid pin(s) found for clock`（必须为 0）；`No clocks matched`（记录数值，并说明与厂商 v7 的 87 基线是否一致；若不同，指出是哪些时钟约束，别猜）。
- 时序：列出所有时钟域最终 setup/hold；**任何一条为负：立即停下，如实报告，不要自行改 RTL 或约束。** 特别记录 hdmi_tx_slow_clk 域和 core_clk（SoC）域。
- 资源：XLR/Memory/DSP 总量，并按层次归因（至少 u_soc、u_tinyml_accel、u_v7_mmt、inst_gamma_correction）。我的预估：XLR ≈ 51,000（约 84%）、Memory ≈ 186、DSP ≈ 57。**若 XLR 超过 57,000（约 94%）或 Memory 超过 230，先停下报告。**
- 位流：路径、字节数、sha256（不可复现，仅作该产物指纹）。
- 写证据 `D:\FPGA\mmt\out\evidence\v7_merge1_build.md`（含 diff 摘要、时序表、资源归因表）。
- 汇报用一段话：结果、时序是否全正、资源、证据路径。然后停下。

## 授权边界（沿用）
- **不烧录**（Kevin 当前明确说先不上板）；不 push；不删文件；不改 RTL/约束/IP。
- 所有结论带证据；不确定写"未验证"。
- 队友线（TinyML）的上板结果只能写"文档声称"，除非你自己在本机复核过。
