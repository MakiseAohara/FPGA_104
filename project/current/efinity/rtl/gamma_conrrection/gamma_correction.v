// gamma_correction (8-bit path only): 3x 512x8 BRAM lookup, 1-cycle latency.
// Table = old 1024x10 curve sampled at {v,v[7:6]} and [9:2]; upper 256 entries = 0 (selected when i_valid=0).
module gamma_correction
#(
	parameter	DATA_WIDTH	= 8,
	parameter 	GAMMA_CURVE	= "2P2.mem"
)
(
	input						i_pclk,
	input						i_rstn,
	input 						i_valid,
	input 						i_hs,
	input 						i_vs,
	input 	[DATA_WIDTH-1:0]	i_red,
	input 	[DATA_WIDTH-1:0]	i_green,
	input 	[DATA_WIDTH-1:0]	i_blue,
	output	[DATA_WIDTH-1:0]	o_red,
	output	[DATA_WIDTH-1:0]	o_green,
	output	[DATA_WIDTH-1:0]	o_blue,
	output	reg					o_valid,
	output  reg  				o_hs,
	output 	reg 				o_vs
);
localparam GF = "./rtl/gamma_conrrection/gamma8.mem";
wire nv = ~i_valid;
true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(9),.WRITE_MODE_1("READ_FIRST"),.WRITE_MODE_2("READ_FIRST"),.OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE(GF))
 u_r(.we1(1'b0),.we2(1'b0),.clka(i_pclk),.clkb(1'b0),.din1(8'd0),.din2(8'd0),.addr1({nv,i_red}),.addr2(9'd0),.dout1(o_red),.dout2());
true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(9),.WRITE_MODE_1("READ_FIRST"),.WRITE_MODE_2("READ_FIRST"),.OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE(GF))
 u_g(.we1(1'b0),.we2(1'b0),.clka(i_pclk),.clkb(1'b0),.din1(8'd0),.din2(8'd0),.addr1({nv,i_green}),.addr2(9'd0),.dout1(o_green),.dout2());
true_dual_port_ram #(.DATA_WIDTH(8),.ADDR_WIDTH(9),.WRITE_MODE_1("READ_FIRST"),.WRITE_MODE_2("READ_FIRST"),.OUTPUT_REG_1("FALSE"),.OUTPUT_REG_2("FALSE"),.RAM_INIT_FILE(GF))
 u_b(.we1(1'b0),.we2(1'b0),.clka(i_pclk),.clkb(1'b0),.din1(8'd0),.din2(8'd0),.addr1({nv,i_blue}),.addr2(9'd0),.dout1(o_blue),.dout2());
always @(posedge i_pclk) begin
	if (~i_rstn) begin o_valid<=1'b0; o_hs<=1'b0; o_vs<=1'b0; end
	else begin o_valid<=i_valid; o_hs<=i_hs; o_vs<=i_vs; end
end
endmodule
