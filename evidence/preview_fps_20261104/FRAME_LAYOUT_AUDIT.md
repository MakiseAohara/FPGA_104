# 网页画面左右拼接：DDR 地址审计

本次只读核对实际 netfix04_rxq2 源和既有综合日志；测试使用独立合成行/列标记。未改 RTL、未操作板卡。

## 明确的地址错误

`main_live30.cc:161-164,1677` 旧值：`FB_BASE=0x01000000`，`FB_FRAME_LEN=960*1080*4+0x200=4147712 (0x3F4A00)`，`LIVE_BANK=2`，所以取像基址为 **0x017E9400**。

实际位流使用 `rtl/frame_buffer_V4/`，由 `ti60f225_oob.xml:78-90` 确认。顶层 `rtl/ti60f225_oob_top.v:652-665` 的 frame_buffer 确实传 `MAX_VID_WIDTH=960`、`I_VID_WIDTH=32`；但 `frame_buffer.v:168-179` 实例化 ddr_buffer 时**未向下传 MAX_VID_WIDTH / MAX_VID_HIGHT / FB_NUM**。

因此 ddr_buffer 和 bank_switch 继承默认宽1920、高1080、三bank，实际保留容量为 `1920*1080*32/8+0x200=8294912 (0x7E9200)` 字节。`ddr_buffer.v:215-222` 将这些默认值继续传给 bank_switch，`bank_switch.v:37` 使用此公式。

这不是仅从源码猜测：已编译该位流的 `D:/FPGA/netfix04/evidence/network_20261104/builds/netfix04_rxq2/1-map.log` 给出：

- L474：frame_buffer override含 `MAX_VID_WIDTH=960`；
- L486：ddr_buffer override仅AXI参数、START_ADDR、BURST_LEN、I_VID_WIDTH=32，**不含 MAX_VID_WIDTH**；
- L509：bank_switch override含FB_NUM=3、VID_DATA_WIDTH=32，同样**不含 MAX_VID_WIDTH**。

三个真实bank地址：

| Bank | 实际起点 |
|---|---|
| 0 | 0x01000000 |
| 1 | **0x017E9200** |
| 2 | 0x01FD2400 |

旧固件所称“bank2”的取像点实际落在**真实bank1 + 512字节**，并非任何bank起点。

## 为什么是左右接缝

真实图像每行仍为1920个uint8 Bayer像素；一拍4像素、32位打包，HDMI读侧960拍×16位=1920字节。bank保留容量和像素行跨度是两个不同概念，**不能把 FB_ROW_BYTES 改成3840或7680**。

旧取像从每行x=512开始读：先读本行x=512..1919的1408字节，再把下一行x=0..511的512字节接在右边。固定接缝位于画面宽度的 `1408/1920=73.33%`；在96像素预览约为x=70.4。此结构会形成左右滚动、拼接感，且最后一行后半会落到未定义帧尾区域。

`test_frame_layout.py` 在每4字节存储真实横向cell号与行号，逐行核验完整1080行，而不是只比较常量：旧取像1080行全部不符；新取像1080行全部一致。第31行的旧图x=1404仍为本行最后cell479，x=1408已变成下一行cell0，证明跨行接缝。

## 最小软件修复

随附 `evidence/v30_mot/frame_layout.h` 使用真实bank容量与独立1920字节行距。选择真实bank1（0x017E9200）继续取像，保留相同物理bank，仅消除512字节误偏移。不要直接修下层RTL参数，因为这会改变HDMI三缓冲地址布局，需要另做完整位流回归。

## 尚未解决的时间一致性

三个bank动态轮换，固定读bank1仍可能在读像素期间被摄像头覆盖。当前APB没有公开已完成bank号，也没有软核读锁；不能保证某张96×96采样来自同一个相机曝光帧。此风险可能造成时变撕裂，但与本次明确的固定512字节错位是两件事。

理想后续是在RTL提供带序号的已完成bank快照和读锁/释放握手，或专用降采样双缓冲，软核只读一次锁定的bank。仅在采样前后读同一bank号仍不充分，因为60Hz相机在较慢采样期间可能绕过完整3bank周期。

PC现役主链使用板内HTTP的原始96×96 PNG，所以本次固定错位在编码/网络前已存在；修UDP实时ID分片本身不会修正这一地址错误。UDP LIVE_ID分片确实没有按帧时间戳分组的潜在混帧问题，应另行加固，但不能作为当前HTTP画面拼图的首因。
