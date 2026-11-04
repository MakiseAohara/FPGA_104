//==========================================================================
//  mmt_mlx90640_ctrl.v  —  MLX90640 红外阵列周期性 RAM 搬运控制器
//--------------------------------------------------------------------------
//  寄存器地址依据（已从官方库核实，非凭印象）：
//    工作区\02_传感器与算法原型\mlx90640-library\mlx90640-library-master\
//      headers\MLX90640_API.h
//        行36: PIXEL_DATA_START_ADDRESS 0x0400   行37: PIXEL_NUM 768
//        行42: AUX_DATA_START_ADDRESS  0x0700   行43: AUX_NUM 64
//        行44: STATUS_REG 0x8000   行45: INIT_STATUS_VALUE 0x0030（清标志位写值）
//        行48: STAT_DATA_READY_MASK BIT_MASK(3)  (=0x0008)
//        行51: CTRL_REG 0x800D
//        行53-54: CTRL_REFRESH_SHIFT=7, CTRL_REFRESH_MASK=REG_MASK(7,3)
//                 （REG_MASK 定义见该文件行32：结果是"目标字段=0，其余全1"的
//                  清除掩码，不是选择掩码——已实际展开验证过，不是凭注释名字猜的）
//      functions\MLX90640_API.c
//        行298-316: MLX90640_SetRefreshRate() —— 读CTRL_REG→只替换刷新率字段
//                    (bit9:7)→写回，其余字段（分辨率/subpage模式等）不动。
//                    本模块的初始化严格照抄这个"只改一个字段"的读-改-写模式。
//    工作区\02_传感器与算法原型\MLX90640_datasheet.txt（Revision 12, 2019-12-03）
//        行419-432（10.4节，第12-13页）：刷新率由0x800D配置；bit3 "New data
//        available in RAM" 需要客户自己清除（"It is up to the customer to
//        reset the bit once the data has been read"）。
//        行607-655（Figure12/Table6，第17-18页）：0x800D 位定义——
//          bit[9:7]  Refresh rate control：000=0.5Hz 001=1Hz 010=2Hz(默认)
//                    011=4Hz 100=8Hz 101=16Hz 110=32Hz 111=64Hz
//          bit[11:10] Resolution（默认18bit）、bit12 Reading pattern（默认chess）
//          等其余字段：本模块一律不碰，维持上电默认值，只改刷新率字段。
//    frame_addr 映射（与契约"0..767=像素,768..831=辅助区"一致，未变）
//
//  ⚠️ 三处已知限制/设计取舍：
//
//  1) STATUS_REG 清标志位、CTRL_REG 初始化：v1 因 master 的 tx_len≤2 做不到，
//     v2 master 支持 tx_len≤4（2字节地址+2字节数据）后，本版已经实现，见下方
//     ST_INIT_* 与 ST_CLR_STATUS_* 状态。
//
//  2) ta_raw 只搬了 frameData[800]（Ptat）一个字，算完整 Ta 还需要 [768]（Vbe）
//     +EEPROM系数，RISC-V 该直接从 BRAM 读 768/800 两个地址自己拼——这条
//     v1就写清楚了，v2未变。
//
//  3) EEPROM（0x2400起832字）本模块不读，frame_addr只有10位装不下，语义上也
//     该是RISC-V开机读一次——这条v1判断，DeepSeek round2已确认同意，不变。
//==========================================================================
`timescale 1ns / 1ps

module mmt_mlx90640_ctrl #(
    parameter CLK_HZ          = 100_000_000,
    parameter I2C_ADDR        = 7'h33,        // MLX90640 默认 7 位地址
    parameter FRAME_PERIOD_MS = 500,          // 2Hz 取一帧
    // 必须与 FRAME_PERIOD_MS 对应的刷新率手动同步（见文件头刷新率表）：
    // 默认 500ms=2Hz -> 3'b010。改 FRAME_PERIOD_MS 时请同步改这个。
    parameter [2:0] REFRESH_CODE = 3'b010
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 帧数据写入端口（双口 BRAM 的写侧）----
    output reg         frame_wr,
    output reg  [9:0]  frame_addr,        // 0..767=像素, 768..831=辅助区
    output reg  [15:0] frame_data,
    output reg  [15:0] frame_cnt,         // 完成的帧计数
    output reg         frame_valid,       // 一帧写入完成脉冲
    output reg  [15:0] ta_raw,            // frameData[800]（Ptat，见文件头②）
    output reg         bus_err,
    output reg         init_done,         // CTRL_REG 初始化已完成（新增）

    // ---- 挂到 mmt_i2c_hub 的从端口（v2：tx_data/tx_len 已加宽）----
    output reg         req,
    output reg  [6:0]  dev_addr,
    output reg  [31:0] tx_data,
    output reg  [2:0]  tx_len,
    output reg  [7:0]  rd_len,
    input  wire        busy,
    input  wire        done,
    input  wire        err,
    input  wire [7:0]  rd_data,
    input  wire        rd_valid,
    input  wire        hub_grant
);

    localparam [15:0] STATUS_REG      = 16'h8000;
    localparam [15:0] CTRL_REG        = 16'h800D;
    localparam [15:0] INIT_STATUS_VAL = 16'h0030;  // 官方库同值，API.h行45
    localparam [15:0] CTRL_REFRESH_CLEAR_MASK = 16'hFC7F; // 清 bit9:7，其余保留
    localparam [15:0] PIX_START_ADDR  = 16'h0400;
    localparam [15:0] AUX_START_ADDR  = 16'h0700;
    localparam        DATA_READY_BIT  = 3;        // 0x0008

    localparam [15:0] CHUNK_WORDS  = 16'd32;       // 每次事务读 32 字=64 字节
    localparam [4:0]  PIX_CHUNKS   = 5'd24;        // 768/32
    localparam [4:0]  AUX_CHUNKS   = 5'd2;         //  64/32
    localparam [4:0]  TOTAL_CHUNKS = PIX_CHUNKS + AUX_CHUNKS; // 26

    localparam [31:0] PERIOD_TICKS = (CLK_HZ / 1000) * FRAME_PERIOD_MS;
    // 轮询超时：给到 1 个完整周期的余量。正常情况下回到 ST_POLL_SEND 时
    // data-ready 应该已经置位（因为 ST_PERIOD_WAIT 已经等了一个 FRAME_PERIOD_MS），
    // 超时说明刷新率配置和 FRAME_PERIOD_MS 没对上，或者器件没响应。
    localparam [31:0] POLL_TIMEOUT_TICKS = PERIOD_TICKS;
    // CTRL_REG 初始化重试上限（上电时器件可能还没就绪，给几次机会，
    // 超过就放弃并置位 bus_err、按未配置状态继续跑——好过硬卡死）
    localparam [3:0]  INIT_RETRY_MAX = 4'd8;

    localparam [4:0]
        ST_INIT_RD_SEND  = 5'd0,   // 读 CTRL_REG 当前值
        ST_INIT_RD_WAIT  = 5'd1,
        ST_INIT_WR_SEND  = 5'd2,   // 只替换刷新率字段，写回
        ST_INIT_WR_WAIT  = 5'd3,
        ST_POLL_SEND     = 5'd4,   // 发起读 STATUS_REG（2字节地址+2字节读）
        ST_POLL_WAIT     = 5'd5,   // 收 2 字节，判断 data-ready 位
        ST_CLR_STATUS_SEND = 5'd6, // 就绪后：写 STATUS_REG=0x0030 清标志位
        ST_CLR_STATUS_WAIT = 5'd7,
        ST_CHUNK_SEND    = 5'd8,   // 发起本 chunk 的"写地址+重复起始读"事务
        ST_CHUNK_WAIT    = 5'd9,   // 收 chunk 数据，拼字写 BRAM
        ST_FRAME_DONE    = 5'd10,  // 打 frame_valid 一拍
        ST_PERIOD_WAIT   = 5'd11;  // 等到下一帧周期

    reg [4:0]  state;
    reg [31:0] tick_cnt;
    reg [31:0] poll_cnt;         // 轮询超时计数（在 ST_POLL_* 期间累计）
    reg [3:0]  init_retry;
    reg [4:0]  chunk_num;      // 0..25
    reg [9:0]  word_cnt;       // 0..831，跨整帧单调递增，帧首清零
    reg        byte_hi_pending;
    reg [7:0]  hi_byte;
    reg [15:0] status_val;
    reg [15:0] ctrl_val_old;

    // 当前 chunk 对应的寄存器起始地址
    wire [15:0] chunk_reg_addr =
        (chunk_num < PIX_CHUNKS) ?
            (PIX_START_ADDR + (chunk_num * CHUNK_WORDS)) :
            (AUX_START_ADDR + ((chunk_num - PIX_CHUNKS) * CHUNK_WORDS));

    // 新 CTRL_REG 值：只替换 bit9:7（刷新率），其余保留读回来的原值
    // 注：{13'd0,REFRESH_CODE} 是 Verilog-2001 写法的零扩展（3bit->16bit），
    // 不能用 16'(REFRESH_CODE) 这种 SystemVerilog 类型转换语法（.v 按 sv_09
    // 之外的 Verilog 解析，那样写会报语法错误）。
    wire [15:0] ctrl_val_new =
        (ctrl_val_old & CTRL_REFRESH_CLEAR_MASK) | ({13'd0, REFRESH_CODE} << 7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_INIT_RD_SEND;
            tick_cnt        <= 32'd0;
            poll_cnt        <= 32'd0;
            init_retry      <= 4'd0;
            chunk_num       <= 5'd0;
            word_cnt        <= 10'd0;
            byte_hi_pending <= 1'b0;
            hi_byte         <= 8'd0;
            status_val      <= 16'd0;
            ctrl_val_old    <= 16'd0;
            frame_wr        <= 1'b0;
            frame_addr      <= 10'd0;
            frame_data      <= 16'd0;
            frame_cnt       <= 16'd0;
            frame_valid     <= 1'b0;
            ta_raw          <= 16'd0;
            bus_err         <= 1'b0;
            init_done       <= 1'b0;
            req             <= 1'b0;
            dev_addr        <= I2C_ADDR;
            tx_data         <= 32'd0;
            tx_len          <= 3'd0;
            rd_len          <= 8'd0;
        end else begin
            frame_wr    <= 1'b0;   // 默认拉低，按需在下面打一拍
            frame_valid <= 1'b0;

            case (state)
            //================================================================
            // 开机初始化：读 CTRL_REG -> 只改刷新率字段 -> 写回
            //================================================================
            ST_INIT_RD_SEND: begin
                dev_addr <= I2C_ADDR;
                tx_data  <= {16'd0, CTRL_REG};
                tx_len   <= 3'd2;
                rd_len   <= 8'd2;
                req      <= 1'b1;
                byte_hi_pending <= 1'b0;
                state    <= ST_INIT_RD_WAIT;
            end
            ST_INIT_RD_WAIT: begin
                if (hub_grant && rd_valid) begin
                    if (!byte_hi_pending) begin
                        hi_byte         <= rd_data;
                        byte_hi_pending <= 1'b1;
                    end else begin
                        ctrl_val_old    <= {hi_byte, rd_data};
                        byte_hi_pending <= 1'b0;
                    end
                end
                if (hub_grant && done) begin
                    req <= 1'b0;
                    if (err) begin
                        bus_err <= 1'b1;
                        if (init_retry >= INIT_RETRY_MAX) begin
                            init_done <= 1'b1;   // 放弃初始化，按上电默认值继续跑
                            state     <= ST_POLL_SEND;
                        end else begin
                            init_retry <= init_retry + 4'd1;
                            state      <= ST_INIT_RD_SEND;
                        end
                    end else begin
                        state <= ST_INIT_WR_SEND;
                    end
                end
            end
            ST_INIT_WR_SEND: begin
                dev_addr <= I2C_ADDR;
                tx_data  <= {CTRL_REG, ctrl_val_new};
                tx_len   <= 3'd4;
                rd_len   <= 8'd0;
                req      <= 1'b1;
                state    <= ST_INIT_WR_WAIT;
            end
            ST_INIT_WR_WAIT: begin
                if (hub_grant && done) begin
                    req <= 1'b0;
                    if (err) begin
                        bus_err <= 1'b1;
                        if (init_retry >= INIT_RETRY_MAX) begin
                            init_done <= 1'b1;
                            state     <= ST_POLL_SEND;
                        end else begin
                            init_retry <= init_retry + 4'd1;
                            state      <= ST_INIT_RD_SEND;
                        end
                    end else begin
                        init_done <= 1'b1;
                        state     <= ST_POLL_SEND;
                    end
                end
            end
            //================================================================
            // 主循环：轮询 STATUS_REG -> 清标志位 -> 分块读 RAM -> 下一帧
            //================================================================
            ST_POLL_SEND: begin
                dev_addr        <= I2C_ADDR;
                tx_data         <= {16'd0, STATUS_REG};
                tx_len          <= 3'd2;
                rd_len          <= 8'd2;
                req             <= 1'b1;
                byte_hi_pending <= 1'b0;
                state           <= ST_POLL_WAIT;
            end
            ST_POLL_WAIT: begin
                if (hub_grant && rd_valid) begin
                    if (!byte_hi_pending) begin
                        hi_byte         <= rd_data;
                        byte_hi_pending <= 1'b1;
                    end else begin
                        status_val      <= {hi_byte, rd_data};
                        byte_hi_pending <= 1'b0;
                    end
                end
                if (hub_grant && done) begin
                    req <= 1'b0;
                    if (err) begin
                        bus_err  <= 1'b1;
                        poll_cnt <= 32'd0;
                        tick_cnt <= 32'd0;
                        state    <= ST_PERIOD_WAIT;
                    end else if (status_val[DATA_READY_BIT]) begin
                        poll_cnt  <= 32'd0;
                        state     <= ST_CLR_STATUS_SEND;
                    end else if (poll_cnt >= POLL_TIMEOUT_TICKS - 32'd1) begin
                        // 轮询超时：不死等，报错并放弃这一帧
                        bus_err  <= 1'b1;
                        poll_cnt <= 32'd0;
                        tick_cnt <= 32'd0;
                        state    <= ST_PERIOD_WAIT;
                    end else begin
                        poll_cnt <= poll_cnt + 32'd1;   // 粗略累计（按轮询次数近似）
                        state    <= ST_POLL_SEND;
                    end
                end
            end
            //----------------------------------------------------------------
            ST_CLR_STATUS_SEND: begin
                dev_addr <= I2C_ADDR;
                tx_data  <= {STATUS_REG, INIT_STATUS_VAL};
                tx_len   <= 3'd4;
                rd_len   <= 8'd0;
                req      <= 1'b1;
                state    <= ST_CLR_STATUS_WAIT;
            end
            ST_CLR_STATUS_WAIT: begin
                if (hub_grant && done) begin
                    req <= 1'b0;
                    // 清标志位失败不影响本帧数据本身有效，只记 bus_err，
                    // 仍然继续读 RAM——数据是新的，只是"我已读完"这个握手
                    // 没告诉器件，最坏情况是下一次轮询提前判定 ready。
                    if (err) bus_err <= 1'b1;
                    chunk_num <= 5'd0;
                    word_cnt  <= 10'd0;
                    state     <= ST_CHUNK_SEND;
                end
            end
            //----------------------------------------------------------------
            ST_CHUNK_SEND: begin
                dev_addr        <= I2C_ADDR;
                tx_data         <= {16'd0, chunk_reg_addr};
                tx_len          <= 3'd2;
                rd_len          <= CHUNK_WORDS[7:0] * 8'd2;  // 32 字 = 64 字节
                req             <= 1'b1;
                byte_hi_pending <= 1'b0;
                state           <= ST_CHUNK_WAIT;
            end
            //----------------------------------------------------------------
            ST_CHUNK_WAIT: begin
                if (hub_grant && rd_valid) begin
                    if (!byte_hi_pending) begin
                        hi_byte         <= rd_data;
                        byte_hi_pending <= 1'b1;
                    end else begin
                        frame_wr        <= 1'b1;
                        frame_addr      <= word_cnt;
                        frame_data      <= {hi_byte, rd_data};
                        if (word_cnt == 10'd800) ta_raw <= {hi_byte, rd_data};
                        word_cnt        <= word_cnt + 10'd1;
                        byte_hi_pending <= 1'b0;
                    end
                end
                if (hub_grant && done) begin
                    req <= 1'b0;
                    if (err) begin
                        bus_err  <= 1'b1;
                        tick_cnt <= 32'd0;
                        state    <= ST_PERIOD_WAIT;
                    end else if (chunk_num == TOTAL_CHUNKS - 5'd1) begin
                        state <= ST_FRAME_DONE;
                    end else begin
                        chunk_num <= chunk_num + 5'd1;
                        state     <= ST_CHUNK_SEND;
                    end
                end
            end
            //----------------------------------------------------------------
            ST_FRAME_DONE: begin
                frame_valid <= 1'b1;
                frame_cnt   <= frame_cnt + 16'd1;
                bus_err     <= 1'b0;
                tick_cnt    <= 32'd0;
                state       <= ST_PERIOD_WAIT;
            end
            //----------------------------------------------------------------
            ST_PERIOD_WAIT: begin
                if (tick_cnt >= PERIOD_TICKS - 32'd1) begin
                    tick_cnt <= 32'd0;
                    state    <= ST_POLL_SEND;
                end else begin
                    tick_cnt <= tick_cnt + 32'd1;
                end
            end
            //----------------------------------------------------------------
            default: state <= ST_POLL_SEND;
            endcase
        end
    end

endmodule
