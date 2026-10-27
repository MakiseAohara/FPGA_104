//==========================================================================
//  mlx90640_model.v  —  MLX90640 红外阵列行为级模型（仿真专用，不可综合）
//--------------------------------------------------------------------------
//  为什么不用通用的 i2c_slave_model.v？
//    通用模型只有一个 **8 位** 寄存器指针，而且读事务**永远从 mem[0] 开始**
//    （见 i2c_slave_model.v 的 addr_ph 分支）。SHT30 的控制器恰好是"纯读、
//    不带寄存器地址"，所以那个模型够用；但 MLX90640 的控制器是标准的
//    "写 16 位寄存器地址 → 重复起始 → 顺序读"，
//      · 寄存器地址是 16 位（0x8000 STATUS / 0x800D CTRL / 0x0400 PIX / 0x0700 AUX）
//      · 一次事务要顺序读 64 字节（32 个字）
//      · 读出来的内容必须**跟着上一次写的地址走**
//    通用模型这三条全不满足。硬把它改成通用 16 位模型又会污染已经通过验证的
//    SHT30/hub 两个 tb，所以这里单独做一个**器件级**模型，通用模型保持不动。
//
//  器件行为依据（都来自官方库/数据手册，不是凭印象）：
//    工作区\02_传感器与算法原型\mlx90640-library\...\headers\MLX90640_API.h
//      PIXEL_DATA_START_ADDRESS 0x0400, PIXEL_NUM 768
//      AUX_DATA_START_ADDRESS   0x0700, AUX_NUM 64
//      STATUS_REG 0x8000, INIT_STATUS_VALUE 0x0030, STAT_DATA_READY_MASK 0x0008
//      CTRL_REG 0x800D
//    数据手册 Rev.12 §10.4：0x8000 bit3 是 "New data available in RAM"，
//      需要客户读完数据后自己清除（写 0x0030 是官方库用的值）。
//      §10.5 Table 6：0x800D bit[9:7] 是刷新率字段。
//
//  ── I2C 位序约定（沿用 i2c_slave_model.v 里已经验证过的那套）──────────
//    bitn = 本字节内已出现的 SCL 上升沿数
//      bitn 0..7 : 8 个数据位（上升沿采样）
//      bitn 8    : 第 8 位采完，rx 已是完整字节，此刻决定并驱动 ACK
//      bitn 9    : ACK 位采完，字节结算（写事务存；读事务装载下一字节）
//    开漏：从机只把 SDA 拉低，释放时输出 z，上拉由 testbench 的 pullup 提供。
//==========================================================================
`timescale 1ns / 1ps

module mlx90640_model #(
    parameter [6:0] ADDR = 7'h33
)(
    inout  wire        scl,
    inout  wire        sda,

    // ---- 寄存器/内存预装（testbench 用；不经过 I2C，直接灌）----
    input  wire [15:0] pre_word_addr,   // 字地址
    input  wire [15:0] pre_word_data,
    input  wire        pre_we,

    // ---- 器件状态注入 / 观测 ----
    input  wire        nack_all,        // 1 = 所有地址字节都 NACK（错误注入）
    input  wire        set_data_ready,  // 打一拍：置 STATUS bit3（有新数据）
    output reg  [15:0] ctrl_reg,        // 可直接预装/观测
    output reg  [15:0] status_reg,
    output reg  [15:0] status_clr_cnt,  // 收到几次"清标志位"写（写 0x0030）
    output reg  [15:0] ctrl_wr_cnt,     // 收到几次 CTRL_REG 写
    output reg  [15:0] ctrl_wr_val,     // 最近一次写进 CTRL_REG 的值
    output reg  [15:0] last_wr_addr,    // 最近一次写事务里的寄存器地址
    output reg  [15:0] last_wr_data,    // 最近一次写事务里的数据字
    output reg         got_start,
    output reg         got_stop,
    output reg  [15:0] rd_word_cnt      // 读事务里一共发出去多少个字
);

    // RAM：0x0400..0x073F 共 832 个字，索引 = 字地址 - 0x0400
    localparam integer RAM_N = 832;
    reg [15:0] ram [0:RAM_N-1];

    localparam [15:0] REG_STATUS = 16'h8000;
    localparam [15:0] REG_CTRL   = 16'h800D;
    localparam [15:0] RAM_BASE   = 16'h0400;
    localparam [15:0] RAM_LAST   = 16'h073F;

    integer i;

    // ---------------------------------------------------------------- 字读取
    function [15:0] word_at;
        input [15:0] a;
        begin
            if      (a == REG_STATUS)                    word_at = status_reg;
            else if (a == REG_CTRL)                      word_at = ctrl_reg;
            else if (a >= RAM_BASE && a <= RAM_LAST)     word_at = ram[a - RAM_BASE];
            else                                         word_at = 16'h0000;
        end
    endfunction

    // 数据手册 §10.5 Table 6 的 RAM 布局：0x0400 起 768 像素字，0x0700 起 64 辅助字。
    // 这里不解释内容，只当存储用 —— 逐点温度换算由 RISC-V 侧的 Melexis 库做。

    // ---------------------------------------------------------------- 开漏
    reg  sda_low;
    assign sda = sda_low ? 1'b0 : 1'bz;

    // ---------------------------------------------------------------- 状态
    reg [3:0]  bitn;
    reg        active, is_rd, addr_ph;
    reg [7:0]  rx, tx;
    reg        ack_seen;

    reg [15:0] wp;        // 当前字地址（读事务用）
    reg        bhi;       // 1 = 下一个字节是该字的 MSB
    reg [15:0] wa_tmp;    // 写事务：正在装配的寄存器地址
    reg [15:0] wd_hi;     // 写事务：数据字的高字节
    reg [7:0]  wcnt;      // 写事务：数据字节计数（0,1=地址；2,3=第一个数据字；…）

    wire        addr_ok = (rx[7:1] == ADDR) && !nack_all;

    // 当前要发出的字节 / 下一个字节
    wire [15:0] cur_word  = word_at(wp);
    wire [7:0]  rd_cur    = bhi ? cur_word[15:8] : cur_word[7:0];
    wire [15:0] next_wp   = bhi ? wp : (wp + 16'd1);
    wire        next_bhi  = ~bhi;
    wire [15:0] next_word = word_at(next_wp);
    wire [7:0]  rd_next   = next_bhi ? next_word[15:8] : next_word[7:0];

    // 数据就绪标志：bit3（0x0008）。器件侧由 set_data_ready 注入，
    // 控制器读完数据后写 0x0030 把它清掉 —— 这两件事都要能被 tb 观测到。
    wire data_ready = status_reg[3];

    initial begin
        sda_low = 1'b0; bitn = 4'd0; active = 1'b0; is_rd = 1'b0; addr_ph = 1'b1;
        rx = 8'd0; tx = 8'd0; ack_seen = 1'b1;
        wp = 16'h0000; bhi = 1'b1; wa_tmp = 16'h0000; wd_hi = 16'h0000; wcnt = 8'd0;
        ctrl_reg = 16'h0000; status_reg = 16'h0000; status_clr_cnt = 16'd0;
        ctrl_wr_cnt = 16'd0; ctrl_wr_val = 16'hFFFF;
        last_wr_addr = 16'h0000; last_wr_data = 16'h0000;
        got_start = 1'b0; got_stop = 1'b0; rd_word_cnt = 16'd0;
        for (i = 0; i < RAM_N; i = i + 1) ram[i] = 16'h0000;
    end

    // ---------------------------------------------------------------- 预装
    // ★ 必须把 posedge pre_we 放进敏感列表：总线空闲时 SCL 一直被上拉、不跳变，
    //   若只写 `posedge scl or negedge scl`，仿真刚开始的预装会全部丢掉
    //   （这个坑在 i2c_slave_model.v 里已经踩过一次）。
    always @(posedge pre_we) begin
        if (pre_word_addr == REG_CTRL)        ctrl_reg   = pre_word_data;
        else if (pre_word_addr == REG_STATUS) status_reg = pre_word_data;
        else if (pre_word_addr >= RAM_BASE && pre_word_addr <= RAM_LAST)
            ram[pre_word_addr - RAM_BASE] = pre_word_data;
    end

    // 数据就绪注入
    always @(posedge set_data_ready) status_reg[3] = 1'b1;

    // ---------------------------------------------------------------- START / STOP
    always @(negedge sda) if (scl === 1'b1) begin
        active    <= 1'b1;
        bitn      <= 4'd0;
        addr_ph   <= 1'b1;
        sda_low   <= 1'b0;
        got_start <= 1'b1;
        rd_word_cnt <= 16'd0;
    end

    always @(posedge sda) if (scl === 1'b1 && active) begin
        active   <= 1'b0;
        sda_low  <= 1'b0;
        got_stop <= 1'b1;
    end

    // ---------------------------------------------------------------- 采样
    always @(posedge scl) if (active) begin
        if (bitn < 4'd8) rx <= {rx[6:0], sda};
        if (bitn == 4'd8) ack_seen <= sda;   // 读事务：主机发的 ACK/NACK
        bitn <= bitn + 4'd1;
    end

    // ---------------------------------------------------------------- 驱动 / 结算
    always @(negedge scl) if (active) begin
        if (bitn == 4'd8) begin
            // ---- 8 位收齐，此刻决定并驱动 ACK ----
            if (addr_ph) begin
                sda_low <= addr_ok ? 1'b1 : 1'b0;   // 地址字节：匹配则 ACK
            end else if (is_rd) begin
                sda_low <= 1'b0;                    // 读数据字节：ACK 由主机发
            end else begin
                sda_low <= 1'b1;                    // 写数据字节：ACK
            end
        end else if (bitn == 4'd9) begin
            // ---- 字节结算 ----
            bitn <= 4'd0;
            if (addr_ph) begin
                addr_ph <= 1'b0;
                is_rd   <= rx[0];
                if (addr_ok && rx[0]) begin
                    // 读事务：从"上一次写事务定下的寄存器地址"开始顺序读。
                    // ★ 这里是通用模型做不到的关键点：地址跟着上一次写走，
                    //   而不是永远从 0 开始。
                    wp          <= wp;
                    bhi         <= 1'b1;
                    tx          <= cur_word[15:8];
                    sda_low     <= ~cur_word[15];
                    rd_word_cnt <= 16'd0;
                end else begin
                    wcnt    <= 8'd0;
                    sda_low <= 1'b0;
                end
            end else if (is_rd) begin
                if (ack_seen) begin
                    // 主机回 NACK：事务结束，释放 SDA 让 STOP 能成立
                    is_rd   <= 1'b0;
                    sda_low <= 1'b0;
                end else begin
                    if (!bhi) rd_word_cnt <= rd_word_cnt + 16'd1;
                    wp      <= next_wp;
                    bhi     <= next_bhi;
                    tx      <= rd_next;
                    sda_low <= ~rd_next[7];
                end
            end else begin
                // ---- 写事务 ----
                sda_low <= 1'b0;
                case (wcnt)
                    8'd0: wa_tmp[15:8] <= rx;
                    8'd1: begin
                        wa_tmp      <= {wa_tmp[15:8], rx};
                        wp          <= {wa_tmp[15:8], rx};   // 读事务要用它
                        last_wr_addr <= {wa_tmp[15:8], rx};
                    end
                    default: begin
                        if (wcnt[0] == 1'b0) begin
                            wd_hi <= rx;                     // 数据字高字节
                        end else begin
                            // 数据字完整：写进器件
                            last_wr_data <= {wd_hi, rx};
                            if (wp == REG_STATUS) begin
                                status_reg     <= {wd_hi, rx};
                                status_clr_cnt <= status_clr_cnt + 16'd1;
                            end else if (wp == REG_CTRL) begin
                                ctrl_reg     <= {wd_hi, rx};
                                ctrl_wr_cnt  <= ctrl_wr_cnt + 16'd1;
                                ctrl_wr_val  <= {wd_hi, rx};
                            end else if (wp >= RAM_BASE && wp <= RAM_LAST) begin
                                ram[wp - RAM_BASE] <= {wd_hi, rx};
                            end
                            wp <= wp + 16'd1;
                        end
                    end
                endcase
                wcnt <= wcnt + 8'd1;
            end
        end else if (is_rd && !addr_ph && bitn >= 4'd1 && bitn <= 4'd7) begin
            // ---- 读事务：移出下一个数据位 ----
            tx      <= {tx[6:0], 1'b0};
            sda_low <= ~tx[6];
        end
    end

    // data_ready 是纯观测点（tb 想看 status_reg[3] 时会用到它的语义说明）
    wire _unused_ok = data_ready;

endmodule
