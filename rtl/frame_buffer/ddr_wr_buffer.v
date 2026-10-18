
module ddr_wr_buffer#(
    parameter AXI_DATA_WIDTH = 512, //!AXI接口位宽
    parameter AXI_ADDR_WIDTH = 33,  //!AXI地址位宽
    parameter WR_FIFO_DEPTH	= 1024, //!Write fifo depth   
    parameter AXI_STRB_WIDTH = AXI_DATA_WIDTH/8,//!总共的字节数量，= AXI_DATA_WIDTH/8
    parameter BURST_LEN       = 15,
    parameter AXSIZE_WTH = clogb2(AXI_DATA_WIDTH/8)//,//!内部数据
    
    
    )(
        
input 								        axi_clk,
input 								        rst_n,
input								        wr_start, // pulse signal 

input		[AXI_ADDR_WIDTH-1:0]	        start_addr,
input		[24:0]							burst_len,
input wire                                  bank_sw_ack	,
output   wire                                 bank_sw 		  ,
output		[7:0] test_cnt ,
output		[31:0] dbg_sb ,
input                                       wr_fifo_rst_p,
input										wr_fifo_wrclk,
input										wr_fifo_wren,
output										wr_fifo_wrfull,
input	 [AXI_DATA_WIDTH-1:0]		        wr_fifo_wrdata, 

output 	[5:0] 								awid,
output  [AXI_ADDR_WIDTH-1:0] 	            awaddr,
output  [8-1:0] 				awlen,
output  [2:0] 					            awsize,
output  [1:0] 								awburst,

output  									awlock,
(* preserve, syn_keep = 1 *) output  reg 	awvalid = 'd0,  // ★ 2026-10-12：必须保留！（Efinity 2026.1 会把本写通道整条折成常量，见 Z5 实验）
output  									awcobuf,
output  									awapcmd,
output  									awallstrb,
output  									awqos,
output  [3:0] 								awcache,
output [2:0]                                awprot,
input 										awready,


output  [AXI_DATA_WIDTH-1:0] 	            wdata,  
output  [AXI_STRB_WIDTH-1:0] 	            wstrb,
output  reg									wlast,
(* preserve, syn_keep = 1 *) output  reg		wvalid,  // ★ 必须保留！
input 										wready,
input [5:0] 								bid,
input 										bvalid,
output  									bready

    );
//=================================================================================

    localparam WR_ADDR_SHIFT_BITS = clogb2(AXI_STRB_WIDTH);
    localparam MAX_BURST_LEN = 4096/(AXI_DATA_WIDTH/8);
    parameter WR_USEDW_WITH = clogb2(WR_FIFO_DEPTH); //!内部数据
    //=============================================================
    //reg define 
    //=============================================================   
    
    
    reg	[AXI_ADDR_WIDTH-1:0] 			                    ddr_wr_addr 	= 'd0;
    
    wire										 			burst_add_en ;
    reg	[8-1:0]							    ddr_awlen = 0;
    reg	    	[1:0]							                start_sync = 'd0;
    reg [24:0]	burst_len_r   = 'd0;
   
    reg														burst_last = 'd0;      
    reg	[8-1:0] 						                    last_burst_cnt = 'd0;
    reg [8-1:0]                                             first_burst_cnt = 'd0;
    (* preserve, syn_keep = 1 *) reg                                                     sync_r1 = 1'b0;
    (* preserve, syn_keep = 1 *) reg                                                     sync_r0 = 1'b0;
    (* preserve, syn_keep = 1 *) reg                                                     sync_r2 = 1'b0;
    reg                                                     sync_r3 = 1'b0;
    reg [24:0]                                              align_burst_num = 'd0;
    reg [24:0]                                              burst_num = 'd0;
    reg [24:0]                                              total_burst_num = 'd0;
    reg [AXI_ADDR_WIDTH-1:0]                                start_addr_r = 'd0;
    //=============================================================
    //wire define 
    //============================================================= 
    wire   [ WR_USEDW_WITH:0] 		wr_fifo_rdusedw;
wire [AXI_DATA_WIDTH-1:0]		wr_fifo_rddata;
wire							wr_fifo_rdempty;  
wire							wr_fifo_rden;
wire 							pos_sync;
wire [AXI_ADDR_WIDTH-1:0]  		nx_ddr_wr_addr;
wire axi_wr_clk = axi_clk;
//=============================================================  
//RTL                                                     
//=============================================================  

	DC_FIFO
# (
  	.FIFO_MODE  ( "Normal"    ), //"Normal"; //"ShowAhead"
    .DATA_WIDTH ( AXI_DATA_WIDTH ),
    .FIFO_DEPTH ( WR_FIFO_DEPTH   )
  ) u_wr_fifo(   
  //System Signal
  /*i*/.Reset   (wr_fifo_rst_p	    ), 
  /*i*/.WrClk   (wr_fifo_wrclk		), 
  /*i*/.WrEn    (wr_fifo_wren		), 
  /*o*/.WrDNum  (wr_fifo_wrusedw	), 
  /*o*/.WrFull  (wr_fifo_wrfull 	), 
  /*i*/.WrData  (wr_fifo_wrdata 	), 
  /*i*/.RdClk   (axi_clk			), 
  /*i*/.RdEn    (wr_fifo_rden		), 
  /*o*/.RdDNum  (wr_fifo_rdusedw	), 
  /*o*/.RdEmpty (wr_fifo_rdempty	), 
  /*o*/.RdData  (wr_fifo_rddata		)  
);

assign wr_fifo_rd_data_test =  wr_fifo_rddata[31:0];

always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n )		start_sync <= 'd0;
    else 			start_sync <= {start_sync[0],wr_start};
end

assign pos_sync = start_sync[1:0] == 2'b01;
//each frame before have enogh time
always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n ) begin
		sync_r0 <= 1'b0;
		sync_r1 <= 1'b0;
		sync_r2 <= 1'b0;
        sync_r3 <= 1'b0;
	end else begin 
		sync_r0 <= pos_sync;
		sync_r1 <= sync_r0;
		sync_r2 <= sync_r1;
        sync_r3 <= sync_r2;
	end 
end

always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n ) begin
		burst_len_r   <= burst_len;//end_address - start_address
        start_addr_r <= start_addr;
	end else begin
		burst_len_r   <= pos_sync ? burst_len : burst_len_r ;
        start_addr_r <= pos_sync ? start_addr:start_addr_r;
	end
end


  
wire [12-WR_ADDR_SHIFT_BITS:0]     first_4k_burst_len = {1'b0,~start_addr_r[11:WR_ADDR_SHIFT_BITS]} + 1'b1;
wire [31:0]     last_4k_burst_len  = burst_len_r - first_4k_burst_len;



generate
    if( BURST_LEN == 1)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[0]  ? {7'd0,first_4k_burst_len[0]}-'d1  :BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[0]  ? {7'd0,last_4k_burst_len[0]}-1  :BURST_LEN;
            burst_num <= align_burst_num[24:1] + 2 ;
        end 
    else if( BURST_LEN == 3 )
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[1:0]? {6'd0,first_4k_burst_len[1:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[1:0]? {6'd0,last_4k_burst_len[1:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:2] + 2 ;
        end 
    else if( BURST_LEN == 7)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[2:0]? {5'd0,first_4k_burst_len[2:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[2:0]? {5'd0,last_4k_burst_len[2:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:3] + 2 ;
        end 
    else if( BURST_LEN == 15)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[3:0]? {4'd0,first_4k_burst_len[3:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[3:0]? {4'd0,last_4k_burst_len[3:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:4] + 2 ;
        end 
    else if( BURST_LEN == 31)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[4:0]? {3'd0,first_4k_burst_len[4:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[4:0]? {3'd0,last_4k_burst_len[4:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:5] + 2 ;
        end 
    else if( BURST_LEN == 63)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[5:0]? {2'd0,first_4k_burst_len[5:0]}-'d1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[5:0]? {2'd0,last_4k_burst_len[5:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:6] + 2 ;
        end 
    else if( BURST_LEN == 127)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[6:0]?{1'd0,first_4k_burst_len[6:0]}-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[6:0]? {1'd0,last_4k_burst_len[6:0]}-1:BURST_LEN;
            burst_num <= align_burst_num[24:7] + 2 ;
        end 
    else if( BURST_LEN == 255)
        always @( posedge axi_clk )
        begin
            first_burst_cnt <= |first_4k_burst_len[7:0]?first_4k_burst_len[7:0]-1:BURST_LEN;
            last_burst_cnt <= |last_4k_burst_len[7:0]? last_4k_burst_len[7:0]-1:BURST_LEN;
            burst_num <= align_burst_num[24:8] + 2 ;
        end 

endgenerate


always @( posedge axi_clk or negedge rst_n   )
begin 
    if( !rst_n ) begin
        align_burst_num <= 'd0;
    end else begin //sync_r1;
	    align_burst_num <= burst_len_r - first_burst_cnt - last_burst_cnt -2 ;
    end 
end

// always @( posedge axi_clk or negedge rst_n   )
// begin
//     if( !rst_n ) begin
//         burst_num <= 'd0;
//     end else begin 
// 		if(sync_r2) begin
// 		case( cfg_alen_r)
// 			8'd1 : burst_num <= align_burst_num[24:1] + 2 ;
// 			8'd3 : burst_num <= align_burst_num[24:2] + 2 ;
// 			8'd7 : burst_num <= align_burst_num[24:3] + 2 ;
// 			8'd15: burst_num <= align_burst_num[24:4] + 2 ;
// 			8'd31: burst_num <= align_burst_num[24:5] + 2 ;
// 			8'd63: burst_num <= align_burst_num[24:6] + 2 ;
//             8'd127: burst_num <= align_burst_num[24:7] + 2 ;
//             8'd255: burst_num <= align_burst_num[24:8] + 2 ;
// 			default:;
// 		endcase
// 		end 
//     end 
// end 		
//=======================================================================================
//address process
reg addr_add_en = 'd0;
reg addr_add_last = 'd0;
reg [31:0] addr_cnt_num = 'd0;
always @(posedge axi_clk or negedge rst_n) 
begin
	if (!rst_n) 						                        ddr_wr_addr <= start_addr_r;//start_addr;
	else if(sync_r2)				                            ddr_wr_addr <= start_addr_r;//start_addr;//( pos_sync )
    // else if(addr_add_en &addr_add_last)                         ddr_wr_addr <= start_addr_r;
	else if( addr_add_en ) 				                        ddr_wr_addr <= nx_ddr_wr_addr;
end      
assign nx_ddr_wr_addr =  ddr_wr_addr + {(ddr_awlen+1) ,{WR_ADDR_SHIFT_BITS{1'b0}}};  
always @( posedge axi_clk or negedge rst_n )
begin
 	if( !rst_n )  							                    addr_cnt_num <= 'd0;
 	else if(sync_r2)					                        addr_cnt_num <= 'd0;//( pos_sync )
    // else if( addr_add_en & addr_add_last)                       addr_cnt_num <= 'd0;
 	else if( addr_add_en )					                    addr_cnt_num <= addr_cnt_num + 1'b1;
end 
always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n )										        addr_add_last <= 1'b0;
	else if(sync_r2)						                    addr_add_last <= 1'b0;	//( pos_sync )	
	else if(addr_add_en && burst_num == addr_cnt_num+'d2  ) 	addr_add_last <= 1'b1;
    else if(addr_add_en && burst_num == addr_cnt_num+'d1  )     addr_add_last <= 1'b0;
end 

always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n )                                                addr_add_en <= 1'b0;
    else if( awvalid & awready )                                addr_add_en <= 1'b1;
    else                                                        addr_add_en <= 1'b0;
end     


//=============================================================================================

//burst process
always @( posedge axi_clk or negedge rst_n )
begin
 	if( !rst_n )  							total_burst_num <= 'd0;
 	else if(sync_r2)					    total_burst_num <= 'd0;//( pos_sync )
    // else if( burst_add_en & burst_last)     total_burst_num <= 'd0;
 	else if( burst_add_en )					total_burst_num <= total_burst_num + 1'b1;
end 
always @( posedge axi_clk or negedge rst_n  )
begin
    if( !rst_n ) 								                ddr_awlen 	<= BURST_LEN;//cfg_alen;
    else if( sync_r2 )						                    ddr_awlen 	<= first_burst_cnt;	 
    // else if( burst_add_en & burst_last)                         ddr_awlen   <= first_burst_cnt;
    else if(burst_add_en && burst_num == total_burst_num+2)		ddr_awlen	<= last_burst_cnt;
    else if( burst_add_en )						                ddr_awlen 	<= BURST_LEN;//cfg_alen_r;	
end


always @( posedge axi_clk or negedge rst_n )
begin
	if( !rst_n )										            burst_last <= 1'b0;
	else if(sync_r2)						                    burst_last <= 1'b0;	//( pos_sync )	
	else if(burst_add_en && burst_num == total_burst_num+'d2  ) burst_last <= 1'b1;
    else if(burst_add_en && burst_num == total_burst_num+'d1 )  burst_last <= 1'b0;
end 
assign bank_sw = burst_last;

//======================================================================================================
(* preserve, syn_keep = 1 *) reg [1:0] state = 2'd0;  // ★ 必须保留！
(* preserve, syn_keep = 1 *) reg wr_req = 0;          // ★ 必须保留！
always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n )
        wr_req <= 1'b0;
    else if( wr_fifo_rdusedw > ddr_awlen )
        wr_req <= 1'b1;
    else 
        wr_req <= 1'b0;
end
// reg [1:0] pre_state = 'd0;
// reg [1:0] nx_state = 'd0;
// always @( posedge axi_clk or negedge rst_n )
// begin
//     if( !rst_n )
//         pre_state <= 'd0;
//     else 
//         pre_state <= nx_state;
// end 

// always @( * )
// begin
//     if( !rst_n ) begin
//         nx_state = 'd0;
//         wvalid = 1'b0;
//         awvalid = 1'b0;
//     end else if( sync_r0 ) begin
//         nx_state = 'd0;
//         wvalid = 1'b0;
//         awvalid = 1'b0;
//     end else begin
//         case( pre_state )
//         2'd0 : begin
//             if( sync_r2 ) begin
//                 nx_state = 2'd1;
//             end else begin
//                 nx_state = 2'd0;
//             end
//             wvalid = 1'b0;
//             awvalid = 1'b0;
//         end
//         2'd1 : begin
//             if( wr_req )begin
//                 nx_state = 2'd2 ;
//                 awvalid = 1'b1;
//             end else begin
//                 nx_state = 2'd1;
//                 awvalid <= 1'b0;
//             end
//             wvalid = 1'b0; 
//         end
//         2'd2 : begin
//             if( awready & awvalid) begin
//                 nx_state = 2'd3 ;
//                 awvalid = 1'b0;
//                 wvalid = 1'b1;
//             end else begin
//                 nx_state =  2'd2;
//                 awvalid = 1'b1;
//                 wvalid = 1'b0;
//             end

//         end
//         2'd3 : begin
//             if( wvalid & wlast & wready )
//             begin
//                 nx_state = 2'd1 ;
//                 wvalid = 1'b0;
//                 awvalid = 1'b0;
//             end else begin
//                 nx_state = 2'd3;
//                 wvalid = 1'b1;
//                 awvalid = 1'b0;
//             end
//         end
//         default : begin
//             nx_state = 2'd0;
//             wvalid = 1'b0;
//             awvalid = 1'b0;
//         end
//         endcase
//     end
// end


always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n ) begin
        awvalid <= 1'b0;
        wvalid <= 1'b0;
        state <= 'd0;
    end else if( sync_r0 && state == 2'd0 ) begin
        // ★ 2026-10-18 修复：原来是 `else if (sync_r0)`——sync_r0 是 pos_sync 的 1 拍延迟、
        //   sync_r2 是 3 拍延迟，而 sync_r0 这一支【优先级高于 case】，于是每帧 sync_r0
        //   都把 state/awvalid 强行清零，把写 FSM 按在 state 0 打转。
        //   实测（ice=0 位流 + 串口 0xE0 通道）：pos_sync_cnt=15、sync_r0_cnt=15、
        //   sync_r2_cnt=15 全饱和、wr_req=1、写 FIFO 近满，但 state 恒为 0、AW 握手 0 次。
        //   修复：只在【空闲态】做这次清零（state==0 时清零本身无副作用），
        //   不再打断 1/2/3 态正在进行的传输。
        awvalid <= 1'b0;
        wvalid <= 1'b0;
        state <= 'd0;
    end else begin
        case(state )
        2'd0 : begin
            if( sync_r2) 
                state <= 2'd1;
        end
        2'd1 : begin
            if( wr_req ) begin
                state <= 2'd2;
                awvalid <= 1'b1;
            end
            wvalid <= 1'b0;   
        end
        2'd2 : begin
            if( awready) begin
                state <= 2'd3;
                awvalid <= 1'b0;
                wvalid <= 1'b1;
            end 
        end
        2'd3 : begin
            if( wvalid & wlast & wready ) begin
                wvalid <= 1'b0;
                state <= 2'd1;
            end
        end
        default : ;
    
        endcase
    end
end
//======================================================================================================
// 调试观测（纯观测，不参与任何功能逻辑）：写 FSM 粘滞"曾经发生过"标志，axi_clk 域，rst_n 清零
// dbg_sb 位定义：见下方 assign dbg_sb 处的新位表（2026-10-15 已重排）
(* preserve, syn_keep = 1 *) reg [25:0] free_cnt = 26'd0;
(* preserve, syn_keep = 1 *) reg [3:0]  pos_sync_cnt = 4'd0;
always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n ) begin
        free_cnt     <= 26'd0;
        pos_sync_cnt <= 4'd0;
    end else begin
        free_cnt <= free_cnt + 26'd1;
        if( pos_sync && pos_sync_cnt != 4'hF ) pos_sync_cnt <= pos_sync_cnt + 4'd1;
    end
end
(* preserve, syn_keep = 1 *) reg sb_pos_sync   = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_st1        = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_wrreq      = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_st2        = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_awready    = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_rdusedw_nz = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_rden       = 1'b0;
(* preserve, syn_keep = 1 *) reg sb_st3        = 1'b0;
always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n ) begin
        sb_pos_sync   <= 1'b0;
        sb_st1        <= 1'b0;
        sb_wrreq      <= 1'b0;
        sb_st2        <= 1'b0;
        sb_awready    <= 1'b0;
        sb_rdusedw_nz <= 1'b0;
        sb_rden       <= 1'b0;
        sb_st3        <= 1'b0;
    end else begin
        if( pos_sync )                  sb_pos_sync   <= 1'b1;
        if( state == 2'd1 )             sb_st1        <= 1'b1;
        if( wr_req )                    sb_wrreq      <= 1'b1;
        if( state == 2'd2 )             sb_st2        <= 1'b1;
        if( awready )                   sb_awready    <= 1'b1;
        if( wr_fifo_rdusedw != 0 )      sb_rdusedw_nz <= 1'b1;
        if( wr_fifo_rden )              sb_rden       <= 1'b1;
        if( state == 2'd3 )             sb_st3        <= 1'b1;
    end
end
// 2026-10-15 "state 恒 0" 定位用观测（纯观测，不改任何功能逻辑）：
//   依据：wr_start 每帧只有一个上升沿 ⇒ pos_sync 单拍 ⇒ 按 RTL 语义 sync_r0 抢占不足以让 state 恒 0；
//   且 pos_sync_cnt=15 与 sb_pos_sync=0 在 RTL 上互相矛盾（同源同复位）⇒ 疑似综合/读数问题。
//   用同步链各级"上升沿计数"区分：链被删 / sync_r0 抢占 / state 被折叠。
(* preserve, syn_keep = 1 *) reg       sync_r0_q   = 1'b0;   // sync_r0 上一拍（自建沿检测，不依赖可能被优化的 sync_r3）
(* preserve, syn_keep = 1 *) reg       sync_r2_q   = 1'b0;
(* preserve, syn_keep = 1 *) reg [3:0] sync_r0_cnt = 4'd0;   // sync_r0 上升沿计数（饱和 15）
(* preserve, syn_keep = 1 *) reg [3:0] sync_r2_cnt = 4'd0;   // sync_r2 上升沿计数（饱和 15）
(* preserve, syn_keep = 1 *) reg       sb_preempt  = 1'b0;   // 粘滞：曾出现 state==0 && sync_r2 && sync_r0（sync_r0 抢占）
always @( posedge axi_clk or negedge rst_n )
begin
    if( !rst_n ) begin
        sync_r0_q   <= 1'b0;
        sync_r2_q   <= 1'b0;
        sync_r0_cnt <= 4'd0;
        sync_r2_cnt <= 4'd0;
        sb_preempt  <= 1'b0;
    end else begin
        sync_r0_q <= sync_r0;
        sync_r2_q <= sync_r2;
        if( sync_r0 && !sync_r0_q && sync_r0_cnt != 4'hF ) sync_r0_cnt <= sync_r0_cnt + 4'd1;
        if( sync_r2 && !sync_r2_q && sync_r2_cnt != 4'hF ) sync_r2_cnt <= sync_r2_cnt + 4'd1;
        if( state == 2'd0 && sync_r2 && sync_r0 )          sb_preempt  <= 1'b1;
    end
end
// 2026-10-15 重排：dbg_sb[18:0] 由 frame_buffer 并入 test_wdata[23:5]（0xE0 可信通道）；
//   dbg_sb[31:19] 原为 0，frame_buffer 经 test_rdata 送 0xE4（通道可信度未验证，仅作补充）
//   ── 0xE0 对应 dbg_sb[18:0]（括号内为 0xE0 的 bit 位置）──
//   [18](23)    free_cnt[25]          活值（应翻转，证明读数存活）
//   [17:14](22:19) sync_r2_cnt        sync_r2 上升沿计数（饱和 15）★最关键
//   [13:10](18:15) sync_r0_cnt        sync_r0 上升沿计数（饱和 15）
//   [9:6](14:11)   pos_sync_cnt       pos_sync 计数（饱和 15）
//   [5](10)     wr_fifo_rdusedw[10]   活值（1 ⇒ FIFO 满 1024）
//   [4](9)      wr_req                活值
//   [3:2](8:7)  state[1:0]            活值
//   [1](6)      sb_st1                粘滞（曾到过 state==1）
//   [0](5)      sb_pos_sync           粘滞
//   判读：r2_cnt=0 & r0_cnt>0 ⇒ 同步链 r1/r2 被删；r2_cnt>0 & st1=0 ⇒ sync_r0 抢占(看 E4 preempt)或 state 被折叠；
//         st1=1 而 state 恒 0 ⇒ 被后续 sync_r0 复位拉回。
//   ── 0xE4 对应 dbg_sb[31:19]（E4 的 bit 位置同 dbg_sb 位号）──
//   [31] rst_n  [30:28] free_cnt[25:23]  [27] sb_rden  [26] sb_st3  [25] sb_st2  [24] sb_awready
//   [23] sb_wrreq  [22] sb_rdusedw_nz  [21] awvalid  [20] awready  [19] sb_preempt
assign dbg_sb = { rst_n, free_cnt[25:23], sb_rden, sb_st3, sb_st2, sb_awready,
                  sb_wrreq, sb_rdusedw_nz, awvalid, awready, sb_preempt,
                  free_cnt[25], sync_r2_cnt, sync_r0_cnt, pos_sync_cnt, wr_fifo_rdusedw[10], wr_req, state, sb_st1, sb_pos_sync };
//======================================================================================================

reg [8:0] write_cnt = 'd0;
reg burst_end_r = 'd0;
always @(posedge axi_clk or negedge rst_n) 
begin
	if (!rst_n) 												burst_end_r <= 1'b0;
	else 							 							burst_end_r <= burst_add_en;
end

always @( posedge axi_clk or negedge rst_n ) 
begin
		if( !rst_n ) 											wlast <= 1'b0;
		else if(awlen == 0 )   begin   			
				if( sync_r3)
						wlast <= 1'b1;
				if( burst_end_r )
						wlast <= 1'b1;	
				else if(wready)			
						wlast <= 1'b0;						
		end else if( write_cnt+1 == awlen && wready && wvalid)	wlast <= 1'b1;
		else if( write_cnt == awlen && wready && wvalid) 		wlast <= 1'b0;
end
always @(posedge axi_clk or negedge rst_n) 
begin
	if (!rst_n) 												write_cnt <= 0;
	else if(sync_r3)											write_cnt <= 0;
	else if( wready && wvalid && wlast) 						write_cnt <= 0;
	else if (wready && wvalid )									write_cnt <= write_cnt + 1;
end  


//============================================================================================================

wire burst_end = wlast & wready & awvalid;
wire wr_over = wlast & wready ; 

 
assign burst_add_en = wlast & wvalid & wready;       
assign wr_fifo_rden = (awvalid & awready )||(wready && wvalid && !wlast );//write_cnt != 0);//(start_sync == 2'b01 
assign awaddr			= ddr_wr_addr;
assign awlen			= ddr_awlen;

assign wdata			= wr_fifo_rddata;
assign awlock 		= 2'b00;  
assign awapcmd 		= 1'b0;  
assign awcobuf 		= 1'b0;  
 
assign awallstrb 	= 1'b0;
assign awburst 		= 2'b01;
assign awsize  		= AXSIZE_WTH;
assign awid 		= 6'h0D;  // AXI 写 ID：低 4 位 = 0xD，非 0，与 TinyML(0) 互斥；本模块不使用 bid，ID 为纯 tag
assign wstrb 		= {AXI_STRB_WIDTH{1'b1}};  
assign awqos        = 1'b0;
assign bready       = 1'b1;
assign awprot       = 3'd2;
assign awcache 		= 4'd3; 
/*----------------------------------------------------------------------------------*\
                                 The function code
\*----------------------------------------------------------------------------------*/
function integer clogb2;
input [31:0] value;
begin
value = value - 1;
for (clogb2 = 0; value > 0; clogb2 = clogb2 + 1)
value = value >> 1;
end
endfunction 

endmodule 
