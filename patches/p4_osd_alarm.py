"""P4 step 1: drive the OSD alarm border from the SoC's detection result.

Path:
  firmware writes APB reg 9 bit0
    -> registered in core_clk
    -> 2-FF synchroniser into the HDMI pixel clock domain
    -> mmt_osd_overlay.alarm (the red screen border)

mmt_osd_demo currently drives alarm from frame_count[7] (a slow demo blink);
that is replaced by a real input port.
"""
import re
from pathlib import Path

ROOT = Path(r"_p2a\v7_camera_ai")
TOP = ROOT / "rtl" / "ti60f225_oob_top.v"
DEMO = ROOT / "rtl" / "mmt" / "osd" / "mmt_osd_demo.v"
ENC = "gb18030"

# ---- 1. demo module: add the alarm port and use it ----
DEMO_OLD_PORT = "    input wire i_de,i_hs,i_vs,"
DEMO_NEW_PORT = "    input wire i_de,i_hs,i_vs,\n    input wire alarm,"
DEMO_OLD_USE = ".alarm(frame_count[7])"
DEMO_NEW_USE = ".alarm(alarm)"

# ---- 2. top: APB write register + CDC + hookup ----
TOP_REG_ANCHOR = "    4'd8: soc_apb_prdata = {31'd0, soc_system_reset};"

TOP_REG_NEW = """    4'd8: soc_apb_prdata = {31'd0, soc_system_reset};
    4'd9: soc_apb_prdata = {31'd0, osd_alarm_core};"""

TOP_CDC_ANCHOR = "always @* begin\n  case(soc_apb_paddr[5:2])"

TOP_CDC_NEW = """// ---- OSD alarm: APB write (core_clk) -> video clock domain ----
reg osd_alarm_core;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) osd_alarm_core <= 1'b0;
  else if(soc_apb_psel && soc_apb_penable && soc_apb_pwrite &&
          soc_apb_paddr[5:2]==4'd9)
    osd_alarm_core <= soc_apb_pwdata[0];
end
reg osd_alarm_v1, osd_alarm_v2;
always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if(!vid_rst_n) begin osd_alarm_v1 <= 1'b0; osd_alarm_v2 <= 1'b0; end
  else begin osd_alarm_v1 <= osd_alarm_core; osd_alarm_v2 <= osd_alarm_v1; end
end
always @* begin
  case(soc_apb_paddr[5:2])"""

TOP_HOOK_OLD = "    .o_de(osd_de),.o_hs(osd_hs),.o_vs(osd_vs));"
TOP_HOOK_NEW = "    .o_de(osd_de),.o_hs(osd_hs),.o_vs(osd_vs),\n    .alarm(osd_alarm_v2));"


def patch(path, pairs):
    s = path.read_bytes().decode(ENC)
    for old, new in pairs:
        if old not in s:
            raise SystemExit("anchor not found in %s: %r" % (path.name, old[:60]))
        s = s.replace(old, new, 1)
    path.write_bytes(s.encode(ENC))
    print("patched", path.name)


def main():
    patch(DEMO, [(DEMO_OLD_PORT, DEMO_NEW_PORT), (DEMO_OLD_USE, DEMO_NEW_USE)])
    patch(TOP, [
        (TOP_CDC_ANCHOR, TOP_CDC_NEW),
        (TOP_REG_ANCHOR, TOP_REG_NEW),
        (TOP_HOOK_OLD, TOP_HOOK_NEW),
    ])
    print("OSD alarm now driven by SoC APB reg 9")
    print("  firmware: *(volatile uint32_t*)0xF8100024 = detected ? 1 : 0;")


if __name__ == "__main__":
    main()
