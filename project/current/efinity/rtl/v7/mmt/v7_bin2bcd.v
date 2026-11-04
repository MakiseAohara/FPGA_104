`timescale 1ns / 1ps
// 16位二进制 -> 5位BCD，双倍-加3移位，顺序实现（16拍）
module v7_bin2bcd (
    input  wire        clk, rst_n,
    input  wire        start,
    input  wire [15:0] bin,
    output reg         done,
    output reg  [19:0] bcd
);
    reg [15:0] sh; reg [19:0] acc; reg [4:0] cnt; reg busy;
    wire [19:0] adj = {
        (acc[19:16] >= 5) ? acc[19:16] + 4'd3 : acc[19:16],
        (acc[15:12] >= 5) ? acc[15:12] + 4'd3 : acc[15:12],
        (acc[11:8]  >= 5) ? acc[11:8]  + 4'd3 : acc[11:8],
        (acc[7:4]   >= 5) ? acc[7:4]   + 4'd3 : acc[7:4],
        (acc[3:0]   >= 5) ? acc[3:0]   + 4'd3 : acc[3:0] };
    wire [19:0] nxt = {adj[18:0], sh[15]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy<=0; done<=0; bcd<=0; sh<=0; acc<=0; cnt<=0; end
        else begin
            done <= 1'b0;
            if (start && !busy) begin busy<=1; sh<=bin; acc<=0; cnt<=0; end
            else if (busy) begin
                acc <= nxt; sh <= {sh[14:0],1'b0}; cnt <= cnt + 5'd1;
                if (cnt == 5'd15) begin busy<=0; done<=1; bcd<=nxt; end
            end
        end
    end
endmodule
