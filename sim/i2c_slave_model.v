//==========================================================================
//  i2c_slave_model.v  —  行为级 I2C 从机模型（仿真专用，不可综合）
//--------------------------------------------------------------------------
//  hub / SHT30 / MLX90640 三个 testbench 共用。
//
//  ── 位计数约定（核心，搞清它就不会错）────────────────────────────────
//    bitn = 本字节内已出现的 SCL 上升沿数
//      bitn 0..7 : 8 个数据位（上升沿采样）
//      bitn 8    : 第 8 位采完；**此刻 rx 里已是完整字节，必须在这里决定 ACK**
//      bitn 9    : ACK 位采完，字节结束，做记账
//    于是：
//      · 上升沿：bitn<8 时采样 SDA，bitn 自增
//      · 下降沿：
//          bitn==8 → 决定并驱动 ACK/NACK（读事务则释放 SDA 让主机发 ACK）
//          bitn==9 → 字节结束：写事务存寄存器；读事务取下一个字节并驱动其 MSB
//          1..7 && 读事务 → 移出下一个数据位（正好 7 次移位覆盖 bit6..bit0）
//
//  ★ 曾经写错过的坑（留作前车之鉴）：
//    第一版把"决定 ACK"放在 bitn==9，但 ACK 是在 bitn==8 就驱动的 ——
//    先驱动后决策，导致 `nack_addr` 永远不生效（NACK 测试必然失败）。
//    根因是没分清"驱动 ACK 的时刻"和"结算字节的时刻"。
//
//  ── 开漏建模 ──────────────────────────────────────────────────────────
//    从机**只把 SDA 拉低**，释放时输出 z；上拉由 testbench 的 pullup 提供。
//==========================================================================
`timescale 1ns / 1ps

module i2c_slave_model #(
    parameter [6:0]   ADDR    = 7'h44,
    parameter integer MEM_N   = 1024
)(
    inout  wire        scl,
    inout  wire        sda,

    input  wire [15:0] mem_addr,
    input  wire [7:0]  mem_wdata,
    input  wire        mem_we,
    output wire [7:0]  mem_rdata,

    input  wire        nack_addr,
    output reg         got_start,
    output reg         got_stop,
    output reg         addr_matched,
    output reg  [7:0]  last_byte,
    output reg         last_byte_valid,
    output reg  [15:0] byte_count,
    output reg  [7:0]  wr_ptr_out,
    output reg         busy
);

    reg [7:0] mem [0:MEM_N-1];
    integer   i;
    assign mem_rdata = mem[mem_addr % MEM_N];

    // ★ 寄存器堆预装（testbench 用 mem_we 在总线还空闲时灌数据）。
    //   坑：原来只写了 `posedge scl or negedge scl`，而总线空闲时 SCL 一直被
    //   上拉、根本不跳变 —— 于是 testbench 在仿真最开始做的 sl_poke 全部丢失，
    //   从机读出来永远是全 0。必须把 posedge mem_we 也放进敏感列表。
    always @(posedge scl or negedge scl or posedge mem_we) begin
        if (mem_we) mem[mem_addr % MEM_N] = mem_wdata;
    end

    reg sda_low;
    assign sda = sda_low ? 1'b0 : 1'bz;

    reg [3:0] bitn;
    reg       active, rd, addr_ph;
    reg [7:0] rx, tx;
    reg [7:0] reg_ptr;
    reg       ack_seen;      // ★ 主机在读事务 ACK 位上的电平（1=NACK=最后一字节）

    // 完整字节已收齐（bitn==8 时有效）
    wire addr_ok = (rx[7:1] == ADDR) && !nack_addr;

    initial begin
        sda_low=1'b0; bitn=4'd0; active=1'b0; rd=1'b0; addr_ph=1'b1;
        rx=8'd0; tx=8'd0; reg_ptr=8'd0; ack_seen=1'b1;
        got_start=1'b0; got_stop=1'b0; addr_matched=1'b0;
        last_byte=8'd0; last_byte_valid=1'b0; byte_count=16'd0;
        wr_ptr_out=8'd0; busy=1'b0;
        for (i = 0; i < MEM_N; i = i + 1) mem[i] = 8'h00;
    end

    // ---------------------------------------------------------------- START / STOP
    always @(negedge sda) if (scl === 1'b1) begin
        active    <= 1'b1;
        bitn      <= 4'd0;
        addr_ph   <= 1'b1;
        sda_low   <= 1'b0;
        got_start <= 1'b1;
        busy      <= 1'b1;
        // ★ 每笔事务重新计数。byte_count 原来是全局累加的，于是第二笔事务里
        //   "第一个数据字节 = 寄存器地址"的判断（byte_count==1）永远不成立，
        //   命令字的第一个字节被当成数据写进 mem[reg_ptr] —— 表现为 SHT30 的
        //   0x2400 命令把 mem[0] 从 0x60 冲成 0x24，读回来的温度全错。
        byte_count <= 16'd0;
    end

    always @(posedge sda) if (scl === 1'b1 && active) begin
        active   <= 1'b0;
        sda_low  <= 1'b0;
        got_stop <= 1'b1;
        busy     <= 1'b0;
    end

    // ---------------------------------------------------------------- 采样
    always @(posedge scl) if (active) begin
        if (bitn < 4'd8) rx <= {rx[6:0], sda};
        // ★ 读事务的第 9 个上升沿（bitn==8）采到的是主机发的 ACK/NACK：
        //   1 = NACK = 主机说"这是最后一个字节"。必须记下来，否则从机会在
        //   最后一个字节之后继续驱动下一个字节的 MSB，把 SDA 一直拉住 ——
        //   主机的 STOP 条件（SCL 高时 SDA 上升）就永远做不出来。
        if (bitn == 4'd8) ack_seen <= sda;
        bitn <= bitn + 4'd1;
    end

    // ---------------------------------------------------------------- 驱动 / 结算
    always @(negedge scl) if (active) begin
        if (bitn == 4'd8) begin
            // ---- 8 位收齐：现在决定并驱动 ACK ----
            if (rd) begin
                sda_low <= 1'b0;                       // 读：ACK 由主机发
            end else if (addr_ph) begin
                sda_low      <= addr_ok ? 1'b1 : 1'b0; // 写地址：匹配则 ACK
                addr_matched <= addr_ok;
            end else begin
                sda_low <= 1'b1;                       // 写数据：一律 ACK
            end
        end else if (bitn == 4'd9) begin
            // ---- 字节结束：记账 ----
            bitn            <= 4'd0;
            last_byte       <= rx;
            last_byte_valid <= 1'b1;
            byte_count      <= byte_count + 16'd1;

            if (addr_ph) begin
                addr_ph <= 1'b0;
                rd      <= rx[0];
                if (addr_ok && rx[0]) begin
                    // 读事务：准备第一个数据字节，并立刻驱动它的 MSB
                    tx      <= mem[0];
                    reg_ptr <= 8'd1;
                    wr_ptr_out <= 8'd1;
                    sda_low <= ~mem[0][7];
                end else begin
                    reg_ptr <= 8'd0;
                    wr_ptr_out <= 8'd0;
                    sda_low <= 1'b0;
                end
            end else if (rd) begin
                // ★ 读事务的字节结算：装载下一个字节并驱动它的 MSB。
                //   原来这里没有这段，tx 只是被移空成 0 —— 多字节读（SHT30 要
                //   一次读 6 字节）除第一个字节外全是 0x00，CRC 必然不过。
                if (ack_seen) begin
                    // 主机回 NACK → 事务结束，释放 SDA 让 STOP 能成立
                    rd      <= 1'b0;
                    sda_low <= 1'b0;
                end else begin
                    tx         <= mem[reg_ptr % MEM_N];
                    sda_low    <= ~mem[reg_ptr % MEM_N][7];
                    reg_ptr    <= reg_ptr + 8'd1;
                    wr_ptr_out <= reg_ptr + 8'd1;
                end
            end else begin
                sda_low <= 1'b0;
                if (!rd) begin
                    // 写事务数据字节：第一个当寄存器地址，其余写进寄存器文件
                    if (byte_count == 16'd1) begin
                        reg_ptr    <= rx;
                        wr_ptr_out <= rx;
                    end else begin
                        mem[reg_ptr % MEM_N] <= rx;
                        reg_ptr    <= reg_ptr + 8'd1;
                        wr_ptr_out <= reg_ptr + 8'd1;
                    end
                end
            end
        end else if (rd && bitn >= 4'd1 && bitn <= 4'd7) begin
            // ---- 读事务：移出下一个数据位（7 次移位覆盖 bit6..bit0）----
            tx      <= {tx[6:0], 1'b0};
            sda_low <= ~tx[6];
        end
    end

endmodule
