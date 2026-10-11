//==========================================================================
//  mmt_i2c_hub.v  —  I2C 总线分时复用控制器
//--------------------------------------------------------------------------
//  赛题任务1 技术要点原文：「I2C 多设备管理：使用 I2C 地址区分不同传感器，
//  设计分时复用控制器」—— 本模块就是那个"分时复用控制器"。
//
//  多个传感器控制器（SHT30 / MLX90640 / 预留）共享一条 I2C 总线，
//  由本模块按轮询(round-robin)仲裁，同一时刻只授权一个客户端占用总线。
//
//  客户端握手（与 mmt_i2c_master 的接口契约一致）：
//    1. 客户端备好 dev_addr/tx_data/tx_len/rd_len 后把 req 拉高并保持；
//    2. 本模块选中它 → c_grant[i] 拉高，同时把它的信号转接到 I2C 主机；
//    3. 主机 done 回来后，本模块撤销 grant，并在下一拍给 c_done[i] 一个脉冲；
//    4. 客户端必须在看到 done 之后撤销 req。
//
//  读数据 rd_data/rd_valid 广播给所有客户端 —— 只有被授权的那个会真正消费，
//  这样省掉一路读数据 mux。
//
//  客户端信号用扁平向量传（Verilog-2001 端口不支持二维数组）：
//    第 i 个客户端的 7 位地址在 c_dev_addr[i*7 +: 7]，其余同理。
//
//  ★ 本版本把 N 限制在 2..4（轮询指针 ptr 是 2 位）。要更多客户端请加宽 ptr。
//==========================================================================
`timescale 1ns / 1ps

module mmt_i2c_hub #(
    parameter N = 3                       // 客户端数量，2..4
)(
    input  wire              clk,
    input  wire              rst_n,

    // ---- 客户端侧 ----
    input  wire [N-1:0]      c_req,
    input  wire [N*7-1:0]    c_dev_addr,
    input  wire [N*32-1:0]   c_tx_data,   // v2: 16→32 位（支持 4 字节寄存器写）
    input  wire [N*3-1:0]    c_tx_len,    // v2: 2→3 位（0..4 个字节）
    input  wire [N*8-1:0]    c_rd_len,
    output wire [N-1:0]      c_grant,
    output wire [N-1:0]      c_done,
    output wire [N-1:0]      c_err,
    output wire [N*8-1:0]    c_rd_data,   // 广播
    output wire [N-1:0]      c_rd_valid,  // 广播

    // ---- I2C 主机侧 ----
    output reg               m_req,
    output reg  [6:0]        m_dev_addr,
    output reg  [31:0]       m_tx_data,
    output reg  [2:0]        m_tx_len,
    output reg  [7:0]        m_rd_len,
    input  wire              m_busy,      // 仅用于观测/调试
    input  wire              m_done,
    input  wire              m_err,
    input  wire [7:0]        m_rd_data,
    input  wire              m_rd_valid
);

    //----------------------------------------------------------------------
    // 轮询仲裁：从 ptr 的下一个开始找，绕一圈回到 ptr 本身
    // （把 ptr 自己放最后 = 标准的 round-robin，不会饿死任何客户端）
    //----------------------------------------------------------------------
    reg [1:0] ptr;      // 上次服务过的客户端
    reg [1:0] sel;      // 本次授权的客户端
    reg       active;   // 0 = 空闲，1 = 已授权
    reg [N-1:0] c_armed;  // ★ 边沿重新武装：客户端 req 落下过才允许再次被选中
                          //   （与 mmt_i2c_master 的 req_armed 是同一个竞争问题，
                          //     不同时修会导致 hub 去 grant 一个 req 尚未撤销的客户端 → 死锁）

    // 只有"请求中且已重新武装"的客户端才参与仲裁
    wire [N-1:0] req_masked = c_req & c_armed;

    reg       found;
    reg [1:0] pick;
    integer   k;
    always @(*) begin
        found = 1'b0;
        pick  = 2'd0;
        for (k = 1; k <= N; k = k + 1) begin
            if (!found && req_masked[(ptr + k) % N]) begin
                found = 1'b1;
                pick  = ((ptr + k) % N);
            end
        end
    end

    //----------------------------------------------------------------------
    // 状态机
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr        <= 2'd0;
            sel        <= 2'd0;
            active     <= 1'b0;
            m_req      <= 1'b0;
            m_dev_addr <= 7'd0;
            m_tx_data  <= 32'd0;
            m_tx_len   <= 3'd0;
            m_rd_len   <= 8'd0;
            c_armed    <= {N{1'b1}};
        end else begin
            // req 落下的客户端重新武装（放在 case 之前；下面授权时的清零赋值优先）
            c_armed <= c_armed | (~c_req);

            if (!active) begin
                m_req <= 1'b0;
                if (found) begin
                    // 授权该客户端，并把它的参数转接到 I2C 主机
                    sel        <= pick;
                    active     <= 1'b1;
                    m_req      <= 1'b1;
                    c_armed[pick] <= 1'b0;      // 等它 req 落下再武装
                    m_dev_addr <= c_dev_addr[pick*7  +: 7];
                    m_tx_data  <= c_tx_data [pick*32 +: 32];
                    m_tx_len   <= c_tx_len  [pick*3  +: 3];
                    m_rd_len   <= c_rd_len  [pick*8  +: 8];
                end
            end else begin
                // 等主机结束。m_done 是单周期脉冲，在同一拍撤销 req，
                // 保证主机下一个周期回到 ST_IDLE 时看到 req=0，不会立刻重启。
                // 注意：c_done / c_err 是【组合】输出（见文件末尾 assign），
                // 必须在 m_done 这一拍就和 grant 同时有效，否则客户端用
                // "hub_grant && done" 判结束会永远等不到 —— 这是本模块 v1
                // 的真实 bug，已修。
                if (m_done) begin
                    m_req  <= 1'b0;
                    active <= 1'b0;
                    ptr    <= sel;
                end
            end
        end
    end

    // 授权位：只有 sel 那一位为 1
    assign c_grant = active ? ({{(N-1){1'b0}}, 1'b1} << sel) : {N{1'b0}};

    // c_done / c_err 必须与 c_grant 同拍，故用组合逻辑产生
    wire [N-1:0] sel_onehot = {{(N-1){1'b0}}, 1'b1} << sel;
    assign c_done = (active && m_done) ? sel_onehot : {N{1'b0}};
    assign c_err  = (active && m_done && m_err) ? sel_onehot : {N{1'b0}};

    assign c_rd_data  = {N{m_rd_data}};
    assign c_rd_valid = {N{m_rd_valid}};

endmodule
