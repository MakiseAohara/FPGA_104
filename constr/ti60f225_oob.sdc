# PLL Constraints
#################
# PLL Constraints
#################
create_clock -period 10.0000 axi_clk
create_clock -period 10.0000 core_clk
create_clock -period 10.0000 i_soc_clk
create_clock -period 2.5000 tx_cal_clk_90edge
create_clock -period 2.5000 sdram_clk
create_clock -period 2.5000 rx_cal_clk
create_clock -period 2.5000 tx_cal_clk
create_clock -period 10.0000 clk_100m
create_clock -waveform {0.7500 1.7500} -period 2.0000 i_mipi_txc_sclk
create_clock -waveform {0.2500 1.2500} -period 2.0000 i_mipi_txd_sclk
create_clock -period 8.0000 i_mipi_tx_pclk

create_clock -period 14.2857 vid_clk_dvi2
create_clock -period 200.0000 CLK_5M
create_clock -period 20.0000 fb
create_clock -period 10.0000 pll_inst4_CLKOUT0
create_clock -period 20.0000 i_mipi_rx_pclk
create_clock -period 7.1429 hdmi_tx_slow_clk
create_clock -waveform {0.3571 1.0714} -period 1.4286 hdmi_tx_fast_clk

set_clock_groups -exclusive  -group {i_soc_clk} -group {i_mipi_rx_pclk} -group {jtag_inst1_TCK}
set_clock_groups -exclusive -group {core_clk} -group {axi_clk} -group {tx_cal_clk} -group {i_mipi_tx_pclk} -group {vid_clk_dvi2 hdmi_tx_slow_clk} -group {CLK_5M} -group {i_mipi_rx_pclk} -group {sdram_clk} -group {rx_cal_clk} -group {i_cam_ck_CLKOUT} -group {jtag_inst1_TCK}
set_clock_groups -exclusive -group {i_mipi_tx_pclk}    -group {i_mipi_rx_pclk}

# ---------------------------------------------------------------------------
# [2026-10-11 时序/CDC 分析补充]  —— 分析见 docs/时序与CDC问题分析.md
# core_clk            : MIPI_TX_PLL 输出 (mmt.peri.xml:354)
# hdmi_tx_slow_clk    : USER_PLL   输出 (mmt.peri.xml:341)
# 二者来自两个不同的 PLL 实例，相位关系不可分析；上面第 26 行的 exclusive 组里漏了
# hdmi_tx_slow_clk。不声明异步时，STA 会把两者当成有确定相位关系的同步时钟，算出
# 0.001 ns 的约束，于是两域之间全部 CDC 通路（终点均为 mmt_sync2 的第一级触发器 s1）
# 被报成假违规（WNS -3.589 ns）。这里补上异步声明。
# [2026-10-11 二次修订] 这里原来写的是一条独立声明：
#     set_clock_groups -asynchronous -group {core_clk} -group {hdmi_tx_slow_clk}
# 实测它虽只点名两个组，却**顺带把同源 USER_PLL 的真实 2:1 同步路径
#     vid_clk_dvi2 ↔ hdmi_tx_slow_clk
# 也切断了**（时钟关系数 16→13；被切的是 mmt_top.v 里 48 位像素采样通路与
# dvi_encoder 复位，分析见 docs/跨域与报警链路复审.md）。
# 现改为把 hdmi_tx_slow_clk 并进上面第 26 行那个 exclusive 组、与 vid_clk_dvi2 **同组**：
#   · 同组内两条时钟仍按同步关系互相计时 —— 正是我们要保留的真实 2:1 路径；
#   · 与 core_clk 等其它组之间依然是异步 —— CDC 假违规照旧被消除（WNS -3.589ns 的修法不变）。
# 验收：重跑后 Setup 时钟关系表应恢复出现 "vid_clk_dvi2 vs hdmi_tx_slow_clk"（+3.7ns 量级），
#       且 core_clk ↔ hdmi_tx_slow_clk 不再被检查、负 slack 仍为 0。

#set_clock_groups -exclusive -group {i_sysclk} -group {jtag_inst1_TCK}                       2.500           -0.197           (R-R)

#set_clock_groups -exclusive -group {i_sysclk_div_2} -group {jtag_inst1_TCK}

#set_clock_groups -exclusive -group {jtag_inst1_TCK} -group {i_hbramClk_fb i_hbramClk_cal i_hbramClk_cal i_hbramClk90} -group {io_systemClk} -group {i_mipi_rx_pclk} -group {i_mipi_tx_pclk i_mipi_clk i_mipi_txc_sclk i_mipi_txd_sclk}

# GPIO Constraints
####################
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {i_arstn}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {i_arstn}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {system_uart_0_io_rxd}]
# set_input_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {system_uart_0_io_rxd}]
# ---------------------------------------------------------------------------
# [2026-10-13 task-25 修正] 原来这 5 组约束同时有两处错误 ⇒ 完全没生效：
#   ① -clock i_soc_clk 在本工程不存在（mmt_top.v:72 该端口已注释掉；:549 的
#      "assign i_soc_clk = core_clk" 只是一根别名线网，综合后无此对象）
#      → efx_pnr.log:81-128 实测报 "No clocks matched 'i_soc_clk'"；
#   ② 端口名不存在：o_cam_rstn[0] / i_cam_scl[0] / o_cam_scl_oe[0] / i_cam_sda[0] /
#      o_cam_sda_oe[0]。本工程真实端口是 o_cam_rst_p / io_cam_scl_IN / io_cam_scl_OE /
#      io_cam_sda_IN / io_cam_sda_OE（mmt_top.v:82-90）。
#   域判定：摄像头 I2C 主机 u2_i2c_master_ctrl_top 跑在 CLK_5M（mmt_top.v:668），
#   OE 由 scl_padoen_o 组合产生（mmt_top.v:679）⇒ 用 -clock CLK_5M；
#   o_cam_rst_p = ~w_arstn（mmt_top.v:678）是纯组合无时钟域信号，按 CLK_5M 记录。
#   注：延用原延时数值（Interface Designer 按本板布线算出），换时钟后更容易满足。
set_output_delay -clock CLK_5M -max 0.091 [get_ports {o_cam_rst_p}]
set_output_delay -clock CLK_5M -min -0.045 [get_ports {o_cam_rst_p}]
set_input_delay  -clock CLK_5M -max 0.795 [get_ports {io_cam_scl_IN}]
set_input_delay  -clock CLK_5M -min 0.461 [get_ports {io_cam_scl_IN}]
set_output_delay -clock CLK_5M -max 0.070 [get_ports {io_cam_scl_OE}]
set_output_delay -clock CLK_5M -min -0.026 [get_ports {io_cam_scl_OE}]
set_input_delay  -clock CLK_5M -max 0.795 [get_ports {io_cam_sda_IN}]
set_input_delay  -clock CLK_5M -min 0.461 [get_ports {io_cam_sda_IN}]
set_output_delay -clock CLK_5M -max 0.070 [get_ports {io_cam_sda_OE}]
set_output_delay -clock CLK_5M -min -0.026 [get_ports {io_cam_sda_OE}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {system_uart_0_io_txd}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {system_uart_0_io_txd}]

# JTAG Constraints
####################
# ---------------------------------------------------------------------------
# [2026-10-13 task-25 修正] jtag_inst1_TCK 原来只有注释掉的模板行，没有真正建时钟
#   ⇒ SoC 的 JTAG TAP 域（真实接口，见 rtl\mmt\mmt_top.v:229-236、:1521-1527）
#   完全没有时序检查，下面 12 条 JTAG I/O 约束也全部报
#   "No clocks matched 'jtag_inst1_TCK'"（efx_pnr.log:129-162）而失效。
#   取值 100.0000 ns（10MHz）对齐厂商 Ti60F225 官方工程
#   tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\edge_vision_soc.sdc:26。
#   时钟关系已在上面第 26 行把它并为一个 exclusive 组（只建时钟不并组会像
#   2026-10-11 的 core_clk↔hdmi_tx_slow_clk 那样被算出"近零约束"的假关系）。
#   ⚠️ 本条会让 12 条 JTAG I/O 约束首次生效（100ns 域，几乎不可能违例）。
create_clock -period 100.0000 [get_ports {jtag_inst1_TCK}]
set_output_delay -clock jtag_inst1_TCK -max 0.134 [get_ports {jtag_inst1_TDO}]
set_output_delay -clock jtag_inst1_TCK -min -0.075 [get_ports {jtag_inst1_TDO}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_CAPTURE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_RESET}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_RESET}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.279 [get_ports {jtag_inst1_SEL}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.162 [get_ports {jtag_inst1_SEL}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_UPDATE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_UPDATE}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.388 [get_ports {jtag_inst1_SHIFT}]
set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.225 [get_ports {jtag_inst1_SHIFT}]
# JTAG Constraints (extra... not used by current Efinity debug tools)
# create_clock -period <USER_PERIOD> [get_ports {jtag_inst1_DRCK}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -max 0.322 [get_ports {jtag_inst1_RUNTEST}]
# set_input_delay -clock_fall -clock jtag_inst1_TCK -min 0.187 [get_ports {jtag_inst1_RUNTEST}]
# Create separate clock groups for JTAG clocks. Remove DRCK clock from the list below if it is not defined.
# set_clock_groups -asynchronous -group {jtag_inst1_TCK jtag_inst1_DRCK}

# HSIO GPIO Constraints
#########################
create_clock -period <USER_PERIOD> [get_ports {CLK_25M}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -max 0.302 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~95}] -min -0.140 [get_ports {ddr_addr[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -max 0.302 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~36}] -min -0.140 [get_ports {ddr_addr[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -max 0.302 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~70}] -min -0.140 [get_ports {ddr_addr[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -max 0.302 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~50~1}] -min -0.140 [get_ports {ddr_addr[3]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -max 0.302 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~25}] -min -0.140 [get_ports {ddr_addr[4]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -max 0.302 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~142~1}] -min -0.140 [get_ports {ddr_addr[5]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -max 0.302 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~59}] -min -0.140 [get_ports {ddr_addr[6]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -max 0.302 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~110}] -min -0.140 [get_ports {ddr_addr[7]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -max 0.302 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~26}] -min -0.140 [get_ports {ddr_addr[8]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -max 0.302 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~127}] -min -0.140 [get_ports {ddr_addr[9]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -max 0.302 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~138}] -min -0.140 [get_ports {ddr_addr[10]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -max 0.302 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~60}] -min -0.140 [get_ports {ddr_addr[11]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -max 0.302 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~35}] -min -0.140 [get_ports {ddr_addr[12]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -max 0.302 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~71}] -min -0.140 [get_ports {ddr_addr[13]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -max 0.302 [get_ports {ddr_addr[14]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~109}] -min -0.140 [get_ports {ddr_addr[14]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -max 0.302 [get_ports {ddr_addr[15]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~143~1}] -min -0.140 [get_ports {ddr_addr[15]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -max 0.302 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~74~1}] -min -0.140 [get_ports {ddr_ba[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -max 0.302 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~132~1}] -min -0.140 [get_ports {ddr_ba[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -max 0.302 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~126}] -min -0.140 [get_ports {ddr_ba[2]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -max 0.302 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~49}] -min -0.140 [get_ports {ddr_cas_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -max 0.302 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~149}] -min -0.140 [get_ports {ddr_ck_lo ddr_ck_hi}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -max 0.302 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~123~1}] -min -0.140 [get_ports {ddr_cke[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -max 0.302 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~95~1}] -min -0.140 [get_ports {ddr_cs_n[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -max 0.302 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~131~1}] -min -0.140 [get_ports {ddr_dm_lo[0] ddr_dm_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -max 0.302 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~83~1}] -min -0.140 [get_ports {ddr_dm_lo[1] ddr_dm_hi[1]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -max 0.302 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~73~1}] -min -0.140 [get_ports {ddr_odt[0]}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -max 0.302 [get_ports {ddr_ras_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~48}] -min -0.140 [get_ports {ddr_ras_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -max <MAX CALCULATION> [get_ports {ddr_reset_n}]
# set_output_delay -clock <CLOCK> [-reference_pin <clkout_pad>] -min <MIN CALCULATION> [get_ports {ddr_reset_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -max 0.302 [get_ports {ddr_we_n}]
set_output_delay -clock sdram_clk -reference_pin [get_ports {sdram_clk~CLKOUT~218~94}] -min -0.140 [get_ports {ddr_we_n}]
# [2026-10-11 修订] 原来这两对约束写的是 -clock i_soc_clk / -reference_pin
#   [get_ports {i_soc_clk~CLKOUT~1~31}] 和 {i_soc_clk~CLKOUT~1~30} —— 本工程的
#   SoC 时钟就是 core_clk（mmt_top.v 里 assign i_soc_clk = core_clk），
#   i_soc_clk 不是端口、也没有 CLKOUT 引脚，整条约束其实是空操作，
#   SPI 输出路径完全没被 STA 约束。改用真实时钟 core_clk（去掉 reference_pin）。
set_output_delay -clock core_clk -max 0.302 [get_ports {system_spi_0_io_sclk_write}]
set_output_delay -clock core_clk -min -0.140 [get_ports {system_spi_0_io_sclk_write}]
set_output_delay -clock core_clk -max 0.302 [get_ports {system_spi_0_io_ss}]
set_output_delay -clock core_clk -min -0.140 [get_ports {system_spi_0_io_ss}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -max 0.476 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~148~1}] -min 0.276 [get_ports {ddr_dq_in_lo[0] ddr_dq_in_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_out_lo[0] ddr_dq_out_hi[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -max 0.302 [get_ports {ddr_dq_oe[0]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~150~1}] -min -0.140 [get_ports {ddr_dq_oe[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -max 0.476 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~157~1}] -min 0.276 [get_ports {ddr_dq_in_lo[1] ddr_dq_in_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_out_lo[1] ddr_dq_out_hi[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -max 0.302 [get_ports {ddr_dq_oe[1]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~159~1}] -min -0.140 [get_ports {ddr_dq_oe[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -max 0.476 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~164~1}] -min 0.276 [get_ports {ddr_dq_in_lo[2] ddr_dq_in_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_out_lo[2] ddr_dq_out_hi[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -max 0.302 [get_ports {ddr_dq_oe[2]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~166~1}] -min -0.140 [get_ports {ddr_dq_oe[2]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -max 0.476 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~149~1}] -min 0.276 [get_ports {ddr_dq_in_lo[3] ddr_dq_in_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_out_lo[3] ddr_dq_out_hi[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -max 0.302 [get_ports {ddr_dq_oe[3]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~151~1}] -min -0.140 [get_ports {ddr_dq_oe[3]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -max 0.476 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~189~1}] -min 0.276 [get_ports {ddr_dq_in_lo[4] ddr_dq_in_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_out_lo[4] ddr_dq_out_hi[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -max 0.302 [get_ports {ddr_dq_oe[4]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~191~1}] -min -0.140 [get_ports {ddr_dq_oe[4]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -max 0.476 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~156~1}] -min 0.276 [get_ports {ddr_dq_in_lo[5] ddr_dq_in_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_out_lo[5] ddr_dq_out_hi[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -max 0.302 [get_ports {ddr_dq_oe[5]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~158~1}] -min -0.140 [get_ports {ddr_dq_oe[5]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -max 0.476 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~165~1}] -min 0.276 [get_ports {ddr_dq_in_lo[6] ddr_dq_in_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_out_lo[6] ddr_dq_out_hi[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -max 0.302 [get_ports {ddr_dq_oe[6]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~167~1}] -min -0.140 [get_ports {ddr_dq_oe[6]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -max 0.476 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~188~1}] -min 0.276 [get_ports {ddr_dq_in_lo[7] ddr_dq_in_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_out_lo[7] ddr_dq_out_hi[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -max 0.302 [get_ports {ddr_dq_oe[7]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~190~1}] -min -0.140 [get_ports {ddr_dq_oe[7]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -max 0.476 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~82~1}] -min 0.276 [get_ports {ddr_dq_in_lo[8] ddr_dq_in_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_out_lo[8] ddr_dq_out_hi[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -max 0.302 [get_ports {ddr_dq_oe[8]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~84~1}] -min -0.140 [get_ports {ddr_dq_oe[8]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -max 0.476 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~39~1}] -min 0.276 [get_ports {ddr_dq_in_lo[9] ddr_dq_in_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_out_lo[9] ddr_dq_out_hi[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -max 0.302 [get_ports {ddr_dq_oe[9]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~41~1}] -min -0.140 [get_ports {ddr_dq_oe[9]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -max 0.476 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~22~1}] -min 0.276 [get_ports {ddr_dq_in_lo[10] ddr_dq_in_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_out_lo[10] ddr_dq_out_hi[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -max 0.302 [get_ports {ddr_dq_oe[10]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~24~1}] -min -0.140 [get_ports {ddr_dq_oe[10]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -max 0.476 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~92~1}] -min 0.276 [get_ports {ddr_dq_in_lo[11] ddr_dq_in_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_out_lo[11] ddr_dq_out_hi[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -max 0.302 [get_ports {ddr_dq_oe[11]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~94~1}] -min -0.140 [get_ports {ddr_dq_oe[11]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -max 0.476 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~23~1}] -min 0.276 [get_ports {ddr_dq_in_lo[12] ddr_dq_in_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_out_lo[12] ddr_dq_out_hi[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -max 0.302 [get_ports {ddr_dq_oe[12]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~25~1}] -min -0.140 [get_ports {ddr_dq_oe[12]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -max 0.476 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~38~1}] -min 0.276 [get_ports {ddr_dq_in_lo[13] ddr_dq_in_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_out_lo[13] ddr_dq_out_hi[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -max 0.302 [get_ports {ddr_dq_oe[13]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~40~1}] -min -0.140 [get_ports {ddr_dq_oe[13]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -max 0.476 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~11~1}] -min 0.276 [get_ports {ddr_dq_in_lo[14] ddr_dq_in_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_out_lo[14] ddr_dq_out_hi[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -max 0.302 [get_ports {ddr_dq_oe[14]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~13~1}] -min -0.140 [get_ports {ddr_dq_oe[14]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -max 0.476 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~12~1}] -min 0.276 [get_ports {ddr_dq_in_lo[15] ddr_dq_in_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_out_lo[15] ddr_dq_out_hi[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -max 0.302 [get_ports {ddr_dq_oe[15]}]
set_output_delay -clock tx_cal_clk_90edge -reference_pin [get_ports {tx_cal_clk_90edge~CLKOUT~14~1}] -min -0.140 [get_ports {ddr_dq_oe[15]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~172~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[0] ddr_dqs_in_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[0] ddr_dqs_out_hi[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -max 0.302 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~174~1}] -min -0.140 [get_ports {ddr_dqs_oe[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[0]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~175~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[0]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -max 0.476 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_input_delay -clock rx_cal_clk -reference_pin [get_ports {rx_cal_clk~CLKOUT~30~1}] -min 0.276 [get_ports {ddr_dqs_in_lo[1] ddr_dqs_in_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_out_lo[1] ddr_dqs_out_hi[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -max 0.302 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~32~1}] -min -0.140 [get_ports {ddr_dqs_oe[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -max 0.302 [get_ports {ddr_dqs_oe_n[1]}]
set_output_delay -clock tx_cal_clk -reference_pin [get_ports {tx_cal_clk~CLKOUT~33~1}] -min -0.140 [get_ports {ddr_dqs_oe_n[1]}]

# MIPI RX Lane Constraints
############################
# ---------------------------------------------------------------------------
# [2026-10-13 task-25 修正] ★ 这是本工程最严重的一条漏约束 ★
#   原来 create_clock 被注释掉 ⇒ MIPI RX 的字节时钟域**完全没有时钟**：
#   · i_cam_ck_CLKOUT 是真实的时钟网络（outflow/mmt.interface.csv:29-32 的 4 条
#     clkout 记录；pinout.csv:66/81 落在 MIPI_GCLK 脚 cam_ck.N/P）；
#   · 它驱动 CSI RX 的 clk_byte_HS（mmt_top.v:564）与摄像头上游探针
#     mmt_cam_probe.clk_byte（mmt_top.v:1479）；该 IP 共 570 个 FF（mmt.hier_util.rpt:54）。
#   · 没有 create_clock ⇒ 这些 FF 既不被计时、也无时钟关系；同时下面 32 条
#     MIPI RX lane 的 set_input_delay/set_output_delay 全部报
#     "No clocks matched 'i_cam_ck_CLKOUT'"（efx_pnr.log:282-313 行警告）而失效。
#   取值 12.000 ns（83.3MHz）依据：本行原本就写着 12.000（厂商 Ti60F225 OOB
#   ti60f225_oob.sdc:256 同值），且本工程摄像头 I2C 寄存器表与厂商
#   Ti60f225_sc431hai2hdmi_v1 逐字节相同（i2c_master_reg_rom.v，MD5 一致）
#   ⇒ 同一摄像头模式、同一 byte clock。若实测字节时钟不是 83.3MHz，改这一行即可。
#   时钟关系已在上面第 26 行把它并为一个 exclusive 组（厂商 Ti60F225 TinyML demo
#   edge_vision_soc.sdc:29 就是这样处理的）。
#   ⚠️ 本条会让时序报告变紧：字节域内部路径 + 32 条 RX lane I/O 约束从此生效。
create_clock -period 12.000 [get_ports {i_cam_ck_CLKOUT}]
# [2026-10-13 task-25 修正] d0/d1 下面这些名字原是 o_cam_d0_*/i_cam_d0_* 带 i_/o_ 前缀，
#   本工程（以及厂商 rtl\ti60f225_oob_top.v:76-83）里的真实端口是 cam_d0_* / cam_d1_*，
#   不带前缀 ⇒ 原 16 条约束全部 "No valid output port(s) found" 而失效。
#   d2/d3 本来就是正确写法（可对照），说明这一段是从别的工程（EVSoC Ti60F225_dsi，
#   edge_vision_soc.sdc:272-279）拷过来的、只改了一半。下面是改正后的名字。
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.604 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.070 [get_ports {cam_d0_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.362 [get_ports {cam_d0_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min -0.140 [get_ports {cam_d0_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.725 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.420 [get_ports {cam_d0_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -max 0.560 [get_ports {cam_d0_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~82~322}] -min 0.325 [get_ports {cam_d0_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.604 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.070 [get_ports {cam_d1_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.362 [get_ports {cam_d1_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min -0.140 [get_ports {cam_d1_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.725 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.420 [get_ports {cam_d1_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -max 0.560 [get_ports {cam_d1_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~130~322}] -min 0.325 [get_ports {cam_d1_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.604 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.070 [get_ports {cam_d2_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.362 [get_ports {cam_d2_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min -0.140 [get_ports {cam_d2_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.725 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.420 [get_ports {cam_d2_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -max 0.560 [get_ports {cam_d2_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~73~322}] -min 0.325 [get_ports {cam_d2_HS_IN[*]}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.604 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.070 [get_ports {cam_d3_FIFO_RD}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.362 [get_ports {cam_d3_RST}]
set_output_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min -0.140 [get_ports {cam_d3_RST}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.725 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.420 [get_ports {cam_d3_FIFO_EMPTY}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -max 0.560 [get_ports {cam_d3_HS_IN[*]}]
set_input_delay -clock i_cam_ck_CLKOUT -reference_pin [get_ports {i_cam_ck_CLKOUT~CLKOUT~141~322}] -min 0.325 [get_ports {cam_d3_HS_IN[*]}]

# MIPI TX Lane Constraints
############################
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~39~322}] -max 0.435 [get_ports {mipi_dp_clk_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~39~322}] -min -0.140 [get_ports {mipi_dp_clk_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~39~322}] -max 0.362 [get_ports {mipi_dp_clk_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~39~322}] -min -0.140 [get_ports {mipi_dp_clk_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -max 0.435 [get_ports {mipi_dp_data0_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -min -0.140 [get_ports {mipi_dp_data0_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -max 0.362 [get_ports {mipi_dp_data0_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~63~322}] -min -0.140 [get_ports {mipi_dp_data0_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -max 0.435 [get_ports {mipi_dp_data1_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -min -0.140 [get_ports {mipi_dp_data1_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -max 0.362 [get_ports {mipi_dp_data1_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~71~322}] -min -0.140 [get_ports {mipi_dp_data1_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -max 0.435 [get_ports {mipi_dp_data2_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -min -0.140 [get_ports {mipi_dp_data2_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -max 0.362 [get_ports {mipi_dp_data2_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~55~322}] -min -0.140 [get_ports {mipi_dp_data2_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -max 0.435 [get_ports {mipi_dp_data3_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -min -0.140 [get_ports {mipi_dp_data3_HS_OUT[*]}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -max 0.362 [get_ports {mipi_dp_data3_RST}]
set_output_delay -clock i_mipi_tx_pclk -reference_pin [get_ports {i_mipi_tx_pclk~CLKOUT~31~322}] -min -0.140 [get_ports {mipi_dp_data3_RST}]


# LVDS Tx Constraints
#######################
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.435 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.140 [get_ports {tmds_tx_clk_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.435 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.140 [get_ports {tmds_tx_data0_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.435 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.140 [get_ports {tmds_tx_data1_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_DATA[*]}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.435 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.140 [get_ports {tmds_tx_data2_TX_OE}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -max 0.483 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~175}] -min -0.175 [get_ports {tmds_tx_clk_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -max 0.483 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~215}] -min -0.175 [get_ports {tmds_tx_data0_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -max 0.483 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~187}] -min -0.175 [get_ports {tmds_tx_data1_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -max 0.483 [get_ports {tmds_tx_data2_TX_RST}]
set_output_delay -clock hdmi_tx_slow_clk -reference_pin [get_ports {hdmi_tx_slow_clk~CLKOUT~218~200}] -min -0.175 [get_ports {tmds_tx_data2_TX_RST}]
