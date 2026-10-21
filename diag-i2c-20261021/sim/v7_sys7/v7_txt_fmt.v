`timescale 1ns / 1ps
// 自动生成：把传感器/决策数值格式化为 3 行 × 48 列 ASCII，写入 OSD 文字 RAM
module v7_txt_fmt (
    input  wire        clk, rst_n,
    input  wire        refresh,                 // 每帧一个脉冲
    input  wire [15:0] temp_x100, rh_x100, ir_x10, area, conf_x100,
    input  wire        motion, alarm_on, night, sns_ok, low_pwr,
    input  wire        dg_scl, dg_sda, dg_slv, dg_stuck, dg_sht_err, dg_ir_err, dg_sht_seen, dg_irseen, dg_crc,
    input  wire [15:0] dg_oe_cnt, dg_slv_cnt,
    output reg         txt_we,
    output reg  [7:0]  txt_wa,
    output reg  [7:0]  txt_wd
);
    localparam S_IDLE=0, S_START=1, S_WAIT=2, S_WR=3;
    reg [7:0] ch;
    reg [1:0] st; reg [2:0] fld; reg [7:0] idx; reg go;
    reg [19:0] bA,bB,bC,bD,bE;
    reg [15:0] bin; reg b_start; wire b_done; wire [19:0] b_bcd;
    v7_bin2bcd u_b2b(.clk(clk),.rst_n(rst_n),.start(b_start),.bin(bin),.done(b_done),.bcd(b_bcd));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st<=S_IDLE; fld<=0; idx<=0; b_start<=0; bin<=0; txt_we<=0; txt_wa<=0; go<=0;
            bA<=0;bB<=0;bC<=0;bD<=0;bE<=0; end
        else begin
            b_start<=0; txt_we<=0;
            case (st)
              S_IDLE: begin if (refresh) begin fld<=0; st<=S_START; end end
              S_START: begin
                  case (fld) 0: bin<=temp_x100; 1: bin<=rh_x100; 2: bin<=ir_x10; 3: bin<=area; default: bin<=conf_x100; endcase
                  b_start<=1; st<=S_WAIT; end
              S_WAIT: if (b_done) begin
                  case (fld) 0: bA<=b_bcd; 1: bB<=b_bcd; 2: bC<=b_bcd; 3: bD<=b_bcd; default: bE<=b_bcd; endcase
                  if (fld==3'd4) begin idx<=0; st<=S_WR; end else begin fld<=fld+3'd1; st<=S_START; end
                  end
              S_WR: begin
                  txt_we<=1; txt_wa<=idx; txt_wd<=ch;
                  if (idx==8'd191) st<=S_IDLE; else idx<=idx+8'd1;
                  end
            endcase
        end
    end
    wire [7:0] hr1 = night ? 8'd50 : 8'd49;   // 23 / 12
    wire [7:0] hr0 = night ? 8'd51 : 8'd50;
    wire [7:0] mot = motion ? 8'd49 : 8'd48;
    wire [7:0] sns0 = sns_ok ? 8'd79 : 8'd69;  // O / E
    wire [7:0] sns1 = sns_ok ? 8'd75 : 8'd82;  // K / R
    // EVT 词：报警 INTRUDE / 低功耗 SLEEP / 正常 NORMAL
    wire [7:0] ev0 = alarm_on ? 8'd73 : (low_pwr ? 8'd83 : 8'd78); // I / S / N
    wire [7:0] ev1 = alarm_on ? 8'd78 : (low_pwr ? 8'd76 : 8'd79); // N / L / O
    wire [7:0] ev2 = alarm_on ? 8'd84 : (low_pwr ? 8'd69 : 8'd82); // T / E / R
    wire [7:0] ev3 = alarm_on ? 8'd82 : (low_pwr ? 8'd69 : 8'd77); // R / E / M
    wire [7:0] ev4 = alarm_on ? 8'd85 : (low_pwr ? 8'd80 : 8'd65); // U / P / A
    wire [7:0] ev5 = alarm_on ? 8'd68 : (low_pwr ? 8'd32 : 8'd76); // D / ' ' / L
    wire [7:0] ev6 = alarm_on ? 8'd69 : 8'd32;                     // E / ' '
    wire [7:0] nd0 = night ? 8'd78 : 8'd68;    // N / D
    wire [7:0] nd1 = night ? 8'd73 : 8'd65;    // I / A
    wire [7:0] nd2 = night ? 8'd71 : 8'd89;    // G / Y
    wire [7:0] nd3 = night ? 8'd72 : 8'd32;    // H / ' '
    wire [7:0] nd4 = night ? 8'd84 : 8'd32;    // T / ' '
    function [7:0] hx(input [3:0] n); hx = (n < 4'd10) ? {4'h3,n} : (8'd55 + {4'h0,n}); endfunction
    function [7:0] bt(input b); bt = b ? 8'd49 : 8'd48; endfunction
    always @* begin
        case (idx)
            8'd0: ch = 8'd84;
            8'd1: ch = 8'd61;
            8'd2: ch = {4'h3,bA[15:12]};
            8'd3: ch = {4'h3,bA[11:8]};
            8'd4: ch = 8'd46;
            8'd5: ch = {4'h3,bA[7:4]};
            8'd6: ch = 8'd67;
            8'd7: ch = 8'd32;
            8'd8: ch = 8'd82;
            8'd9: ch = 8'd72;
            8'd10: ch = 8'd61;
            8'd11: ch = {4'h3,bB[15:12]};
            8'd12: ch = {4'h3,bB[11:8]};
            8'd13: ch = 8'd46;
            8'd14: ch = {4'h3,bB[7:4]};
            8'd15: ch = 8'd37;
            8'd16: ch = 8'd32;
            8'd17: ch = 8'd72;
            8'd18: ch = 8'd82;
            8'd19: ch = 8'd61;
            8'd20: ch = hr1;
            8'd21: ch = hr0;
            8'd22: ch = 8'd32;
            8'd23: ch = nd0;
            8'd24: ch = nd1;
            8'd25: ch = nd2;
            8'd26: ch = nd3;
            8'd27: ch = nd4;
            8'd64: ch = 8'd73;
            8'd65: ch = 8'd82;
            8'd66: ch = 8'd61;
            8'd67: ch = {4'h3,bC[11:8]};
            8'd68: ch = {4'h3,bC[7:4]};
            8'd69: ch = 8'd46;
            8'd70: ch = {4'h3,bC[3:0]};
            8'd71: ch = 8'd67;
            8'd72: ch = 8'd32;
            8'd73: ch = 8'd77;
            8'd74: ch = 8'd79;
            8'd75: ch = 8'd84;
            8'd76: ch = 8'd73;
            8'd77: ch = 8'd79;
            8'd78: ch = 8'd78;
            8'd79: ch = 8'd61;
            8'd80: ch = mot;
            8'd81: ch = 8'd32;
            8'd82: ch = 8'd65;
            8'd83: ch = 8'd82;
            8'd84: ch = 8'd69;
            8'd85: ch = 8'd65;
            8'd86: ch = 8'd61;
            8'd87: ch = {4'h3,bD[15:12]};
            8'd88: ch = {4'h3,bD[11:8]};
            8'd89: ch = {4'h3,bD[7:4]};
            8'd90: ch = {4'h3,bD[3:0]};
            8'd128: ch = 8'd69;
            8'd129: ch = 8'd86;
            8'd130: ch = 8'd84;
            8'd131: ch = 8'd61;
            8'd132: ch = ev0;
            8'd133: ch = ev1;
            8'd134: ch = ev2;
            8'd135: ch = ev3;
            8'd136: ch = ev4;
            8'd137: ch = ev5;
            8'd138: ch = ev6;
            8'd139: ch = 8'd32;
            8'd140: ch = 8'd67;
            8'd141: ch = 8'd79;
            8'd142: ch = 8'd78;
            8'd143: ch = 8'd70;
            8'd144: ch = 8'd61;
            8'd145: ch = {4'h3,bE[11:8]};
            8'd146: ch = 8'd46;
            8'd147: ch = {4'h3,bE[7:4]};
            8'd148: ch = {4'h3,bE[3:0]};
            8'd149: ch = 8'd32;
            8'd150: ch = 8'd83;
            8'd151: ch = 8'd78;
            8'd152: ch = 8'd83;
            8'd153: ch = 8'd61;
            8'd154: ch = sns0;
            8'd155: ch = sns1;
            8'd28: ch = 8'd32;
            8'd29: ch = 8'd83;
            8'd30: ch = 8'd67;
            8'd31: ch = 8'd76;
            8'd32: ch = 8'd61;
            8'd33: ch = bt(dg_scl);
            8'd34: ch = 8'd32;
            8'd35: ch = 8'd83;
            8'd36: ch = 8'd68;
            8'd37: ch = 8'd65;
            8'd38: ch = 8'd61;
            8'd39: ch = bt(dg_sda);
            8'd40: ch = 8'd32;
            8'd41: ch = 8'd65;
            8'd42: ch = 8'd61;
            8'd43: ch = bt(dg_slv);
            8'd44: ch = 8'd32;
            8'd45: ch = 8'd69;
            8'd46: ch = 8'd61;
            8'd47: ch = bt(dg_sht_err);
            8'd91: ch = 8'd32;
            8'd92: ch = 8'd73;
            8'd93: ch = 8'd69;
            8'd94: ch = 8'd61;
            8'd95: ch = bt(dg_ir_err);
            8'd96: ch = 8'd32;
            8'd97: ch = 8'd83;
            8'd98: ch = 8'd86;
            8'd99: ch = 8'd61;
            8'd100: ch = bt(dg_sht_seen);
            8'd101: ch = 8'd32;
            8'd102: ch = 8'd73;
            8'd103: ch = 8'd86;
            8'd104: ch = 8'd61;
            8'd105: ch = bt(dg_irseen);
            8'd106: ch = 8'd32;
            8'd107: ch = 8'd67;
            8'd108: ch = 8'd61;
            8'd109: ch = bt(dg_crc);
            8'd110: ch = 8'd75;
            8'd111: ch = bt(dg_stuck);
            8'd156: ch = 8'd32;
            8'd157: ch = 8'd79;
            8'd158: ch = 8'd61;
            8'd159: ch = hx(dg_oe_cnt[15:12]);
            8'd160: ch = hx(dg_oe_cnt[11:8]);
            8'd161: ch = hx(dg_oe_cnt[7:4]);
            8'd162: ch = hx(dg_oe_cnt[3:0]);
            8'd163: ch = 8'd32;
            8'd164: ch = 8'd78;
            8'd165: ch = 8'd61;
            8'd166: ch = hx(dg_slv_cnt[15:12]);
            8'd167: ch = hx(dg_slv_cnt[11:8]);
            8'd168: ch = hx(dg_slv_cnt[7:4]);
            8'd169: ch = hx(dg_slv_cnt[3:0]);
            default: ch = 8'd32;
        endcase
    end
endmodule
