//==========================================================================
//  mmt_i2c_master.v  —  通用 I2C 主机（字节级引擎）
//--------------------------------------------------------------------------
//  模块名前缀 mmt_ 用于避开板卡包 demo 里的同名模块。
//
//  一次事务的时序：
//    [START] [addr+W] [tx_len 个字节] [重复START] [addr+R] [rd_len 个字节] [STOP]
//
//     tx_len>0, rd_len=0  → 纯写事务
//     tx_len=0, rd_len>0  → 纯读事务（地址字节直接带 R）
//     tx_len>0, rd_len>0  → 写子地址后重复起始读  ← MLX90640 用这种
//
//  两种传感器的实际用法：
//    SHT30     : 写 {0x2C,0x06} 启动单次测量(纯写)；稍后纯读 6 字节
//                (温度MSB/LSB/CRC + 湿度MSB/LSB/CRC)
//    MLX90640  : 写 2 字节寄存器地址后重复起始读 N 字节
//                例：0x2400 起读 64 字节(32 个 16bit 像素)，0x06 读环境温度
//
//  时序实现：
//    SCL 由 ph[1:0] 四相产生：ph=0/1 时 SCL 低，ph=2/3 时 SCL 高
//    SDA 只在 ph==1 改变（此刻 SCL 为低，满足 I2C 数据建立要求）
//    SDA 只在 ph==2 采样（此刻 SCL 为高，数据稳定）
//    状态推进统一在 ph==3 的末尾
//
//  SCL/SDA 为开漏：oe=0 表示释放（靠外部上拉变高），oe=1 时输出 scl_o/sda_o
//
//  ── 修订记录 ──────────────────────────────────────────────────────────
//  v2 (2026-09-20)  两处修正，均由"传感器子系统真正实例化后综合"暴露出来：
//    (1) 【多驱动 bug】scl_o 曾被两个 always 块同时赋值（相位块 + FSM 块），
//        综合报 VDB-1000 "net 'scl_o' is constantly driven from multiple places"。
//        根因：只把模块列进文件表、不实例化时，综合器会整块优化掉，等于没检查。
//        现在 scl_o 只由相位块驱动；FSM 只控制 scl_oe。
//    (2) 【接口宽度不足】tx_data 原为 16 位、tx_len 最多 2 字节，写不了
//        MLX90640 的 CTRL_REG(0x800D) —— 那是"地址 2 字节 + 数据 2 字节"共
//        4 字节的寄存器写。现加宽为 tx_data[31:0] / tx_len[2:0]（0..4 字节）。
//
//  v3 (2026-09-20)  仿真器（iverilog）装上后第一次真正跑通编译，编译器自己报出的
//    真 bug（人工review完全没看出来）：bit_cnt 只声明 3 位（0..7），但代码里到处
//    比较 bit_cnt < 4'd8 / == 4'd8 —— 4'd8 这个字面量本身装不进 3 位，按 Verilog
//    规则会被截断成 4'd0！结果 bit_cnt<4'd8 恒假、bit_cnt==4'd8 只在 bit_cnt=0
//    时成立——ACK 判断和字节边界从一开始就是错的，每个"字节"实际只发了 1 位就
//    误判成发完了。iverilog 报的是 warning（不是 error）"Numeric constant
//    truncated to 3 bits"，综合器大概率也只是同样静默截断，不会报错——这个 bug
//    此前不会被任何一次综合跑通所排除。已修：bit_cnt 改 4 位（[3:0]），所有相关
//    比较/加法字面量同步改成 4'd8 / 4'd7 / 4'd1 / 4'd0。
//
//  tx_data 字节约定（**右对齐**）：tx_len=N 时，要发的 N 个字节占据
//  tx_data[N*8-1:0]，且 **第 0 个先发**的那个字节在 tx_data[N*8-1 -: 8]。
//     tx_len=1 → 只发 tx_data[7:0]
//     tx_len=2 → 先发 tx_data[15:8]，再发 tx_data[7:0]
//     tx_len=4 → 依次 tx_data[31:24],[23:16],[15:8],[7:0]
//  例：SHT30 命令 0x2400 → tx_data=32'h0000_2400, tx_len=2（先 0x24 后 0x00）
//      写 MLX90640 CTRL_REG → tx_data=32'h800D_0000, tx_len=4（0x80,0x0D,0x00,0x00）
//==========================================================================
`timescale 1ns / 1ps

module mmt_i2c_master #(
    parameter CLK_HZ = 100_000_000,   // 输入时钟频率
    parameter SCL_HZ = 100_000        // 目标 SCL 频率
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 命令接口 ----
    input  wire        req,           // 电平请求；握手完成后由 busy/done 撤销
    input  wire [6:0]  dev_addr,      // 7 位器件地址
    input  wire [31:0] tx_data,       // 见文件头"tx_data 字节约定"（右对齐）
    input  wire [2:0]  tx_len,        // 0..4 个写字节
    input  wire [7:0]  rd_len,        // 读字节数，0 表示不读

    output reg         busy,
    output reg         done,          // 事务结束脉冲（成功或失败都会给）
    output reg         err,           // 1 = 本次事务中从机未应答(NACK)

    // ---- 读数据流 ----
    output reg  [7:0]  rd_data,
    output reg         rd_valid,      // 与 rd_data 同拍，1 个 clk 宽

    // ---- I2C 物理接口（开漏三态）----
    input  wire        scl_i,
    output wire        scl_o,
    output wire        scl_oe,
    input  wire        sda_i,
    output reg         sda_o,
    output reg         sda_oe
);

    //----------------------------------------------------------------------
    // 分相时钟
    //----------------------------------------------------------------------
    localparam integer DIV_RAW = CLK_HZ / (SCL_HZ * 4);
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;

    reg [15:0] div_cnt;
    reg        scl_oe_r;
    reg  [23:0] str_cnt;
    wire       stretch_to = (&str_cnt);   // ★ 内部「想拉低 SCL」标志；真正到 pad 的开漏使能由相位决定
    reg [1:0]  ph;
    reg        scl_hold_low;   // ★ 强制 SCL 保持低（START/重复START 后那一位周期用）

    wire tick   = (div_cnt == DIV[15:0] - 16'd1);
    // ★ PERIPH07：时钟拉伸——已放开 SCL 但线仍为低 ⇒ 从机在拉，冻结相位等线抬高
    wire scl_want_high = scl_oe_r && (ph >= 2'd2) && !scl_hold_low;
    wire stretch       = scl_want_high && !scl_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           str_cnt <= 24'd0;
        else if (!stretch)    str_cnt <= 24'd0;
        else if (!(&str_cnt)) str_cnt <= str_cnt + 1'b1;
    end
    wire act_sda  = tick && (ph == 2'd1) && !stretch;   // SDA 改变时机（SCL 低）
    wire act_samp = tick && (ph == 2'd2) && !stretch;   // SDA 采样时机（SCL 高）
    wire act_next = tick && (ph == 2'd3) && !stretch;   // 位结束，状态推进

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 16'd0;
            ph      <= 2'd0;
        end else if (tick) begin
            if (stretch) begin
                div_cnt <= div_cnt;        // 拉伸期间冻结相位
            end else begin
                div_cnt <= 16'd0;
                ph      <= ph + 2'd1;
            end
        end else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    // SCL 输出电平由相位决定（oe 决定是否驱动）。
    // ★ v4 修正：START / 重复START 之后的那一位周期必须【持续保持低】，
    //   否则相位块会在 ph>=2 时把它抬起来，多出一个 SCL 上升沿 ——
    //   从机会把这个多余的沿当成一个数据位，导致整体错一位、地址被 NACK。
    //   这正是 Claude 用 testbench 观察到的现象（START 后多一次低→高跳变）。
    // ★ PERIPH07：SCL 改【开漏】——只拉低，抬高交给上拉。
    //   原实现 oe=1 时一直推挽驱动（高/低都由 FPGA 给），从机想拉伸时会被顶回去。
    assign scl_o  = 1'b0;
    assign scl_oe = scl_oe_r && ((ph < 2'd2) || scl_hold_low);

    //----------------------------------------------------------------------
    // 事务状态机
    //----------------------------------------------------------------------
    localparam [3:0] ST_IDLE    = 4'd0,
                     ST_START1  = 4'd1,   // SDA 下降（SCL 高）→ 起始条件
                     ST_START2  = 4'd2,   // SCL 拉低
                     ST_TX      = 4'd3,   // 发送 8 bit + 收 ACK
                     ST_RSTART1 = 4'd4,   // 释放 SDA/SCL
                     ST_RSTART2 = 4'd5,   // SDA 下降（SCL 高）→ 重复起始
                     ST_RSTART3 = 4'd6,   // SCL 拉低
                     ST_RX      = 4'd7,   // 收 8 bit + 发 ACK/NACK
                     ST_STOP1   = 4'd8,   // SDA 拉低
                     ST_STOP2   = 4'd9,   // SCL 放开→高
                     ST_STOP3   = 4'd10,  // SDA 放开→高 = 停止条件
                     ST_DONE    = 4'd11;

    reg [3:0]  state;
    reg [3:0]  bit_cnt;      // 0..7 数据位, 8 = ACK 位（★4位！3位装不下8，见下方v3说明）
    reg [7:0]  tx_byte;
    reg [7:0]  rx_shift;
    reg [7:0]  rd_cnt;
    reg [2:0]  tx_idx;       // 0 = 器件地址字节；1..tx_len = 数据字节
    reg [31:0] tx_shift;     // 预左对齐的待发字节串（最高字节先发）
    reg        raddr_phase;  // 1 = 当前发的地址字节是"读"地址
    reg        ack_bit;
    reg        req_armed;    // ★ 边沿重新武装：见下方 req/done 竞争说明

    // 本次事务是否需要"先写地址再读"
    wire       do_read = (rd_len != 8'd0);
    // 纯读事务时，器件地址字节的 R/W 位直接置 1
    wire       addr_rw = (do_read && (tx_len == 2'd0)) ? 1'b1 : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            err       <= 1'b0;
            rd_data   <= 8'd0;
            rd_valid  <= 1'b0;
            scl_oe_r    <= 1'b0;
            sda_oe    <= 1'b0;
            sda_o     <= 1'b0;
            bit_cnt   <= 4'd0;
            tx_byte   <= 8'd0;
            rx_shift  <= 8'd0;
            rd_cnt    <= 8'd0;
            tx_idx    <= 4'd0;
            tx_shift  <= 32'd0;
            raddr_phase <= 1'b0;
            ack_bit   <= 1'b0;
            req_armed <= 1'b1;
            scl_hold_low <= 1'b0;
        end else begin
            done     <= 1'b0;
            rd_valid <= 1'b0;

            // ★ req/done 竞争修正（由 Claude 复审发现，方案：边沿重新武装）
            //   问题：ST_DONE 拍的下一拍，state 已是 ST_IDLE，而 done 恰好也在这一拍有效；
            //   请求方按约定"看到 done 才撤 req"，撤销要再等一拍才生效，所以本拍读到的
            //   req 还是旧的 1 —— 原实现会立刻用残留参数再发一次事务。
            //   修法：只有观察到 req 曾经落下过（req==0）才重新允许接受请求。
            //   放在 case 之前：ST_IDLE 里接受请求时会再赋 0，后赋值优先，语义正确。
            if (!req) req_armed <= 1'b1;

            case (state)
            //--------------------------------------------------------------
            ST_IDLE: begin
                scl_oe_r <= 1'b0;
                sda_oe <= 1'b0;
                busy   <= 1'b0;
                // ★ v5 关键修正：**只在分相时钟的位边界（ph==0 且 div_cnt==0）接受请求**。
                //   背景：div_cnt/ph 是自由运行的，而 ST_IDLE 接受请求的那一刻相位是
                //   任意的。ST_START1 靠 act_sda(ph==1) 把 SDA 拉低来产生 START 条件，
                //   靠 act_next(ph==3) 推进状态。如果进入 ST_START1 时 ph 已经走过 1，
                //   这个位周期内 act_sda 再也不会来，而 act_next 照样把状态推到
                //   ST_START2 —— SDA 从没被拉低，START 条件根本没产生，从机不会
                //   激活，于是地址字节必然收到 NACK。
                //   复位后的第一次事务恰好 ph=0 所以"看着是对的"，之后每一次都错，
                //   表现为"第一条命令成功、后面全 err=1"这种极具迷惑性的现象。
                //   对齐到 (ph==0 && div_cnt==0) 之后，ST_START1 里 act_sda 一定先于
                //   act_next 出现，START 必然成立；顺带也让地址字节的 8 个数据位
                //   与分相时钟严格对齐（原来会整体错相位）。
                if (req && req_armed && (ph == 2'd0) && (div_cnt == 16'd0)) begin
                    busy     <= 1'b1;
                    err      <= 1'b0;
                    req_armed <= 1'b0;      // 等 req 落下后才会重新武装
                    tx_byte  <= {dev_addr, addr_rw};
                    bit_cnt  <= 4'd0;
                    rd_cnt   <= 8'd0;
                    tx_idx   <= 4'd0;
                    raddr_phase <= 1'b0;
                    // 把要发的数据字节左对齐，使"最先发"的字节落在 [31:24]
                    case (tx_len)
                        4'd0:    tx_shift <= 32'd0;
                        4'd1:    tx_shift <= {tx_data[7:0],  24'h0};
                        4'd2:    tx_shift <= {tx_data[15:0], 16'h0};
                        4'd3:    tx_shift <= {tx_data[23:0],  8'h0};
                        default: tx_shift <= tx_data;
                    endcase
                    state    <= ST_START1;
                end
            end
            //--------------------------------------------------------------
            // 起始条件：SCL 已是高（oe=0），把 SDA 拉低
            ST_START1: begin
                if (act_sda) begin
                    sda_oe <= 1'b1;
                    sda_o  <= 1'b0;
                end
                if (act_next) state <= ST_START2;
            end
            //--------------------------------------------------------------
            ST_START2: begin
                if (act_sda) begin
                    scl_oe_r       <= 1'b1;   // SCL 拉低
                    scl_hold_low <= 1'b1;   // ★ 并禁止相位块在这一位周期内把它抬高
                end
                if (act_next) begin
                    bit_cnt      <= 4'd0;
                    scl_hold_low <= 1'b0;   // 交给下一位周期的正常相位
                    state        <= ST_TX;
                end
            end
            //--------------------------------------------------------------
            // 发送一个字节 + 读回 ACK
            ST_TX: begin
                if (act_sda) begin
                    if (bit_cnt < 4'd8) begin
                        sda_oe <= 1'b1;
                        sda_o  <= tx_byte[4'd7 - bit_cnt];
                    end else begin
                        sda_oe <= 1'b0;          // 第 9 位释放 SDA，让从机拉低
                    end
                end
                if (act_samp && (bit_cnt == 4'd8)) ack_bit <= sda_i;
                if (act_next) begin
                    if (bit_cnt < 4'd8) begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end else begin
                        bit_cnt <= 4'd0;
                        // ---- 一个字节发完，决定下一步 ----
                        if (ack_bit) begin
                            err   <= 1'b1;              // 从机未应答
                            state <= ST_STOP1;
                        end else if (raddr_phase) begin
                            // 读地址字节发完 → 开始收数据
                            raddr_phase <= 1'b0;
                            state       <= ST_RX;
                        end else if (tx_idx == 4'd0) begin
                            // 刚发完器件地址字节
                            if (tx_len == 4'd0) begin
                                state <= do_read ? ST_RX : ST_STOP1;
                            end else begin
                                tx_byte  <= tx_shift[31:24];
                                tx_shift <= {tx_shift[23:0], 8'h00};
                                tx_idx   <= 4'd1;
                                state    <= ST_TX;
                            end
                        end else if (tx_idx < tx_len) begin
                            // 还有数据字节要发
                            tx_byte  <= tx_shift[31:24];
                            tx_shift <= {tx_shift[23:0], 8'h00};
                            tx_idx   <= tx_idx + 4'd1;
                            state    <= ST_TX;
                        end else begin
                            // 所有数据字节发完
                            if (do_read) state <= ST_RSTART1;
                            else         state <= ST_STOP1;
                        end
                    end
                end
            end
            //--------------------------------------------------------------
            // 重复起始：先放开 SDA/SCL，再 SDA 下降，再 SCL 拉低
            ST_RSTART1: begin
                if (act_sda) begin
                    scl_oe_r <= 1'b0;   // SCL 升高
                    sda_oe <= 1'b0;   // SDA 升高
                end
                if (act_next) state <= ST_RSTART2;
            end
            ST_RSTART2: begin
                if (act_sda) begin
                    sda_oe <= 1'b1;   // SCL 为高时 SDA 下降 = 起始条件
                    sda_o  <= 1'b0;
                end
                if (act_next) begin
                    tx_byte     <= {dev_addr, 1'b1};   // 读地址
                    raddr_phase <= 1'b1;
                    state       <= ST_RSTART3;
                end
            end
            ST_RSTART3: begin
                if (act_sda) begin
                    scl_oe_r       <= 1'b1;   // SCL 拉低
                    scl_hold_low <= 1'b1;   // ★ 同上，避免重复START后多出一个时钟脉冲
                end
                if (act_next) begin
                    bit_cnt      <= 4'd0;
                    scl_hold_low <= 1'b0;
                    state        <= ST_TX;
                end
            end
            //--------------------------------------------------------------
            // 接收一个字节 + 回 ACK/NACK
            ST_RX: begin
                // ★ PERIPH08：读数据位在【ph0 一开始】就释放 SDA。
                //   原来在 ph1 末尾释放，只比 SCL 抬高早一个相位；上拉慢时 SDA 还在爬升，
                //   从机会把「SCL 高 + SDA 上升」认成 STOP，于是停发（实测只回 1~3 字节）。
                if (tick && (ph == 2'd0) && !stretch && (bit_cnt < 4'd8)) sda_oe <= 1'b0;
                if (act_sda && (bit_cnt >= 4'd8)) begin
                    // 第 9 位：最后一个字节回 NACK(1)，其余回 ACK(0)
                    sda_oe <= 1'b1;
                    sda_o  <= ((rd_cnt + 8'd1) >= rd_len) ? 1'b1 : 1'b0;
                end
                if (act_samp && (bit_cnt < 4'd8)) begin
                    rx_shift <= {rx_shift[6:0], sda_i};
                end
                if (act_next) begin
                    if (bit_cnt < 4'd8) begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end else begin
                        bit_cnt  <= 4'd0;
                        rd_data  <= rx_shift;
                        rd_valid <= 1'b1;
                        rd_cnt   <= rd_cnt + 8'd1;
                        if ((rd_cnt + 8'd1) >= rd_len) state <= ST_STOP1;
                        else                           state <= ST_RX;
                    end
                end
            end
            //--------------------------------------------------------------
            // 停止条件：SDA 先低 → SCL 升 → SDA 升（SCL 高）
            ST_STOP1: begin
                if (act_sda) begin
                    sda_oe <= 1'b1;
                    sda_o  <= 1'b0;
                end
                if (act_next) state <= ST_STOP2;
            end
            ST_STOP2: begin
                if (act_sda) scl_oe_r <= 1'b0;   // SCL 升高，SDA 仍为低
                if (act_next) state <= ST_STOP3;
            end
            ST_STOP3: begin
                if (act_sda) sda_oe <= 1'b0;   // SDA 升高（SCL 为高）= 停止条件
                if (act_next) state <= ST_DONE;
            end
            //--------------------------------------------------------------
            ST_DONE: begin
                scl_oe_r <= 1'b0;
                sda_oe <= 1'b0;
                busy   <= 1'b0;
                done   <= 1'b1;
                state  <= ST_IDLE;
            end
            //--------------------------------------------------------------
            default: state <= ST_IDLE;
            endcase

            // ★ 拉伸超时：约 0.6 s 仍被拉住 → 放弃本次事务并报 err
            if (stretch_to) begin
                scl_oe_r <= 1'b0;
                sda_oe   <= 1'b0;
                err      <= 1'b1;
                state    <= ST_DONE;
            end
        end
    end

endmodule