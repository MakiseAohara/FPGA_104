> **历史快照（MERGE16/17）**：下文“定版”描述属于对应历史阶段。当前硬件工程见 [project/current](../../project/current/README.md)，当前位流及校验值见 [firmware](../../firmware/README.md)，评委构建入口见 [构建与运行](../../docs/review/REPRODUCE.md)。

---

# rtl — MERGE16 / MERGE17 源码与时序资源

## merge17（定版）

- 位流：`v7_MERGE17.bit`，**SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`**，2,845,704 B。
- 内容：红外热图转置（144×192）+ WB B 增益默认 0x1C8；`rtl.diff`、`ti60f225_oob_top.v`、`v7_osd_overlay.v`、`tb_heat_rot.v`、`sim_log.txt`、`wave_transpose.png`。
- 资源/时序：`place.rpt`（XLR 42,857/60,800 = 70.49%、BRAM 189/256、DSP 67/160）、`timing_final.rpt`（最差 setup −0.984 ns、hold 7 条）。

## merge16

- 位流 `v7_MERGE16.bit`（SHA256 `81332CD1…1F8882`）、`apb_regs.md`（APB 寄存器表）、`rtl.diff`、时序/资源报告。

> RTL 源码本体在仓库 `rtl/mmt/`（自研模块）与 `evidence/v27_rtl_ir/`（MERGE15 快照）；本目录放定版位流与报告。
