# 生成 v7_MERGE1：队友 v7_camera_ai（SoC+TinyML）+ 我们的传感器/决策核心/OSD。全部按字节处理，不改编码与换行。
import os, shutil, sys
S = os.path.dirname(os.path.abspath(__file__)); SC = os.path.dirname(S)
SRC = os.path.join(SC, "tm", "project", "v7_camera_ai"); DST = os.path.join(SC, "v7_MERGE1")
S2 = os.path.join(SC, "sys2"); S5 = "/mnt/user-data/outputs/v7_sys5"
if os.path.exists(DST): shutil.rmtree(DST)
shutil.copytree(SRC, DST, ignore=lambda d, n: [x for x in n if x == "bitstream"])
os.makedirs(os.path.join(DST, "rtl", "v7", "mmt"), exist_ok=True); os.makedirs(os.path.join(DST, "rtl", "v7", "osd"), exist_ok=True)
core_s5 = ["v7_txt_fmt.v", "v7_pwr_ctl.v"]                     # SENSE5 的最新版
core_s2 = ["v7_bin2bcd.v", "v7_frame_diff.v", "v7_ir_proc.v", "v7_freeze_ctl.v"]
repo = ["mmt_dpram.v","mmt_i2c_hub.v","mmt_i2c_master.v","mmt_mlx90640_ctrl.v","mmt_sensor_subsystem.v",
        "mmt_sht30_ctrl.v","mmt_fusion_vote.v","mmt_alarm_ctrl.v","mmt_video_downscale.v"]
M = os.path.join(DST, "rtl", "v7", "mmt")
shutil.copy(os.path.join(S, "v7_mmt_core.v"), M)
for f in core_s5: shutil.copy(os.path.join(S5, f), M)
for f in core_s2: shutil.copy(os.path.join(SC, "sys2", f) if os.path.exists(os.path.join(SC, "sys2", f)) else os.path.join(S2, f), M)
for f in repo: shutil.copy(os.path.join(S2, "repo_rtl", f), M)
O = os.path.join(DST, "rtl", "v7", "osd")
shutil.copy(os.path.join(S2, "v7_osd_top.v"), O)
ov = open(os.path.join(S2, "v7_osd_overlay.v"), "rb").read()
assert ov.count(b'$readmemh("font8x16.hex", font_rom);') == 1
open(os.path.join(O, "v7_osd_overlay.v"), "wb").write(ov.replace(b'$readmemh("font8x16.hex", font_rom);', b'$readmemh("v7_font8x16.hex", font_rom);'))
shutil.copy(os.path.join(S2, "font8x16.hex"), os.path.join(DST, "v7_font8x16.hex"))
# ---- top.v（字节级）
p = os.path.join(DST, "rtl", "ti60f225_oob_top.v"); t = open(p, "rb").read()
anchor = b"       output [7:0] led,\n"; assert t.count(anchor) == 1
ports = (b"       input  wire io_sns_sda_IN,\n       output wire io_sns_sda_OUT,\n       output wire io_sns_sda_OE,\n"
         b"       input  wire io_sns_scl_IN,\n       output wire io_sns_scl_OUT,\n       output wire io_sns_scl_OE,\n"
         b"       output wire sns_buzzer,\n       input  wire key_night_n,\n       input  wire key_learn_n,\n")
t = t.replace(anchor, ports + anchor)
a = t.index(b"// OSD follows the existing gamma selector"); b = t.index(b"dvi_encoder dvi_encoder_m0"); assert a < b
new = b"""// ---- merged: pixels before OSD (same gamma select and R/B crossing as the original mmt_osd_demo input) ----
wire [7:0] enc_r_in = gamma_sel ? gamma_rdata : hdmi_tx_bdata;
wire [7:0] enc_g_in = gamma_sel ? gamma_gdata : hdmi_tx_gdata;
wire [7:0] enc_b_in = gamma_sel ? gamma_bdata : hdmi_tx_rdata;
wire       enc_de_in = gamma_sel ? gamma_valid : hdmi_tx_de;
wire       enc_hs_in = gamma_sel ? gamma_hs    : hdmi_tx_hs;
wire       enc_vs_in = gamma_sel ? gamma_vs    : hdmi_tx_vs;
wire [7:0] osd_r,osd_g,osd_b;
wire osd_de,osd_hs,osd_vs;
wire        mmt_alarm_active;
wire [1:0]  mmt_led;
wire        mmt_txt_we; wire [7:0] mmt_txt_wa, mmt_txt_wd;
wire        mmt_th_we;  wire [9:0] mmt_th_wa;  wire [7:0] mmt_th_wd;
// ai_person = person decision bit written by firmware (TinyML), APB reg9 bit0, 2-FF synced into hdmi_tx_slow_clk
v7_mmt_core #(.AI_MODE(1)) u_v7_mmt (
	.clk(hdmi_tx_slow_clk), .rst_n(vid_rst_n),
	.in_r(enc_r_in), .in_g(enc_g_in), .in_b(enc_b_in),
	.in_de(enc_de_in), .in_hs(enc_hs_in), .in_vs(enc_vs_in),
	.ai_person(osd_alarm_v2), .key_night_n(key_night_n), .key_learn_n(key_learn_n),
	.scl_i(io_sns_scl_IN), .sda_i(io_sns_sda_IN),
	.scl_o(io_sns_scl_OUT), .scl_oe(io_sns_scl_OE), .sda_o(io_sns_sda_OUT), .sda_oe(io_sns_sda_OE),
	.buzzer(sns_buzzer), .led(mmt_led), .alarm_active(mmt_alarm_active),
	.txt_we(mmt_txt_we), .txt_wa(mmt_txt_wa), .txt_wd(mmt_txt_wd),
	.th_we(mmt_th_we), .th_wa(mmt_th_wa), .th_wd(mmt_th_wd)
);
assign led[1] = mmt_led[1];
v7_osd_top u_v7_osd (
	.vclk   (hdmi_tx_slow_clk),
	.vrst_n (vid_rst_n),
	.i_r (enc_r_in), .i_g (enc_g_in), .i_b (enc_b_in),
	.i_de(enc_de_in), .i_hs(enc_hs_in), .i_vs(enc_vs_in),
	.o_r (osd_r), .o_g (osd_g), .o_b (osd_b),
	.o_de(osd_de), .o_hs(osd_hs), .o_vs(osd_vs),
	.alarm_in(mmt_alarm_active),
	.txt_we(mmt_txt_we), .txt_wa(mmt_txt_wa), .txt_wd(mmt_txt_wd),
	.th_we(mmt_th_we), .th_wa(mmt_th_wa), .th_wd(mmt_th_wd)
);

"""
t = t[:a] + new + t[b:]; open(p, "wb").write(t)
# ---- 工程 xml（CRLF）
p = os.path.join(DST, "ti60f225_oob.xml"); x = open(p, "rb").read()
anchor = b'        <efx:design_file name="rtl/mmt/osd/mmt_osd_demo.v" version="default" library="default" />\r\n'
assert x.count(anchor) == 1
files = ["rtl/v7/mmt/" + f for f in (["v7_mmt_core.v"] + core_s5 + core_s2 + repo)] + ["rtl/v7/osd/v7_osd_top.v", "rtl/v7/osd/v7_osd_overlay.v"]
add = "".join('        <efx:design_file name="%s" version="default" library="default"/>\r\n' % f for f in files).encode()
open(p, "wb").write(x.replace(anchor, anchor + add))
# ---- peri xml（LF）
p = os.path.join(DST, "ti60f225_oob.peri.xml"); x = open(p, "rb").read().decode("latin-1")
def inout(name, pin):
    return f'''        <efxpt:comp_gpio name="{name}" gpio_def="{pin}" mode="inout" bus_name="" io_standard="3.3 V LVCMOS">
            <efxpt:input_config name="{name}_IN" name_ddio_lo="" conn_type="normal" is_register="false" clock_name="" is_clock_inverted="false" pull_option="weak pullup" is_schmitt_trigger="false" ddio_type="none" is_bus_hold="false" delay="0" is_serial="false" is_dyn_delay="false" fastclk_name="" pullup_ena_name="{name}_PULL_UP_ENA" dyn_delay_en_name="{name}_DLY_ENA" dyn_delay_reset_name="{name}_DLY_RST" dyn_delay_ctrl_name="{name}_DLY_CTRL" clkmux_buf_name=""/>
            <efxpt:output_config name="{name}_OUT" name_ddio_lo="" register_option="none" clock_name="" is_clock_inverted="false" is_slew_rate="false" tied_option="none" ddio_type="none" delay="0" is_serial="false" drive_strength="2" fastclk_name=""/>
            <efxpt:output_enable_config name="{name}_OE" is_register="false" clock_name="" is_clock_inverted="false" name_oen="{name}_OEN"/>
        </efxpt:comp_gpio>
'''
def inp(name, pin):
    return f'''        <efxpt:comp_gpio name="{name}" gpio_def="{pin}" mode="input" bus_name="" io_standard="3.3 V LVCMOS">
            <efxpt:input_config name="{name}" name_ddio_lo="" conn_type="normal" is_register="false" clock_name="" is_clock_inverted="false" pull_option="weak pullup" is_schmitt_trigger="false" ddio_type="none" is_bus_hold="false" delay="0" is_serial="false" is_dyn_delay="false" fastclk_name="" pullup_ena_name="{name}_PULL_UP_ENA" dyn_delay_en_name="{name}_DLY_ENA" dyn_delay_reset_name="{name}_DLY_RST" dyn_delay_ctrl_name="{name}_DLY_CTRL" clkmux_buf_name=""/>
        </efxpt:comp_gpio>
'''
def outp(name, pin):
    return f'''        <efxpt:comp_gpio name="{name}" gpio_def="{pin}" mode="output" bus_name="" io_standard="3.3 V LVCMOS">
            <efxpt:output_config name="{name}" name_ddio_lo="" register_option="none" clock_name="" is_clock_inverted="false" is_slew_rate="false" tied_option="none" ddio_type="none" delay="0" is_serial="false" drive_strength="4" fastclk_name=""/>
        </efxpt:comp_gpio>
'''
anchor = '        <efxpt:comp_gpio name="led[0]"'
assert x.count(anchor) == 1
blk = inout("io_sns_scl", "GPIOL_11") + inout("io_sns_sda", "GPIOL_09") + outp("sns_buzzer", "GPIOR_13") + inp("key_night_n", "GPIOR_22") + inp("key_learn_n", "GPIOR_21")
open(p, "wb").write(x.replace(anchor, blk + anchor).encode("latin-1"))
print("OK", DST)
