# MERGE14 调试配置查找结果（2026-10-26，Claude 在 Kevin 电脑上查）

## 结论
1. `ti60f225_oob.xml`（MERGE14 工程）第 217 行引用 `debug_profile.wizard.json`，但该文件在 `D:\v7work\v7_MERGE14` 及其所有 out*/outflow*/work_* 目录里**都不存在**。不是漏传，是这份文件没有保留。
2. 仓库里登记的 `v7_MERGE14.bit`（SHA256 E399F990…41FE8）与 `D:\v7work\v7_MERGE14\out_run2\v7_MERGE14.bit` 的 SHA256 **完全一致**：板上位流来自 run2 这次编译。其余 out/ out_run1/ out_run3/ 的位流哈希都不同，不要用。
3. 本次编译实际生成的调试配置只有 `out_run2/debug_profile.mark_debug.json`（见 MERGE14_run2_debug_profile.mark_debug.json）：jtag_user=USER1，selected_nets 为空，capture_control=false，data_depth=1024。里面没有 VIO/LA 的 UUID 和探针清单。
4. 调试核是手写在 `debug_top.v` 里的，UUID 以源码为准：d2d3643a7f1e49a3a7f48b242e104fdd 与 40fc40c15a7b4e5392113defb86d2a4c。
5. `OLD_WBH1_debug_cores_NOT_MERGE14.json` 来自更早的 WBH 版本（vio0 UUID af5ad2e9…，la0 UUID cf5d5db3…，g_gain 初值 0xff），**UUID 与 MERGE14 不同，不能直接用**；放在这里只作参考：它说明那一代 VIO 有 r_gain/g_gain/b_gain/gamma_sel 四个探针，LA 有 ch0_g/ch0_b/ch0_de/cal_done。

## 对白平衡排查的含义
- 不需要再找 `debug_profile.wizard.json`：它不存在，继续等它没有意义。
- 若要通过 USER1 读写 VIO，应按 debug_top.v 里 UUID 为 d2d3…/40fc… 的两个核，自己写一份描述（探针名、位宽、初值取自 debug_top.v），不要沿用旧 WBH 的 UUID。
- 读回全 FF 也可能不是缺 profile，而是 TAP 序列或板上当前位流/调试核没有响应；需要先确认当前板上配置确实是 run2 的位流。
