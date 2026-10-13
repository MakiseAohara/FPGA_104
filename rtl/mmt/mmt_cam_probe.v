//==========================================================================
//  mmt_cam_probe.v  —  摄像头上游探针（task-19）
//--------------------------------------------------------------------------
//  干什么：把**4 个时钟域**里的"摄像头链路"信号，变成 core_clk 域里可读的
//          累计计数器 + 状态字，串口读出来就能回答：
//            「像素到底卡在哪一段？I2C 没跑？字节/像素时钟没来？CSI RX 没解出像素？」
//
//  监测对象（按信号链从上游往下）：
//    1) cam_scl       = io_cam_scl_OUT      (CLK_5M 域)  —— 摄像头 I2C 配置有没有真跑
//    2) clk_byte      = i_cam_ck_CLKOUT     (字节时钟)   —— MIPI 字节时钟在不在
//    3) clk_pixel     = i_mipi_rx_pclk      (像素时钟)   —— MIPI 像素时钟在不在
//    4) csi_de/hs/vs  = w_mipi_rx_*         (像素时钟)   —— ★ CSI RX 有没有吐像素
//    5) CSI RX 明文状态：word_count / datatype / vc / pixel_per_clk / fifo_rd_empty / irq
//       （CSI RX 端口表里**没有 PLL lock** 输出，见 docs §1 的实测清单；
//         这几个是最接近"链路状态"的明文，比计数更直接）
//
//  ---------------------------------------------------------------------------
//  跨时钟域怎么做（这是本模块的核心，别改坏）
//  ---------------------------------------------------------------------------
//  绝对**不能**把多 bit 计数器直接打两拍搬过来 —— 高位低位不同时更新时，
//  会读到一个"从未存在过"的中间值（ `rtl\mmt\common\mmt_sync2.v:6-14` 写明了这个限制）。
//  本模块统一用 **"源域翻转标志 + 2FF 同步 + 目标域边沿检测累加"**：
//
//      源域(clk_x)：  x_d <= x;  if (x != x_d) x_tg <= ~x_tg;      // 只搬 1 bit
//            ──2FF(mmt_sync2)──►  core_clk：  if (x_tg_s != x_tg_sd) cnt <= cnt+1;
//
//  · 得到的是**单调递增值**，语义 = "源域信号变化了多少次"（不需要精确到 1 拍）
//  · 计数器在 core_clk 域，被寄存器块读到，不会被优化掉
//  · 时钟探针（2 个时钟）用"源域自由分频 → 翻转"实现：时钟死了就不翻转 ⇒ 计数不涨。
//    分频 2^PRESCALE_BITS（默认 1024）：**1 次计数 = 1024 个源时钟周期**，
//    所以"频率 ≈ 增量 × 1024 ÷ 采样间隔秒数"。分频是为了让 32 位计数器慢点绕回
//    （像素时钟 74MHz 不分频的话 107 秒就绕回一次）。
//
//  ⚠️ 已知限制（写在明处，别过度解读数字）：
//    a) 源域信号变化率接近 core_clk/2（50MHz）时会**漏计**；本模块监测的
//       SCL(~100kHz)、de/hs/vs(≤几百 kHz) 远低于该上限，计数可当作准确。
//    b) 复位统一用 core 域的异步 `rst_n`（探针只做诊断，不参与功能；复位释放
//       跨域最多让某个计数器多计 1 次，无害）。
//    c) `csi_*` 状态字按"**准静态**"处理（逐位 2FF）：它们不是计数值，
//       偶尔读到旧值可接受。**其中 word_count 的时钟域是【推断】= clk_pixel**，
//       若上板看到它的计数明显不合理，说明它其实在字节时钟域
//       （那时把 `wc_d/wc_tg` 那一段的时钟换成 clk_byte 即可，一行改动）。
//
//  ---------------------------------------------------------------------------
//  寄存器窗口（相对本探针的索引 raddr；mmt_soc_regs 把它映射到 0x80..0xA4）
//  ---------------------------------------------------------------------------
//    idx  偏移    名称            内容
//     0   0x80   CAM_SCL_CNT     [31:0] cam_scl 的变化次数（I2C 配置活动的证据）
//     1   0x84   CAM_CK_CNT      [31:0] clk_byte   探针计数（×1024 = 字节时钟周期数）
//     2   0x88   CAM_PCLK_CNT    [31:0] clk_pixel  探针计数（×1024 = 像素时钟周期数）
//     3   0x8C   CSI_DE_CNT      [31:0] csi_de 变化次数     ★ 最关键
//     4   0x90   CSI_HS_CNT      [31:0] csi_hs 变化次数
//     5   0x94   CSI_VS_CNT      [31:0] csi_vs 变化次数（≈ 帧数×2）
//     6   0x98   CAM_PROBE_ST    [0]=scl 电平 [1]=ck 探针电平 [2]=pclk 探针电平
//                                 [3]=de 电平 [4]=hs 电平 [5]=vs 电平
//                                 [6]=scl_seen [7]=de_seen [8]=hs_seen [9]=vs_seen
//                                 [10]=ck_seen [11]=pclk_seen [12]=wc_seen
//                                 [13]=I2C SDA 当前电平 [14]=pd_any 粘滞
//                                 （seen = "开机以来曾变化过"的粘滞位）
//     7   0x9C   CSI_LINK_ST     [3:0]=pixel_per_clk [7:4]=fifo_rd_empty [8]=irq
//                                 [10:9]=vc [16:11]=datatype
//                                 ★ [31:17] = 15'h2A5C **位流魔数**（见下）
//     8   0xA0   CSI_WC_CNT      word_count **值变化次数**（★ 不是包数，见下）
//     9   0xA4   CSI_WC_NOW      [15:0] word_count 当前快照
//    10   0xB0   PROBE_ID        = 32'h4D4D5450 ("MMTP") ★ **位流魔数**（全 32 位）
//    11   0xB4   CSI_PD_CNT      [31:0] "de && pixel_data!=0" 拍数（÷1024，数据有效性）
//    12   0xB8   CSI_WC_MAX      [15:0] 历史最大 word_count（这个包最大多少词）
//    13   0xBC   I2C_ACK_CNT     [31:0] I2C **ACK 次数**（从器件把 SDA 拉低）
//    14   0xC0   I2C_NACK_CNT    [31:0] I2C NACK 次数（没人应答）
//    15   0xC4   RST_HS_STAT     [0]=core 域 rstn(1=三个 PLL 都锁定) [1]=像素域 rstn(1=已释放)
//                                 [2]=ck_HS_ENA 电平 [6:3]=d0..d3_HS_ENA 电平
//                                 [7]=ck 曾拉起 [11:8]=d0..d3 曾拉起
//                                 ★ 自检：core=1 而 像素=0 逻辑上不可能 ⇒ 读到就说明
//                                    `i_mipi_rx_pclk` 没在跑
//
//  ---------------------------------------------------------------------------
//  ★ 位流魔数为什么必须有（Claude 审查提出，task-24）
//  ---------------------------------------------------------------------------
//  旧位流（没有本探针）读 0x80..0xA4 一律返回 0 —— 而"探针在、但计数与链路参数恰好都是 0"
//  读出来**一模一样**，分不出来。所以两处都放魔数（冗余但便宜）：
//    · `link[31:17]`  = 15'h2A5C
//    · `PROBE_ID`     = 32'h4D4D5450 ("MMTP")
//  串口上**读到魔数才证明这版位流里有探针**；读不到 ⇒ 位流没重编。
//
//  ★ `CSI_WC_CNT` 的语义（被 Claude 纠正过，别误读）
//  ---------------------------------------------------------------------------
//  它数的是 **`word_count` 这个值变化的次数**，不是"解出的包数"：
//  同一帧内各行包的 `word_count` 往往相同 ⇒ 稳态下**每帧只变几次，`wc(d=0)` 是正常的**，
//  不能当故障。要看"包/行在不在动"用 `CSI_HS_CNT`(0x90)/`CSI_VS_CNT`(0x94)；
//  要看"这个包多大"用 `CSI_WC_MAX`(0xB8) 与 `CSI_WC_NOW`(0xA4)。
//
//  ★ I2C ACK 计数为什么必须有（task-24）
//  ---------------------------------------------------------------------------
//  `i2c_16addr_8data.v` **不做 ACK 判断**，配置序列不管 NACK 都照样发完 ⇒
//  光看 SCL 跳变数，"传感器响应了"和"根本没接/没响应"**数字一模一样**。
//  本模块在 CLK_5M 域做一个小 I2C 监视器：数 SCL 的第 9 个脉冲高电平期间
//  `io_cam_sda_IN` 是否为低 ⇒ 那就是从器件的 ACK。
//
//  ★ 关于 `cam_scl` 这个端口名（Lead 已改接法，别再退回）
//  ---------------------------------------------------------------------------
//  它现在接的是 **`io_cam_scl_OE`**（输出使能），**不是** `io_cam_scl_OUT`：
//  OpenCores I2C 是开漏写法，`scl_o` 恒为 0（`i2c_master_ctrl_top.v:13` 注释即写明），
//  真正翻转的是使能。本模块内部按"**OE=1 ⇒ SCL 被拉低（低电平）**"处理
//  （`mmt_top.v:679` 是 `io_cam_scl_OE = ~scl_padoen_o`）。
//
//  实例化位置：mmt_top.v（那边才有这些域的信号/时钟）；读口接到 mmt_soc_regs。
//  加进工程：**必须**在 mmt.xml 的 design_file 清单里加一行（见文档 §2 的补丁步骤 0）。
//==========================================================================
`timescale 1ns / 1ps

module mmt_cam_probe #(
    parameter PRESCALE_BITS = 10          // 时钟探针分频：2^10 = 1024
)(
    // ---------------- 观察域（core_clk = 系统 100MHz）----------------
    input  wire        clk,               // core_clk
    input  wire        rst_n,             // 低有效异步复位（core 域）

    // ---------------- 被观察域各自的时钟 ----------------
    input  wire        clk_5m,            // CLK_5M：摄像头 I2C 配置时钟
    input  wire        clk_byte,          // i_cam_ck_CLKOUT：MIPI 字节时钟
    input  wire        clk_pixel,         // i_mipi_rx_pclk：MIPI 像素时钟

    // ---------------- 待观察信号（各自时钟域）----------------
    input  wire        cam_scl,           // io_cam_scl_**OE**（开漏使能：1=SCL 被拉低）(clk_5m)
    input  wire        cam_sda,           // io_cam_sda_IN（真实 SDA 线电平）        (clk_5m)
    input  wire        csi_de,            // w_mipi_rx_de        (clk_pixel)
    input  wire        csi_hs,            // w_mipi_rx_hs        (clk_pixel)
    input  wire        csi_vs,            // w_mipi_rx_vs        (clk_pixel)
    input  wire [63:0] csi_pixel_data,    // w_mipi_rx_data（判"数据有效性"用）     (clk_pixel)

    // ---------------- 复位 / PLL 状态（task-24 追加 1）----------------
    //   pix_rstn = mmt_top.v 的 w_mipi_rx_pclk_arstn（像素域复位，1=已释放）
    //   ★ 注意：core 域的 w_arstn 本来就是本模块的 rst_n 端口，所以**不用**再加端口，
    //     内部 2FF 出来即可（w_arstn = i_pll_locked & pll_locked & user_pll_locked，
    //     见 mmt_top.v:499 —— 它为 1 说明三个 PLL 全锁定）。
    input  wire        pix_rstn,          // w_mipi_rx_pclk_arstn（像素域）

    // ---------------- MIPI LP/HS 握手状态（task-24 追加 2，★最关键）----------------
    //   【实测】这 5 根都是 csi_rx_controller 的**输出**（IP 在命令 PHY 进 HS）：
    //     ip\csi_rx_controller\csi_rx_controller.sv:59 `output Rx_HS_enable_C`
    //                                              :71 `output [3:0] Rx_HS_enable_D`
    //   ⇒ 按"**电平 + 粘滞位**"处理（曾经拉起过 = 摄像头真的进过 HS 模式）。
    //   时钟域【推断】：由 IP 的 PHY 控制逻辑驱动，多半在字节时钟域；
    //   这里只取"准静态电平"，逐位 2FF 足够（不做计数，不涉及多 bit 一致性）。
    input  wire        hs_ck_ena,         // o_cam_ck_HS_ENA   （时钟 lane）
    input  wire        hs_d0_ena,         // cam_d0_HS_ENA     （数据 lane 0）
    input  wire        hs_d1_ena,         // cam_d1_HS_ENA
    input  wire        hs_d2_ena,         // cam_d2_HS_ENA
    input  wire        hs_d3_ena,         // cam_d3_HS_ENA

    // ---------------- CSI RX 明文状态（clk_pixel 域，【推断】）----------------
    input  wire [15:0] csi_word_count,    // csi_rx_controller.sv:98
    input  wire [5:0]  csi_datatype,      //                      :96
    input  wire [1:0]  csi_vc,            //                      :100
    input  wire [3:0]  csi_pixel_per_clk, //                      :95
    input  wire [3:0]  csi_fifo_rd_empty, //                      :74（是 IP 的**输入**，由 lane FIFO 喂）
    input  wire        csi_irq,           //                      :92

    // ---------------- 寄存器读口（由 mmt_soc_regs 驱动）----------------
    input  wire [3:0]  raddr,             // 0..14 ⇒ 0x80..0xC0
    output reg  [31:0] rdata
);

    //==========================================================
    // 1. 源域：跳变检测 + 翻转标志（每个信号 1 bit toggle）
    //==========================================================
    // ★ 为什么每个寄存器都带初值 `= 1'b0`（**很重要，别删**）：
    //   本探针要监测的正是"某个域的时钟**还没来**"这种情形（摄像头时钟 lane 没锁定
    //   ⇒ 字节/像素时钟根本不存在）。若该域的寄存器没有确定的复位/初值，
    //   它会停在 X，而 `if (cam_scl != scl_d)` 一旦两边含 X 就**永远不成立**
    //   ⇒ 即使后来时钟来了、信号也动了，计数器也永远是 0 —— 那恰好会把
    //   "时钟后来来了但被 X 卡死" 误报成 "一直没动"。
    //   固定初值在 FPGA 里由位流的 FF 初值实现（Efinity 支持），仿真里同样生效。
    //   （这个坑是 task-19 的仿真实测抓到的：把 clk_5m 的第一次沿推迟到复位释放之后，
    //     计数器就恒 0；加初值后正常。）
    (* preserve, syn_keep = 1 *) reg scl_d = 1'b0, scl_tg = 1'b0;
    (* preserve, syn_keep = 1 *) reg de_d  = 1'b0, de_tg  = 1'b0;
    (* preserve, syn_keep = 1 *) reg hs_d  = 1'b0, hs_tg  = 1'b0;
    (* preserve, syn_keep = 1 *) reg vs_d  = 1'b0, vs_tg  = 1'b0;

    always @(posedge clk_5m or negedge rst_n) begin
        if (!rst_n) begin scl_d <= 1'b0; scl_tg <= 1'b0; end
        else begin
            scl_d <= cam_scl;
            if (cam_scl != scl_d) scl_tg <= ~scl_tg;
        end
    end

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin de_d <= 1'b0; de_tg <= 1'b0; end
        else begin
            de_d <= csi_de;
            if (csi_de != de_d) de_tg <= ~de_tg;
        end
    end

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin hs_d <= 1'b0; hs_tg <= 1'b0; end
        else begin
            hs_d <= csi_hs;
            if (csi_hs != hs_d) hs_tg <= ~hs_tg;
        end
    end

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin vs_d <= 1'b0; vs_tg <= 1'b0; end
        else begin
            vs_d <= csi_vs;
            if (csi_vs != vs_d) vs_tg <= ~vs_tg;
        end
    end

    //==========================================================
    // 2. 两个时钟的"活着吗"探针（源域自由分频 → 翻转）
    //==========================================================
    (* preserve, syn_keep = 1 *) reg [PRESCALE_BITS-1:0] byte_div = {PRESCALE_BITS{1'b0}};
    (* preserve, syn_keep = 1 *) reg                     byte_tg  = 1'b0;
    (* preserve, syn_keep = 1 *) reg [PRESCALE_BITS-1:0] pix_div  = {PRESCALE_BITS{1'b0}};
    (* preserve, syn_keep = 1 *) reg                     pix_tg   = 1'b0;

    always @(posedge clk_byte or negedge rst_n) begin
        if (!rst_n) begin byte_div <= {PRESCALE_BITS{1'b0}}; byte_tg <= 1'b0; end
        else if (byte_div == {PRESCALE_BITS{1'b1}}) begin
            byte_div <= {PRESCALE_BITS{1'b0}};
            byte_tg  <= ~byte_tg;
        end else begin
            byte_div <= byte_div + 1'b1;
        end
    end

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin pix_div <= {PRESCALE_BITS{1'b0}}; pix_tg <= 1'b0; end
        else if (pix_div == {PRESCALE_BITS{1'b1}}) begin
            pix_div <= {PRESCALE_BITS{1'b0}};
            pix_tg  <= ~pix_tg;
        end else begin
            pix_div <= pix_div + 1'b1;
        end
    end

    //==========================================================
    // 3. word_count 变化 → 翻转标志（【推断】clk_pixel 域）
    //==========================================================
    (* preserve, syn_keep = 1 *) reg [15:0] wc_d = 16'd0;
    (* preserve, syn_keep = 1 *) reg        wc_tg = 1'b0;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin wc_d <= 16'd0; wc_tg <= 1'b0; end
        else begin
            wc_d <= csi_word_count;
            if (csi_word_count != wc_d) wc_tg <= ~wc_tg;
        end
    end

    //==========================================================
    // 3b. I2C ACK 监视器（CLK_5M 域）—— task-24
    //==========================================================
    // 为什么需要：`i2c_16addr_8data.v` 不做 ACK 判断，配置序列不管 NACK 都发完 ⇒
    // 只看 SCL 计数，"传感器响应了"和"没响应"完全一样。
    //
    // 原理（标准 I2C 监视器）：
    //   · 本端口接的是 **OE**：scl_hi = ~cam_scl（OE=1 ⇒ SCL 被拉低 ⇒ 低电平）
    //   · **按 SCL 上升沿计数**（每一次上升 = 一个位的高电平开始）：
    //       第 1..8 个上升 = 8 个数据位，第 9 个上升 = ACK 槽
    //     ★ 为什么数上升沿而不是下降沿：START 之后主机会先把 SCL 拉低一次
    //       （那个下降沿**不是**数据位），按下降沿计数会整体错一位，把最后一个
    //       数据位当成 ACK。上升沿没有这个歧义。
    //   · 在第 9 个高电平**期间**（不是边沿上，避免与从器件释放 SDA 竞争）采样 SDA：
    //       低 = ACK（从器件应答），高 = NACK
    //   · START/STOP：scl_hi 为高期间 SDA 变化 ⇒ 复位位计数
    (* preserve, syn_keep = 1 *) reg        scl_hi_d = 1'b0;
    (* preserve, syn_keep = 1 *) reg        sda_d    = 1'b1;
    (* preserve, syn_keep = 1 *) reg [3:0]  i2c_bit  = 4'd0;   // 已出现的上升沿数 0..9
    (* preserve, syn_keep = 1 *) reg        ack_done = 1'b0;
    (* preserve, syn_keep = 1 *) reg        ack_tg   = 1'b0;
    (* preserve, syn_keep = 1 *) reg        nack_tg  = 1'b0;

    wire scl_hi   = ~cam_scl;              // 1 = SCL 释放（高）
    wire scl_rise = (~scl_hi_d) & scl_hi;  // 一个位的高电平开始
    wire scl_fall = scl_hi_d & (~scl_hi);  // 高电平结束

    always @(posedge clk_5m or negedge rst_n) begin
        if (!rst_n) begin
            scl_hi_d <= 1'b0;
            sda_d    <= 1'b1;
            i2c_bit  <= 4'd0;
            ack_done <= 1'b0;
            ack_tg   <= 1'b0;
            nack_tg  <= 1'b0;
        end else begin
            scl_hi_d <= scl_hi;
            sda_d    <= cam_sda;

            if (scl_rise) begin
                i2c_bit  <= (i2c_bit == 4'd9) ? 4'd9 : (i2c_bit + 4'd1);
                ack_done <= 1'b0;
            end
            // 第 9 个高电平期间采一次（高电平中间最稳）
            if (scl_hi && (i2c_bit == 4'd9) && (!ack_done)) begin
                if (!cam_sda) ack_tg  <= ~ack_tg;   // SDA 低 = 从器件应答
                else          nack_tg <= ~nack_tg;
                ack_done <= 1'b1;
            end
            if (scl_fall && (i2c_bit == 4'd9)) begin
                i2c_bit  <= 4'd0;                   // 一个字节结束，准备下一个
                ack_done <= 1'b0;
            end
            // START/STOP：SCL 高期间 SDA 变化 ⇒ 复位位计数（否则会把 START 当成数据位）
            if (scl_hi && (cam_sda != sda_d)) begin
                i2c_bit  <= 4'd0;
                ack_done <= 1'b0;
            end
        end
    end

    //==========================================================
    // 3c. 数据有效性：de && (pixel_data != 0)（clk_pixel 域）—— task-24
    //==========================================================
    // 为什么需要：`DE` 在跳**不代表数据有效**（可以是全 0 的占位行）。
    //   · pd_tg ：每 1024 拍"de && data!=0"翻转一次 ⇒ core 域计数（1 次 = 1024 拍）
    //   · pd_any：**粘滞位**，只要出现过一拍非 0 数据就置 1（最省事的"数据见过没"）
    (* preserve, syn_keep = 1 *) reg [PRESCALE_BITS-1:0] pd_div = {PRESCALE_BITS{1'b0}};
    (* preserve, syn_keep = 1 *) reg                     pd_tg  = 1'b0;
    (* preserve, syn_keep = 1 *) reg                     pd_any = 1'b0;

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            pd_div <= {PRESCALE_BITS{1'b0}};
            pd_tg  <= 1'b0;
            pd_any <= 1'b0;
        end else if (csi_de && (csi_pixel_data != 64'd0)) begin
            pd_any <= 1'b1;
            if (pd_div == {PRESCALE_BITS{1'b1}}) begin
                pd_div <= {PRESCALE_BITS{1'b0}};
                pd_tg  <= ~pd_tg;
            end else begin
                pd_div <= pd_div + 1'b1;
            end
        end
    end

    //==========================================================
    // 3d. word_count 历史最大（clk_pixel 域，准静态快照）—— task-24
    //==========================================================
    // 用来把 `wc` 的读数解释清楚："这个包最大有多少词"。
    (* preserve, syn_keep = 1 *) reg [15:0] wc_max = 16'd0;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) wc_max <= 16'd0;
        else if (csi_word_count > wc_max) wc_max <= csi_word_count;
    end

    //==========================================================
    // 4. 2FF 同步到 core_clk（只要 1 bit toggle / 准静态值）
    //==========================================================
    wire scl_tg_s, de_tg_s, hs_tg_s, vs_tg_s, byte_tg_s, pix_tg_s, wc_tg_s;
    wire scl_lvl_s, de_lvl_s, hs_lvl_s, vs_lvl_s;
    wire sda_lvl_s;
    wire [15:0] wc_now_s;
    wire [15:0] wc_max_s;
    wire [5:0]  dt_s;
    wire [1:0]  vc_s;
    wire [3:0]  ppc_s, fre_s;
    wire        irq_s;
    // task-24 追加：I2C ACK / 像素数据有效 / word_count 最大 / 复位 / HS_ENA
    wire ack_tg_s, nack_tg_s, pd_tg_s, pd_any_s;
    wire core_rstn_s, pix_rstn_s;
    wire hs_ck_s, hs_d0_s, hs_d1_s, hs_d2_s, hs_d3_s;

    mmt_sync2 #(.WIDTH(1)) u_sy_scl_tg (.clk_b(clk), .rst_n_b(rst_n), .d_a(scl_tg),   .q_b(scl_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_de_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(de_tg),    .q_b(de_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_hs_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_tg),    .q_b(hs_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_vs_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(vs_tg),    .q_b(vs_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_ck_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(byte_tg),  .q_b(byte_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_pk_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(pix_tg),   .q_b(pix_tg_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_wc_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(wc_tg),    .q_b(wc_tg_s));
    // 电平（只看"现在是不是高"）
    mmt_sync2 #(.WIDTH(1)) u_sy_scl_lv (.clk_b(clk), .rst_n_b(rst_n), .d_a(cam_scl),  .q_b(scl_lvl_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_de_lv  (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_de),   .q_b(de_lvl_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_hs_lv  (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_hs),   .q_b(hs_lvl_s));
    mmt_sync2 #(.WIDTH(1)) u_sy_vs_lv  (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_vs),   .q_b(vs_lvl_s));
    // CSI RX 准静态状态（逐位 2FF，见文件头限制 c）
    mmt_sync2 #(.WIDTH(16)) u_sy_wc_now (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_word_count),    .q_b(wc_now_s));
    mmt_sync2 #(.WIDTH(6))  u_sy_dt     (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_datatype),      .q_b(dt_s));
    mmt_sync2 #(.WIDTH(2))  u_sy_vc     (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_vc),            .q_b(vc_s));
    mmt_sync2 #(.WIDTH(4))  u_sy_ppc    (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_pixel_per_clk), .q_b(ppc_s));
    mmt_sync2 #(.WIDTH(4))  u_sy_fre    (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_fifo_rd_empty),  .q_b(fre_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_irq    (.clk_b(clk), .rst_n_b(rst_n), .d_a(csi_irq),           .q_b(irq_s));
    // ---- task-24 追加：I2C ACK / 像素数据有效 / 复位 / HS_ENA ----
    mmt_sync2 #(.WIDTH(1))  u_sy_ack    (.clk_b(clk), .rst_n_b(rst_n), .d_a(ack_tg),   .q_b(ack_tg_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_nack   (.clk_b(clk), .rst_n_b(rst_n), .d_a(nack_tg),  .q_b(nack_tg_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_pd_tg  (.clk_b(clk), .rst_n_b(rst_n), .d_a(pd_tg),    .q_b(pd_tg_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_pd_any (.clk_b(clk), .rst_n_b(rst_n), .d_a(pd_any),   .q_b(pd_any_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_sda_lv (.clk_b(clk), .rst_n_b(rst_n), .d_a(cam_sda),  .q_b(sda_lvl_s));
    mmt_sync2 #(.WIDTH(16)) u_sy_wc_max (.clk_b(clk), .rst_n_b(rst_n), .d_a(wc_max),   .q_b(wc_max_s));
    // 复位状态：core 域的 rst_n 与像素域的 pix_rstn（各 1 bit，2FF 即可）
    mmt_sync2 #(.WIDTH(1), .RESET_VAL(0)) u_sy_crst (.clk_b(clk), .rst_n_b(rst_n), .d_a(rst_n),   .q_b(core_rstn_s));
    mmt_sync2 #(.WIDTH(1), .RESET_VAL(0)) u_sy_prst (.clk_b(clk), .rst_n_b(rst_n), .d_a(pix_rstn), .q_b(pix_rstn_s));
    // HS_ENA 电平（IP 输出，准静态；只取电平+粘滞，不做计数）
    mmt_sync2 #(.WIDTH(1))  u_sy_hs_ck  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_ck_ena), .q_b(hs_ck_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_hs_d0  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_d0_ena), .q_b(hs_d0_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_hs_d1  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_d1_ena), .q_b(hs_d1_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_hs_d2  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_d2_ena), .q_b(hs_d2_s));
    mmt_sync2 #(.WIDTH(1))  u_sy_hs_d3  (.clk_b(clk), .rst_n_b(rst_n), .d_a(hs_d3_ena), .q_b(hs_d3_s));

    //==========================================================
    // 5. core_clk 域：边沿检测 + 累加
    //==========================================================
    reg scl_tg_sd = 1'b0, de_tg_sd = 1'b0, hs_tg_sd = 1'b0, vs_tg_sd = 1'b0;
    reg ck_tg_sd  = 1'b0, pk_tg_sd = 1'b0, wc_tg_sd = 1'b0;
    reg scl_seen  = 1'b0, de_seen  = 1'b0, hs_seen  = 1'b0, vs_seen  = 1'b0;
    reg ck_seen   = 1'b0, pk_seen  = 1'b0, wc_seen  = 1'b0;
    // task-24 追加
    reg ack_tg_sd = 1'b0, nack_tg_sd = 1'b0, pd_tg_sd = 1'b0;
    reg hs_ck_seen = 1'b0, hs_d0_seen = 1'b0, hs_d1_seen = 1'b0, hs_d2_seen = 1'b0, hs_d3_seen = 1'b0;

    (* preserve, syn_keep = 1 *) reg [31:0] cnt_scl  = 32'd0, cnt_ck   = 32'd0, cnt_pclk = 32'd0;
    (* preserve, syn_keep = 1 *) reg [31:0] cnt_de   = 32'd0, cnt_hs   = 32'd0;
    (* preserve, syn_keep = 1 *) reg [31:0] cnt_vs   = 32'd0, cnt_wc   = 32'd0;
    // task-24 追加：I2C ACK/NACK、像素数据有效（÷1024）
    (* preserve, syn_keep = 1 *) reg [31:0] cnt_ack  = 32'd0, cnt_nack = 32'd0, cnt_pd = 32'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_tg_sd <= 1'b0; de_tg_sd <= 1'b0; hs_tg_sd <= 1'b0; vs_tg_sd <= 1'b0;
            ck_tg_sd  <= 1'b0; pk_tg_sd <= 1'b0; wc_tg_sd <= 1'b0;
            scl_seen  <= 1'b0; de_seen  <= 1'b0; hs_seen  <= 1'b0; vs_seen  <= 1'b0;
            ck_seen   <= 1'b0; pk_seen  <= 1'b0; wc_seen  <= 1'b0;
            ack_tg_sd <= 1'b0; nack_tg_sd <= 1'b0; pd_tg_sd <= 1'b0;
            hs_ck_seen <= 1'b0; hs_d0_seen <= 1'b0; hs_d1_seen <= 1'b0;
            hs_d2_seen <= 1'b0; hs_d3_seen <= 1'b0;
            cnt_scl <= 32'd0; cnt_ck <= 32'd0; cnt_pclk <= 32'd0;
            cnt_de  <= 32'd0; cnt_hs <= 32'd0; cnt_vs   <= 32'd0; cnt_wc <= 32'd0;
            cnt_ack <= 32'd0; cnt_nack <= 32'd0; cnt_pd <= 32'd0;
        end else begin
            scl_tg_sd <= scl_tg_s;
            de_tg_sd  <= de_tg_s;
            hs_tg_sd  <= hs_tg_s;
            vs_tg_sd  <= vs_tg_s;
            ck_tg_sd  <= byte_tg_s;
            pk_tg_sd  <= pix_tg_s;
            wc_tg_sd  <= wc_tg_s;
            ack_tg_sd <= ack_tg_s;
            nack_tg_sd<= nack_tg_s;
            pd_tg_sd  <= pd_tg_s;

            if (scl_tg_s != scl_tg_sd) begin cnt_scl  <= cnt_scl  + 32'd1; scl_seen <= 1'b1; end
            if (de_tg_s  != de_tg_sd ) begin cnt_de   <= cnt_de   + 32'd1; de_seen  <= 1'b1; end
            if (hs_tg_s  != hs_tg_sd ) begin cnt_hs   <= cnt_hs   + 32'd1; hs_seen  <= 1'b1; end
            if (vs_tg_s  != vs_tg_sd ) begin cnt_vs   <= cnt_vs   + 32'd1; vs_seen  <= 1'b1; end
            if (byte_tg_s!= ck_tg_sd ) begin cnt_ck   <= cnt_ck   + 32'd1; ck_seen  <= 1'b1; end
            if (pix_tg_s != pk_tg_sd ) begin cnt_pclk <= cnt_pclk + 32'd1; pk_seen  <= 1'b1; end
            if (wc_tg_s  != wc_tg_sd ) begin cnt_wc   <= cnt_wc   + 32'd1; wc_seen  <= 1'b1; end
            if (ack_tg_s != ack_tg_sd) cnt_ack  <= cnt_ack  + 32'd1;
            if (nack_tg_s!= nack_tg_sd)cnt_nack <= cnt_nack + 32'd1;
            if (pd_tg_s  != pd_tg_sd ) cnt_pd   <= cnt_pd   + 32'd1;
            // HS_ENA 粘滞位：曾经拉起过就记住（"摄像头真的进过 HS 模式"）
            if (hs_ck_s) hs_ck_seen <= 1'b1;
            if (hs_d0_s) hs_d0_seen <= 1'b1;
            if (hs_d1_s) hs_d1_seen <= 1'b1;
            if (hs_d2_s) hs_d2_seen <= 1'b1;
            if (hs_d3_s) hs_d3_seen <= 1'b1;
        end
    end

    //==========================================================
    // 6. 寄存器读口（组合读，地址在 APB 建立相就有效）
    //==========================================================
    always @(*) begin
        case (raddr)
            // ---- 累计计数器 ----
            4'd0: rdata = cnt_scl;
            4'd1: rdata = cnt_ck;
            4'd2: rdata = cnt_pclk;
            4'd3: rdata = cnt_de;
            4'd4: rdata = cnt_hs;
            4'd5: rdata = cnt_vs;
            // ---- 状态字：电平 + 粘滞位（12+5+15 = 32 位，正好）----
            //   [0]scl [1]ck_tg [2]pclk_tg [3]de [4]hs [5]vs
            //   [6]scl_seen [7]de_seen [8]hs_seen [9]vs_seen [10]ck_seen [11]pclk_seen [12]wc_seen
            //   [13]I2C SDA 当前电平 [14]pd_any 粘滞（曾采到非 0 像素数据）
            4'd6: rdata = {12'd0, 5'd0, pd_any_s, sda_lvl_s,
                           wc_seen, pk_seen, ck_seen,
                           vs_seen, hs_seen, de_seen, scl_seen,
                           vs_lvl_s, hs_lvl_s, de_lvl_s,
                           pix_tg_s, byte_tg_s, scl_lvl_s};
            // ---- CSI RX 明文状态 + ★ 位流魔数 ----
            //   [3:0]=pixel_per_clk [7:4]=fifo_rd_empty [8]=irq [10:9]=vc [16:11]=datatype
            //   [31:17] = 15'h2A5C（读到这个才说明这版位流里有探针）
            4'd7: rdata = {15'h2A5C, dt_s, vc_s, irq_s, fre_s, ppc_s};
            // ---- word_count 值变化次数（★ 不是包数）/ 当前值 / 历史最大 ----
            4'd8:  rdata = cnt_wc;
            4'd9:  rdata = {16'd0, wc_now_s};
            4'd12: rdata = {16'd0, wc_max_s};
            // ---- ★ 探针魔数（32 位，全字匹配最不容易误判）----
            4'd10: rdata = 32'h4D4D5450;
            // ---- 数据有效性：de && pixel_data!=0 的拍数（÷1024）----
            4'd11: rdata = cnt_pd;
            // ---- I2C ACK / NACK 次数 ----
            4'd13: rdata = cnt_ack;
            4'd14: rdata = cnt_nack;
            // ---- 复位/PLL 状态 + MIPI HS_ENA 电平/粘滞位（task-24 追加）----
            //   [0]core rstn(=三个 PLL 都锁定) [1]像素域 rstn(1=已释放)
            //   [2]ck_HS_ENA 电平 [6:3]=d0..d3_HS_ENA 电平
            //   [7]ck 曾拉起 [11:8]=d0..d3 曾拉起
            //   自检：core=1 而 像素=0 在逻辑上不可能 ⇒ 读到就说明像素时钟没跑
            4'd15: rdata = {20'd0,
                            hs_d3_seen, hs_d2_seen, hs_d1_seen, hs_d0_seen, hs_ck_seen,
                            hs_d3_s,    hs_d2_s,    hs_d1_s,    hs_d0_s,    hs_ck_s,
                            pix_rstn_s, core_rstn_s};
            default: rdata = 32'h0;
        endcase
    end

endmodule
