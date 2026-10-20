"""P2b step 2: attach the TinyML accelerator to bridge lane 2.

- copies source/tinyml/*.v into the project and registers them in the XML
- declares the t_* AXI nets + cmd/rsp nets
- instantiates tinyml_accelerator_channels
- rewires the SoC's custom-instruction port from tie-offs to the accelerator
- rewires bridge lane2 from tie-offs to t_*
"""
import re
import shutil
from pathlib import Path

AI = Path(r"C:\Users\Makise Aohara\Documents\Codex\2026-10-15"
          r"\https-github-com-makiseaohara-fpga-104\work\peripherals-20261020\ai_ddr_09")
ROOT = Path(r"_p2a\v7_camera_ai")
TOP = ROOT / "rtl" / "ti60f225_oob_top.v"
XML = ROOT / "ti60f225_oob.xml"
ENC = "gb18030"

DECL = """
// ===================== P2b: TinyML 加速器（桥 lane2）=====================
wire [7:0]   t_awid;   wire [31:0] t_awaddr; wire [7:0] t_awlen;
wire [2:0]   t_awsize; wire [1:0]  t_awburst; wire [0:0] t_awlock;
wire [3:0]   t_awcache; wire [2:0] t_awprot;
wire [127:0] t_wdata;  wire [15:0] t_wstrb;  wire [0:0] t_wlast;
wire [7:0]   t_arid;   wire [31:0] t_araddr; wire [7:0] t_arlen;
wire [2:0]   t_arsize; wire [1:0]  t_arburst; wire [0:0] t_arlock;
wire [3:0]   t_arcache; wire [2:0] t_arprot;
wire [0:0]   t_awvalid, t_wvalid, t_bready, t_arvalid, t_rready;
wire [0:0]   t_awready, t_wready, t_arready, t_bvalid, t_rvalid, t_rlast;
wire [7:0]   t_bid, t_rid;
wire [1:0]   t_bresp, t_rresp;
wire [127:0] t_rdata;
wire         soc_cmd_valid, soc_cmd_ready, soc_rsp_valid, soc_rsp_ready, soc_cmd_int;
wire [9:0]   soc_cmd_function;
wire [31:0]  soc_cmd_a, soc_cmd_b, soc_rsp_data;
"""

ACCEL = """
tinyml_accelerator_channels #(.AXI_DW_M(128)) u_tinyml_accel(
 .clk(core_clk), .reset(soc_system_reset),
 .m_axi_clk(core_clk), .m_axi_rstn(!soc_system_reset),
 .cmd_valid(soc_cmd_valid), .cmd_ready(soc_cmd_ready),
 .cmd_function_id(soc_cmd_function),
 .cmd_inputs_0(soc_cmd_a), .cmd_inputs_1(soc_cmd_b),
 .cmd_int(soc_cmd_int),
 .rsp_valid(soc_rsp_valid), .rsp_ready(soc_rsp_ready),
 .rsp_outputs_0(soc_rsp_data),
 .m_axi_awid(t_awid), .m_axi_awaddr(t_awaddr), .m_axi_awlen(t_awlen),
 .m_axi_awsize(t_awsize), .m_axi_awburst(t_awburst), .m_axi_awlock(t_awlock),
 .m_axi_awcache(t_awcache), .m_axi_awprot(t_awprot),
 .m_axi_wdata(t_wdata), .m_axi_wstrb(t_wstrb), .m_axi_wlast(t_wlast),
 .m_axi_arid(t_arid), .m_axi_araddr(t_araddr), .m_axi_arlen(t_arlen),
 .m_axi_arsize(t_arsize), .m_axi_arburst(t_arburst), .m_axi_arlock(t_arlock),
 .m_axi_arcache(t_arcache), .m_axi_arprot(t_arprot),
 .m_axi_awvalid(t_awvalid), .m_axi_wvalid(t_wvalid), .m_axi_bready(t_bready),
 .m_axi_arvalid(t_arvalid), .m_axi_rready(t_rready),
 .m_axi_awready(t_awready), .m_axi_wready(t_wready),
 .m_axi_bresp(t_bresp), .m_axi_bvalid(t_bvalid),
 .m_axi_arready(t_arready),
 .m_axi_rdata(t_rdata), .m_axi_rresp(t_rresp),
 .m_axi_rlast(t_rlast), .m_axi_rvalid(t_rvalid)
);
"""

LANE2 = {
    "s_awid": "t_awid", "s_awaddr": "t_awaddr", "s_awlen": "t_awlen",
    "s_awsize": "t_awsize", "s_awburst": "t_awburst", "s_awlock": "t_awlock",
    "s_awcache": "t_awcache", "s_awprot": "t_awprot",
    "s_wdata": "t_wdata", "s_wstrb": "t_wstrb", "s_wlast": "t_wlast",
    "s_arid": "t_arid", "s_araddr": "t_araddr", "s_arlen": "t_arlen",
    "s_arsize": "t_arsize", "s_arburst": "t_arburst", "s_arlock": "t_arlock",
    "s_arcache": "t_arcache", "s_arprot": "t_arprot",
    "s_awvalid": "t_awvalid", "s_wvalid": "t_wvalid", "s_bready": "t_bready",
    "s_arvalid": "t_arvalid", "s_rready": "t_rready",
    "s_awready": "t_awready", "s_wready": "t_wready",
    "s_bid": "t_bid", "s_bresp": "t_bresp", "s_bvalid": "t_bvalid",
    "s_arready": "t_arready", "s_rid": "t_rid", "s_rdata": "t_rdata",
    "s_rresp": "t_rresp", "s_rlast": "t_rlast", "s_rvalid": "t_rvalid",
}


def copy_sources():
    dst = ROOT / "source" / "tinyml"
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in (AI / "source" / "tinyml").glob("*.v"):
        shutil.copy2(f, dst / f.name)
        n += 1
    print("copied %d tinyml sources -> source/tinyml" % n)

    x = XML.read_text(encoding=ENC)
    if "tinyml_accelerator_channels.v" in x:
        print("XML already lists tinyml sources")
        return
    inc = '        <efx:param name="include" value="source/tinyml" value_type="e_string" />\n'
    m = re.search(r'^[ \t]*<efx:param name="work_dir" value="work_syn"[^>]*/>\n', x, re.M)
    if not m:
        raise SystemExit("no synthesis work_dir param to anchor on")
    x = x[:m.end()] + inc + x[m.end():]

    files = "".join(
        '        <efx:design_file name="source/tinyml/%s" version="default" library="default"/>\n' % n
        for n in ("tinyml_defines.v", "tinyml_core0_define.v", "tinyml_top.v",
                  "tinyml_accelerator_channels.v", "tinyml_accelerator.v"))
    m2 = re.search(r'^[ \t]*<efx:design_file [^>]*/>\n', x, re.M)
    x = x[:m2.start()] + files + x[m2.start():]
    XML.write_text(x, encoding=ENC)
    print("XML: added include + 5 design_file entries")


def main():
    copy_sources()
    s = TOP.read_bytes().decode(ENC)

    # rewrite bridge lane2: first element of each multiconcat
    pat = re.compile(r"(\.(s_\w+)\s*\(\{)(tie0(?:_\d+)?|s_ign_\w+)(,)")
    hits = []

    def rep(m):
        port = m.group(2)
        if port in LANE2:
            hits.append(port)
            return m.group(1) + LANE2[port] + m.group(4)
        return m.group(0)

    s2 = pat.sub(rep, s)
    print("bridge lane2 rewired: %d ports" % len(hits))
    s = s2

    # SoC custom-instruction port: replace the tie-off block with real nets
    old_block = """.cpu0_customInstruction_cmd_valid(),
 .cpu0_customInstruction_cmd_ready(tie0),
 .cpu0_customInstruction_function_id(),
 .cpu0_customInstruction_inputs_0(),
 .cpu0_customInstruction_inputs_1(),
 .cpu0_customInstruction_rsp_valid(tie0),
 .cpu0_customInstruction_rsp_ready(),
 .cpu0_customInstruction_outputs_0(tie0_32),"""
    new_block = """.cpu0_customInstruction_cmd_valid(soc_cmd_valid),
 .cpu0_customInstruction_cmd_ready(soc_cmd_ready),
 .cpu0_customInstruction_function_id(soc_cmd_function),
 .cpu0_customInstruction_inputs_0(soc_cmd_a),
 .cpu0_customInstruction_inputs_1(soc_cmd_b),
 .cpu0_customInstruction_rsp_valid(soc_rsp_valid),
 .cpu0_customInstruction_rsp_ready(soc_rsp_ready),
 .cpu0_customInstruction_outputs_0(soc_rsp_data),"""
    if old_block not in s:
        raise SystemExit("SoC custom-instruction block not found (already patched?)")
    s = s.replace(old_block, new_block, 1)
    s = s.replace(".userInterruptA(tie0),", ".userInterruptA(soc_cmd_int),", 1)

    # declarations + accelerator instance
    anchor = "// ===================== P2a: SapphireSoC + 3-lane bridge =================="
    s = s.replace(anchor, DECL + anchor, 1)
    s = s.replace("SapphireSoc u_soc(", ACCEL + "\nSapphireSoc u_soc(", 1)

    TOP.write_bytes(s.encode(ENC))
    print("top: accelerator instantiated; SoC cmd port wired; decl added")


if __name__ == "__main__":
    main()
