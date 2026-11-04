// v7_audio_tone.v — HDMI 音频提示音（接到 dvi_encoder 的 audio_L/R/valid）
//
// 48 kHz / 24-bit L-PCM；三音上行提示（880/1175/1319 Hz），enable=1 时循环，否则输出静音采样。
// 采样节拍用整数累加，无小数误差累积；正弦表 64 点。
`timescale 1ns / 1ps

module v7_audio_tone #(
    parameter CLK_HZ    = 148500000,
    parameter SAMPLE_HZ = 48000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    output reg  [23:0] audio_l,
    output reg  [23:0] audio_r,
    output reg         audio_valid
);

    localparam integer NOTE_LEN = 12000;
    localparam integer GAP      = 2400;
    localparam integer PERIOD   = 38400;

    /* 48 kHz 采样节拍 */
    reg  [31:0] tick_acc;
    reg         tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tick_acc <= 32'd0; tick <= 1'b0; end
        else if (tick_acc + SAMPLE_HZ >= CLK_HZ) begin
            tick_acc <= tick_acc + SAMPLE_HZ - CLK_HZ;
            tick     <= 1'b1;
        end else begin
            tick_acc <= tick_acc + SAMPLE_HZ;
            tick     <= 1'b0;
        end
    end

    /* 音符序列 */
    reg  [31:0] npos;
    reg  [31:0] phase;
    reg  [31:0] inc;
    reg  [9:0]  env;

    wire [31:0] npos_nxt = (npos + 32'd1 >= PERIOD) ? 32'd0 : npos + 32'd1;
    wire [1:0]  nidx     = (npos_nxt < NOTE_LEN)   ? 2'd0 :
                           (npos_nxt < 2*NOTE_LEN) ? 2'd1 :
                           (npos_nxt < 3*NOTE_LEN) ? 2'd2 : 2'd3;
    wire [31:0] intra    = (npos_nxt < NOTE_LEN)   ? npos_nxt :
                           (npos_nxt < 2*NOTE_LEN) ? npos_nxt - NOTE_LEN :
                           (npos_nxt < 3*NOTE_LEN) ? npos_nxt - 2*NOTE_LEN : 32'd4000;
    /* 包络：0..1023 线性起步，再 >>3 得到 0..127 的幅度（约 1/8 满量程） */
    wire [9:0]  env_raw  = (intra > 32'd1023) ? 10'd1023 : intra[9:0];
    wire [9:0]  env_nxt  = env_raw >> 3;

    always @(*) begin
        case (nidx)
            2'd0:    inc = 32'd78741067;
            2'd1:    inc = 32'd105106798;
            default: inc = 32'd117978278;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npos <= 32'd0; phase <= 32'd0; env <= 10'd0;
        end else if (tick) begin
            npos  <= npos_nxt;
            phase <= phase + inc;
            env   <= env_nxt;
        end
    end

    /* 正弦表（64 点） */
    reg signed [15:0] wave;
    always @(*) begin
        case (phase[31:26])
            6'd0: wave = 16'sd0;
            6'd1: wave = 16'sd3212;
            6'd2: wave = 16'sd6393;
            6'd3: wave = 16'sd9512;
            6'd4: wave = 16'sd12539;
            6'd5: wave = 16'sd15446;
            6'd6: wave = 16'sd18204;
            6'd7: wave = 16'sd20787;
            6'd8: wave = 16'sd23170;
            6'd9: wave = 16'sd25329;
            6'd10: wave = 16'sd27245;
            6'd11: wave = 16'sd28898;
            6'd12: wave = 16'sd30273;
            6'd13: wave = 16'sd31356;
            6'd14: wave = 16'sd32137;
            6'd15: wave = 16'sd32609;
            6'd16: wave = 16'sd32767;
            6'd17: wave = 16'sd32609;
            6'd18: wave = 16'sd32137;
            6'd19: wave = 16'sd31356;
            6'd20: wave = 16'sd30273;
            6'd21: wave = 16'sd28898;
            6'd22: wave = 16'sd27245;
            6'd23: wave = 16'sd25329;
            6'd24: wave = 16'sd23170;
            6'd25: wave = 16'sd20787;
            6'd26: wave = 16'sd18204;
            6'd27: wave = 16'sd15446;
            6'd28: wave = 16'sd12539;
            6'd29: wave = 16'sd9512;
            6'd30: wave = 16'sd6393;
            6'd31: wave = 16'sd3212;
            6'd32: wave = 16'sd0;
            6'd33: wave = -16'sd3212;
            6'd34: wave = -16'sd6393;
            6'd35: wave = -16'sd9512;
            6'd36: wave = -16'sd12539;
            6'd37: wave = -16'sd15446;
            6'd38: wave = -16'sd18204;
            6'd39: wave = -16'sd20787;
            6'd40: wave = -16'sd23170;
            6'd41: wave = -16'sd25329;
            6'd42: wave = -16'sd27245;
            6'd43: wave = -16'sd28898;
            6'd44: wave = -16'sd30273;
            6'd45: wave = -16'sd31356;
            6'd46: wave = -16'sd32137;
            6'd47: wave = -16'sd32609;
            6'd48: wave = -16'sd32767;
            6'd49: wave = -16'sd32609;
            6'd50: wave = -16'sd32137;
            6'd51: wave = -16'sd31356;
            6'd52: wave = -16'sd30273;
            6'd53: wave = -16'sd28898;
            6'd54: wave = -16'sd27245;
            6'd55: wave = -16'sd25329;
            6'd56: wave = -16'sd23170;
            6'd57: wave = -16'sd20787;
            6'd58: wave = -16'sd18204;
            6'd59: wave = -16'sd15446;
            6'd60: wave = -16'sd12539;
            6'd61: wave = -16'sd9512;
            6'd62: wave = -16'sd6393;
            6'd63: wave = -16'sd3212;
            default: wave = 16'sd0;
        endcase
    end

    /* 24-bit 有符号：prod = wave(±32767)*env(0..127)；prod[25:2] 约为 1/8 满量程 */
    wire signed [25:0] prod = $signed(wave) * $signed({2'b00, env});
    wire        [23:0] pcm  = prod[25:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_l <= 24'd0; audio_r <= 24'd0; audio_valid <= 1'b0;
        end else begin
            audio_valid <= tick;
            if (tick) begin
                audio_l <= enable ? pcm : 24'd0;
                audio_r <= enable ? pcm : 24'd0;
            end
        end
    end

endmodule
