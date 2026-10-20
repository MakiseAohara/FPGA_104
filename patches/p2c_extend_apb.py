"""Extend the SoC APB status block to the full 8-register map used by the firmware.

P2b only implemented registers 0..3, so the firmware's `ci` counter (register 6)
always read 0 -- which made the acceptance check report
MMT_AI_FAIL NO_HARDWARE_ACTIVITY even though the accelerator may have been
working.

Register map (matches the AI reference design):
  0 cal_done | 1 aw_cnt | 2 ar_cnt | 3 bridge_state
  4 t_aw_cnt | 5 t_ar_cnt | 6 ci_cnt | 7 irq_cnt
  8 soc_system_reset snapshot (diagnostic extra)
"""
import re
from pathlib import Path

TOP = Path(r"_p2a\v7_camera_ai\rtl\ti60f225_oob_top.v")
ENC = "gb18030"

OLD = """wire [2:0] bridge_state;
reg  [31:0] soc_aw_cnt, soc_ar_cnt;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) begin soc_aw_cnt <= 32'd0; soc_ar_cnt <= 32'd0; end
  else begin
    if(soc_awvalid && soc_awready) soc_aw_cnt <= soc_aw_cnt + 32'd1;
    if(soc_arvalid && soc_arready) soc_ar_cnt <= soc_ar_cnt + 32'd1;
  end
end
always @* begin
  case(soc_apb_paddr[5:2])
    4'd0: soc_apb_prdata = {31'd0, cal_done};
    4'd1: soc_apb_prdata = soc_aw_cnt;
    4'd2: soc_apb_prdata = soc_ar_cnt;
    4'd3: soc_apb_prdata = {29'd0, bridge_state};
    default: soc_apb_prdata = 32'd0;
  endcase
end"""

NEW = """wire [2:0] bridge_state;
reg  [31:0] soc_aw_cnt, soc_ar_cnt;
reg  [31:0] t_aw_cnt, t_ar_cnt, ci_cnt, irq_cnt;
reg  irq_prev;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) begin
    soc_aw_cnt <= 32'd0; soc_ar_cnt <= 32'd0;
    t_aw_cnt <= 32'd0; t_ar_cnt <= 32'd0;
    ci_cnt <= 32'd0; irq_cnt <= 32'd0; irq_prev <= 1'b0;
  end else begin
    if(soc_awvalid && soc_awready) soc_aw_cnt <= soc_aw_cnt + 32'd1;
    if(soc_arvalid && soc_arready) soc_ar_cnt <= soc_ar_cnt + 32'd1;
    if(t_awvalid && t_awready)     t_aw_cnt   <= t_aw_cnt + 32'd1;
    if(t_arvalid && t_arready)     t_ar_cnt   <= t_ar_cnt + 32'd1;
    if(soc_cmd_valid && soc_cmd_ready) ci_cnt  <= ci_cnt + 32'd1;
    if(soc_cmd_int && !irq_prev)       irq_cnt <= irq_cnt + 32'd1;
    irq_prev <= soc_cmd_int;
  end
end
always @* begin
  case(soc_apb_paddr[5:2])
    4'd0: soc_apb_prdata = {31'd0, cal_done};
    4'd1: soc_apb_prdata = soc_aw_cnt;
    4'd2: soc_apb_prdata = soc_ar_cnt;
    4'd3: soc_apb_prdata = {29'd0, bridge_state};
    4'd4: soc_apb_prdata = t_aw_cnt;
    4'd5: soc_apb_prdata = t_ar_cnt;
    4'd6: soc_apb_prdata = ci_cnt;
    4'd7: soc_apb_prdata = irq_cnt;
    4'd8: soc_apb_prdata = {31'd0, soc_system_reset};
    default: soc_apb_prdata = 32'd0;
  endcase
end"""


def main():
    s = TOP.read_bytes().decode(ENC)
    if OLD not in s:
        raise SystemExit("APB block not found (already extended?)")
    s = s.replace(OLD, NEW, 1)
    TOP.write_bytes(s.encode(ENC))
    print("APB map extended to 0..8 (ci_cnt on reg 6, irq_cnt on reg 7)")


if __name__ == "__main__":
    main()
