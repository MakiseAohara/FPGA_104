module debayer_top_2to1
(
	input			in_pclk,
	input			in_rstn,
	
	input			raw_vs_i,
	input			raw_hs_i,
	input			raw_de_i,
	input			raw_valid_i,
	input	[15:0]	raw_datax4_i,
	input [15:0] r_gain,
	input [15:0] g_gain,
	input [15:0] b_gain,
	
	output				rgb_vs_o,
	output				rgb_hs_o,
	output				rgb_de_o,
	output				rgb_valid_o,
	output [15:0] 	rgb_bout,
	output [15:0] 	rgb_gout,
	output [15:0] 	rgb_rout,
	output	[24*2-1:0]	rgb_datax2_o, //b,g,r,b,g,r

	// MERGE16: 白平衡前（rgb_gain 之前）中心区域通道统计
	output wire [31:0] wb_sum_r,
	output wire [31:0] wb_sum_g,
	output wire [31:0] wb_sum_b,
	output wire [31:0] wb_pix,
	output wire [31:0] wb_sat,
	output wire        wb_tgl
);

wire	        w_gain_vs;
wire	        w_gain_hs;
wire	        w_gain_ah;
wire	        w_gain_de;
wire	[15:0]	w_gain_data;

// ---------------------------------------------------------------------------
// MERGE16: 复制 rgb_gain_v1 内部的行奇偶判定（r_line_cnt），供通道统计使用。
//   行 A（parity=0）：high=G, low=B；行 B（parity=1）：high=R, low=G
//   （与修正后的 gain 接线一致，见 docs/交接文档-2026-10-20.md §3 Bug 3/4）
// ---------------------------------------------------------------------------
reg wb_vs_1P, wb_de_1P, wb_valid_1P, wb_line_parity;
always @(posedge in_pclk or negedge in_rstn) begin
	if (!in_rstn) begin
		wb_vs_1P <= 1'b0; wb_de_1P <= 1'b0; wb_valid_1P <= 1'b0; wb_line_parity <= 1'b0;
	end else begin
		wb_vs_1P    <= raw_vs_i;
		wb_de_1P    <= raw_de_i;
		wb_valid_1P <= raw_valid_i;
		if (wb_vs_1P && !raw_vs_i)
			wb_line_parity <= 1'b0;
		else if (wb_valid_1P && wb_de_1P && (!raw_de_i))
			wb_line_parity <= ~wb_line_parity;
	end
end

v7_wb_stat #(.H_ACTIVE(1920), .V_ACTIVE(1080)) u_wb_stat (
	.clk(in_pclk), .rst_n(in_rstn),
	.vs(raw_vs_i), .hs(raw_hs_i), .de(raw_de_i), .valid(raw_valid_i),
	.data(raw_datax4_i),
	.line_parity(wb_line_parity),
	.sum_r(), .sum_g(), .sum_b(), .pix_cnt(), .sat_cnt(),
	.out_sum_r(wb_sum_r), .out_sum_g(wb_sum_g), .out_sum_b(wb_sum_b),
	.out_pix(wb_pix), .out_sat(wb_sat), .frame_tgl(wb_tgl)
);

rgb_gain_v1
#(
	.P_DEPTH(8	),
	.Q_WIDTH(16	)
)
inst_rgb_gain
(
	.i_pclk		(in_pclk		),
	.i_arstn	(in_rstn		),
	.i_hs		(raw_hs_i		),
	.i_vs		(raw_vs_i		),
	.i_de		(raw_de_i		),
	.i_valid	(raw_valid_i	),
	.i_data		(raw_datax4_i	),

	
	.gain_b (r_gain		),
	.gain_g (g_gain		),
	.gain_r (b_gain		),
	
	.o_hs		(w_gain_hs		),
	.o_vs		(w_gain_vs		),
	.o_de		(w_gain_ah		),
	.o_valid	(w_gain_de	    ),
	.o_data		(w_gain_data	)
);

		
		wire	    	w_debayer_lb_hs;
		wire	    	w_debayer_lb_vs;
		wire	    	w_debayer_lb_ah;
		wire	    	w_debayer_lb_de;
		wire	[15:0]	w_debayer_lb_p_11;
		wire	[15:0]	w_debayer_lb_p_00;
		wire	[15:0]	w_debayer_lb_p_01;

		line_buffer
		#(
			.P_DEPTH	(8),
			.X_CNT_WIDTH(10)
		)
		inst_line_buffer_debayer
		(
			.i_arstn	(in_rstn	),
			.i_pclk		(in_pclk	),
			
			.i_vsync	(w_gain_vs),	//(raw_vs_i		),//					
			.i_hsync	(w_gain_hs),	//(raw_hs_i		),//
			.i_de		(w_gain_de),	//(raw_de_i		),//
			.i_valid	(w_gain_de),	//(raw_valid_i	),//
			.i_p		({w_gain_data[7:0],w_gain_data[15:8]}),	//(raw_datax4_i	),//
			
			.o_vsync	(w_debayer_lb_vs  ),
			.o_hsync	(w_debayer_lb_hs  ),
			.o_de		(w_debayer_lb_de  ),
			.o_valid	(w_debayer_lb_ah  ),
			.o_p_11		(w_debayer_lb_p_11),
			.o_p_00		(w_debayer_lb_p_00),
			.o_p_01		(w_debayer_lb_p_01)
		);
		wire	w_debayer_hs;
		wire	w_debayer_vs;
		wire	w_debayer_ah;
		wire	w_debayer_de;
		wire	[10:0]	w_debayer_x;
		wire	[10:0]	w_debayer_y;
		wire	[15:0]	w_debayer_r;
		wire	[15:0]	w_debayer_g;
		wire	[15:0]	w_debayer_b;
		raw_to_rgb
		#(
			.P_DEPTH	(8),
			.LEGACY		(1'b1)
		)
		inst_raw_to_rgb
		(
			.i_arstn	(in_rstn	),
			.i_pclk		(in_pclk	),
			
			.i_vsync	(w_debayer_lb_vs),
			.i_hsync	(w_debayer_lb_hs),
			.i_de		(w_debayer_lb_de),
			.i_valid	(w_debayer_lb_ah),
			.i_p_11		(w_debayer_lb_p_11),
			.i_p_00		(w_debayer_lb_p_00),
			.i_p_01		(w_debayer_lb_p_01),
			
			
			.o_vsync	(w_debayer_vs),
			.o_hsync	(w_debayer_hs),
			.o_de		(w_debayer_ah),
			.o_valid	(w_debayer_de),
			.o_x_cnt	(w_debayer_x),
			.o_y_cnt	(w_debayer_y),
			.o_r		(w_debayer_r),
			.o_g		(w_debayer_g),
			.o_b		(w_debayer_b)
		);	
		
	assign		rgb_vs_o 		= w_debayer_vs;	
	assign		rgb_hs_o 		= w_debayer_hs;	
	assign		rgb_de_o 		= w_debayer_ah;	
	assign		rgb_valid_o 	= w_debayer_de;	
	assign 		rgb_bout  		= w_debayer_b;
	assign 		rgb_gout  		= w_debayer_g;
	assign 		rgb_rout  		= w_debayer_r;

	assign		rgb_datax2_o 	= {	w_debayer_b[15:8],w_debayer_g[15:8],w_debayer_r[15:8],
									w_debayer_b[ 7:0],w_debayer_g[ 7:0],w_debayer_r[ 7:0]};	
endmodule
