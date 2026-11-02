# 白平衡 RTL 改动（照此可恢复）

> 代码树在 `D:\v30_build\m17`（不进仓库），这里保存**准确的改动内容**，换机/换会话时照着加回即可。

## 1. `rtl/ti60f225_oob_top.v` — 新增 APB 字 19/20/21 译码（core_clk 域）

放在 `// ---- command issue (core_clk) ----` 之前：

```verilog
reg [15:0] wb_r_q, wb_g_q, wb_b_q;
always @(posedge core_clk or negedge w_arstn) begin
  if (!w_arstn) begin
    wb_r_q <= 16'd344;   // 0x1581.344x
    wb_g_q <= 16'd280;   // 0x1181.094x
    wb_b_q <= 16'd420;   // 0x1A41.641x
  end else if (soc_apb_psel && soc_apb_penable && soc_apb_pwrite) begin
    case (soc_apb_paddr[6:2])
      5'd19: wb_r_q <= soc_apb_pwdata[15:0];
      5'd20: wb_g_q <= soc_apb_pwdata[15:0];
      5'd21: wb_b_q <= soc_apb_pwdata[15:0];
      default: ;
    endcase
  end
```

## 2. `rtl/ti60f225_oob_top.v` — 彩色增益：VIO 优先、APB 兜底

```verilog
wire [15:0] wb_r_v = |r_gain ? r_gain : wb_r_q;
wire [15:0] wb_g_v = |g_gain ? g_gain : wb_g_q;
wire [15:0] wb_b_v = |b_gain ? b_gain : wb_b_q;

	.r_gain       (wb_r_v),
  .g_gain       (wb_g_v),
  .b_gain       (wb_b_v),
```

（原来写的是 `(|r_gain? r_gain:255)` 之类：无调试器时 VIO 恒 0 → 三通道都 255 → 完全不做白平衡。）

## 3. `rtl/debayer/debayer_top_2to1.v` — R/B 增益接反修正

```verilog
	.gain_b (b_gain		),   // MERGE21: e/ (r_gain)R/B Ê¥Í
	.gain_g (g_gain		),
	.gain_r (r_gain		),   // MERGE21: e/ (b_gain)
```

原为 `.gain_b (r_gain)` / `.gain_r (b_gain)`（接反）。

改完必须重出位流才生效：本次产物 `v7_MERGE21_WB.bit`（2,806,104 B / `D165EDCA7A2272CB1AE682966BC25D38C800AFF85803C65D048003BCCE4C5AEE`）。
