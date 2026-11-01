# ⑦ 语音播报 —— 改走 HDMI 音频（显示屏自带喇叭）

日期：2026-11-02
背景：SPI 语音模块受硬件限制暂缓；队友确认**显示器自带喇叭**，因此把提示音改从 **HDMI 音频**送出去，
不需要额外硬件、不占 J7 的 IO。

## 1. 为什么可以这么做

本设计的 HDMI 发送器是 `rtl/dvi_tx/dvi_encoder.v_encrypted.v`（Efinix 加密 IP），
它**本来就有音频端口**：

```
input [23:0] audio_L, audio_R;
input        audio_valid;
input [19:0] audio_N, audio_CTS;
input [3:0]  audio_sample_frequency;
input [3:0]  audio_word_length;
```

但原顶层 `ti60f225_oob_top.v` 里这几个信号**从未声明/驱动**（Verilog 隐式 1-bit 悬空线），
所以 HDML 输出一直没有音频数据岛 → 屏幕没声音。

## 2. 实现

新增 `rtl/v7/audio/v7_audio_tone.v`（约 160 行，纯逻辑，无 IP）：

- **48 kHz 采样节拍**：像素时钟 148.5 MHz 用整数累加计时（`tick_acc + 48000 >= 148500000`），无小数误差累积；
- **三音上行提示**：880 / 1175 / 1319 Hz，每音 0.25 s、音间静音 0.05 s，循环 0.8 s；
- **正弦表** 64 点（−32767…32767），幅度约 1/8 满量程，音符内 1023 点线性包络（防爆音）；
- **24-bit L-PCM**，左右声道同值；`enable=0` 时仍按 48 kHz 送 0 采样（HDMI 需要连续采样流）。

顶层改动（`ti60f225_oob_top.v`）：

```verilog
wire [23:0] audio_L_v, audio_R_v;
wire        audio_valid_v;
wire [3:0]  audio_samp_freq_v = 4'd5;   // IEC 60958 采样率码 0101 = 48 kHz
wire [3:0]  audio_word_len_v  = 4'd3;   // 字长码 0011 = 24 bit
v7_audio_tone u_v7_audio (.clk(hdmi_tx_slow_clk), .rst_n(vid_rst_n), .enable(audio_beep_en), ...);
assign audio_beep_en = (!audio_boot_done) | mmt_alarm_active;
```

- `audio_boot_done`：上电后约 0.9 s 的自检提示（便于确认链路），之后自动静音；
- `mmt_alarm_active`：与蜂鸣器同源，报警期间循环提示音。

`audio_N=6144`、`audio_CTS=148500` 沿用原顶层常量（48 kHz / 148.5 MHz 的标准 ACR 值）。

## 3. 构建与上板

| 项 | 结果 |
|---|---|
| 位流 | `v7_MERGE18_AUDIO.bit`，**2,838,420 B**，SHA256 `E96C05BFCF740D13A1A1ABA69743FEE63FA7A4E7FFB2002DB44495CD258FF58C` |
| 资源 | FF 21,685 / LUT 23,829 / RAM 192 / DSP 69（与 MERGE17 同量级） |
| 时序 | **setup 违例 1 条、hold 违例 7 条**，最差 hold −0.805 ns（hdmi_tx_slow_clk ↔ core_clk）。MERGE17 当年是全正；本构建树与出货树不同，未追平——**如实记录，未掩盖** |
| 烧录 | JTAG 烧录判据 PASS（Device ID `0x10660A79`），日志 `D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261102_001831.log` |
| 固件 | 定版 lpfix `tinyml_pdti8_v292_day_lpfix.bin`（300,938 B / `BC37FEAB`）上传通过 `MMT_LOAD_PASS DDR_CRC` |
| 启动 | 串口 `MMT_DEC / MMT_LP / MMT_FIXED / MMT_THUMB` 正常，说明视频链路与相机都在跑 |

**待确认**：提示音是否真的从显示器喇叭出来，必须人耳确认（本机无音频采集设备）。
若无声，按优先级尝试：`audio_samp_freq_v` 改 `4'd6`(44.1 kHz) / `4'd7`(32 kHz)；
`audio_word_len_v` 改 `4'd2`(20 bit)；或把 `audio_N/CTS` 按实际 TMDS 时钟重算。

## 4. 回退

任何异常（黑屏/花屏/闪断）立即刷回 `evidence/v29_rtl_ir_rot/v7_MERGE17.bit`
（2,845,704 B / SHA256 `3A69AAFB0E22E262E4CA7FE887CB332822772536356B596473D996BA190887CF`），
固件仍用 `BC37FEAB`。

## 5. 边界（不夸大）

1. 这是**提示音/音效**，不是自然语音；要真人声需要把 PCM 表换成语音采样（带宽 48 kHz×24 bit，
   一段 2 s 语音约 288 KB，可直接放进 BRAM/DDR 播放），本轮没做。
2. 音频是否真的出声要**人耳确认**（本机没有音频采集）。画面不受影响是必要条件，不是充分条件。
3. HDMI 音频依赖显示器的 EDID/音频能力；若屏幕不认这个采样率，可能仍然无声——届时可把
   `audio_samp_freq_v` 改成 `4'd6`（44.1 kHz）或 `4'd7`（32 kHz）再试。


## 6. 出声验证（进行中）

本机没有音频采集硬件以外的仪器，但**有声卡麦克风阵列**，故用录音做客观验证：

1. 办法 A（人耳，最快）：当前板子跑的就是 `MERGE18_AUDIO` 位流——**断电再上电**，
   约 1 s 后应听到三音上行提示（880→1175→1319 Hz，循环 0.8 s，共约 0.9 s）。
2. 办法 B（麦克风）：刷位流时录了 32 s 房间音（`rec_audio.wav`）。分析显示
   编程结束后的第 ~19 s 处在 880–1319 Hz 有能量峰（相对邻近背景 2–5 倍），
   但**房间噪声太大、比值不足以下结论**——按"证据不足"处理，不作为"已出声"的证明。
3. 办法 C（客观，已启动）：另编一版**常响诊断位流** `MERGE19_AUDIO_ON`
   （`audio_beep_en = 1'b1`，不需要固件、不需要串口），录音后做长时 FFT 求三音信噪比。
   该版本只用于验证，正式交付仍用 `MERGE18_AUDIO`。

串口已拔、固件无法上传，因此依赖固件的报警触发音暂时不测；上电自检音与常响诊断位流不受影响。

## 7. 常响诊断位流（已编好，未验证）

| 项 | 值 |
|---|---|
| 文件 | `v7_MERGE19_AUDIO_ON.bit`（本地 `D:\v30_build\m17\out\`） |
| 大小 / SHA256 | 2,830,458 B / `2B8ABD8C3B002778119A888F02BDD53DB547304E0AC315092CF0EB80CE00AA03` |
| 差异 | 仅把 `audio_beep_en` 固定为 1（持续三音循环），其余与 MERGE18 相同 |
| 用途 | 无固件、无串口时也能客观验证 HDMI 音频通路（录音 → FFT 求三音信噪比） |
| 状态 | **未验证**：刷写时报 `No USB target detected`——板卡的 FT4232H（供电+JTAG+UART 一体）已拔掉，板子断电 |

恢复供电后即可验证：刷 MERGE19 → 录 12 s → `D:\v30_build\rec_analyze_on.py`（信噪比 > 3 判为出声）。
验证完请刷回 `MERGE18_AUDIO`（正常版）。
