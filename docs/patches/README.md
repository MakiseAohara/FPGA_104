# 厂商 IP 的 4 个颜色 bug —— 补丁说明

ALL_FIXES.diff 是合并版，单独文件是分项版。**基准**：Ti60f225_sc431hai2hdmi_v7（厂商原版）。

## 应用顺序（相对厂商原版一次性全部应用）

| 文件 | 改动 | 行号 |
|---|---|---|
| tl\debayer\debayer_top_2to1.v | .i_p (w_gain_data) → .i_p ({w_gain_data[7:0],w_gain_data[15:8]}) | L85 |
| tl\debayer\debayer_top_2to1.v | .gain_b (r_gain) → .gain_b (b_gain)；.gain_r (b_gain) → .gain_r (r_gain) | L51/L53 |
| tl\debayer\raw_to_rgb.v | L396 w_r_00_00_h0 ↔ L398 w_b_00_00_h0 两行互换 | L396/L398 |
| tl\debayer\rgb_gain_v1.v | if (r_line_cnt) → if (!r_line_cnt) | L68 |
| debug_top.v | VIO 初值 → R='h158 / G='h118 / B='h1A0（WBH6）或 'h170（WBH7） | L102/L104 |

## 各 bug 的作用

1. **字节交换缺失** ⇒ 像素奇偶错 ⇒ 拜耳相位偏一列 ⇒ 紫 + 网格
2. **raw_to_rgb 396/398 对调** ⇒ T0 高位 G 点的 R/B 插值错 ⇒ 蓝点
3. **增益接线错配** ⇒ 调 b_gain 画面变红
4. **增益级行奇偶差一行** ⇒ G 像素吃到 B/R 增益 ⇒ 马赛克 + 绿点

## 验证链

X → 紫变绿；XZ → 蓝点消失；XZL → 马赛克/绿点消失（里程碑）；WBF → 调参方向正确。

详见 docs/evidence/v7_phase_flash.md。