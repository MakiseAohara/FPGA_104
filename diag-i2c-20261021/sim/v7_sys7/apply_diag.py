import re
core=open('sys7/v7_mmt_core.v',encoding='utf-8').read()
fmt=open('sys7/v7_txt_fmt.v',encoding='utf-8').read()

# ---- core: diagnostic logic ----
diag = '''
    //---------------- I2C 诊断（SENSE6）----------------
    reg [1:0] dg_scl_s, dg_sda_s; always @(posedge clk) begin dg_scl_s <= {dg_scl_s[0], scl_i}; dg_sda_s <= {dg_sda_s[0], sda_i}; end
    reg [8:0] dg_rel_sda, dg_rel_scl;     // 主机释放线后的稳定计数（>=256 拍 ≈1.7us，远大于上拉上升时间）
    reg scl_oe_d, dg_slv_q, dg_slv, dg_stuck, dg_crc, dg_irseen;
    reg [15:0] dg_oe_cnt, dg_slv_cnt;
    wire dg_slv_now = dg_rel_sda[8] & ~dg_sda_s[1];       // 主机已释放 SDA 却为低 = 从机在拉低（ACK/数据）
    wire dg_stk_now = dg_rel_scl[8] & ~dg_scl_s[1];       // 主机已释放 SCL 却为低 = 被外部拉住
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dg_rel_sda<=0; dg_rel_scl<=0; scl_oe_d<=0; dg_slv_q<=0; dg_slv<=0; dg_stuck<=0; dg_crc<=0; dg_irseen<=0; dg_oe_cnt<=0; dg_slv_cnt<=0; end
        else begin
            scl_oe_d <= scl_oe; dg_slv_q <= dg_slv_now;
            dg_rel_sda <= sda_oe ? 9'd0 : (dg_rel_sda[8] ? dg_rel_sda : dg_rel_sda + 1'b1);
            dg_rel_scl <= scl_oe ? 9'd0 : (dg_rel_scl[8] ? dg_rel_scl : dg_rel_scl + 1'b1);
            if (scl_oe & ~scl_oe_d & ~&dg_oe_cnt) dg_oe_cnt <= dg_oe_cnt + 1'b1;
            if (dg_slv_now & ~dg_slv_q & ~&dg_slv_cnt) dg_slv_cnt <= dg_slv_cnt + 1'b1;
            if (dg_slv_now) dg_slv <= 1'b1;
            if (dg_stk_now) dg_stuck <= 1'b1;
            if (sht_crc_err) dg_crc <= 1'b1;
            if (ir_fv) dg_irseen <= 1'b1;
        end
    end
'''
anchor = "    //---------------- OSD 文字 ----------------"
assert core.count(anchor)==1
core = core.replace(anchor, diag + "\n" + anchor)
old = ".txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd));\nendmodule"
assert core.count(old)==1
new = (".dg_scl(dg_scl_s[1]), .dg_sda(dg_sda_s[1]), .dg_slv(dg_slv), .dg_stuck(dg_stuck), .dg_sht_err(sht_bus_err), .dg_ir_err(ir_bus_err),\n"
       "        .dg_sht_seen(sht_seen), .dg_irseen(dg_irseen), .dg_crc(dg_crc), .dg_oe_cnt(dg_oe_cnt), .dg_slv_cnt(dg_slv_cnt),\n"
       "        .txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd));\nendmodule")
core = core.replace(old,new)
open('sys7/v7_mmt_core.v','w',encoding='utf-8').write(core)

# ---- fmt ----
old_in = "    output reg         txt_we,"
assert fmt.count(old_in)==1
fmt = fmt.replace(old_in, "    input  wire        dg_scl, dg_sda, dg_slv, dg_stuck, dg_sht_err, dg_ir_err, dg_sht_seen, dg_irseen, dg_crc,\n    input  wire [15:0] dg_oe_cnt, dg_slv_cnt,\n"+old_in)
helper = '''    function [7:0] hx(input [3:0] n); hx = (n < 4'd10) ? {4'h3,n} : (8'd55 + {4'h0,n}); endfunction
    function [7:0] bt(input b); bt = b ? 8'd49 : 8'd48; endfunction
'''
fmt = fmt.replace("    always @* begin\n        case (idx)", helper + "    always @* begin\n        case (idx)")
def s(i,txt): return ''.join("            8'd%d: ch = 8'd%d;\n"%(i+k,ord(c)) for k,c in enumerate(txt))
add = ''
# row0 idx 28..47 :  " SCL=x SDA=x A=x E=x"
add += s(28," SCL=")+"            8'd33: ch = bt(dg_scl);\n"+s(34," SDA=")+"            8'd39: ch = bt(dg_sda);\n"+s(40," A=")+"            8'd43: ch = bt(dg_slv);\n"+s(44," E=")+"            8'd47: ch = bt(dg_sht_err);\n"
# row1 idx 91..111 : " IE=x SV=x IV=x C=x Kx"
add += s(91," IE=")+"            8'd95: ch = bt(dg_ir_err);\n"+s(96," SV=")+"            8'd100: ch = bt(dg_sht_seen);\n"+s(101," IV=")+"            8'd105: ch = bt(dg_irseen);\n"+s(106," C=")+"            8'd109: ch = bt(dg_crc);\n"+"            8'd110: ch = 8'd75;\n            8'd111: ch = bt(dg_stuck);\n"
# row2 idx 156..169 : " O=hhhh N=hhhh"
add += s(156," O=")
for k in range(4): add += "            8'd%d: ch = hx(dg_oe_cnt[%d:%d]);\n"%(159+k,15-4*k,12-4*k)
add += s(163," N=")
for k in range(4): add += "            8'd%d: ch = hx(dg_slv_cnt[%d:%d]);\n"%(166+k,15-4*k,12-4*k)
tail = "            default: ch = 8'd32;"
assert fmt.count(tail)==1
fmt = fmt.replace(tail, add + tail)
open('sys7/v7_txt_fmt.v','w',encoding='utf-8').write(fmt)
print("ok")
