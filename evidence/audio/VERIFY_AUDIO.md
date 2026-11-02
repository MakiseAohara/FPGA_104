# HDMI 音频客观验证记录（麦克风录音 + FFT）

日期：2026-11-02
目的：⑦ 改为 HDMI 音频后，**客观**确认提示音真的从显示器喇叭出来（不只靠人耳）。

## 1. 方法

1. 刷**常响诊断位流** `v7_MERGE19_AUDIO_ON.bit`（2,830,458 B / `2B8ABD8C…AA03`，
   仅把 `audio_beep_en` 固定为 1，其余与交付版 MERGE18 相同）。该位流不需要固件、不需要串口，
   上电即持续循环三音提示。
2. 用本机声卡麦克风阵列（`麦克风阵列 (Realtek(R) Audio)`，48 kHz）录 12 s 房间音。
3. 0.5 s 窗、Hann 窗做 FFT：目标频点 ±20 Hz 内的峰值 ÷ 邻近 ±120 Hz（去掉目标带）的中位数 = 信噪比。

## 2. 结果

| 目标音 | SNR 中位 | SNR 90 分位 |
|---|---|---|
| 880.0 Hz | **34.9** | 94.8 |
| 1174.7 Hz | **25.7** | 106.9 |
| 1318.5 Hz | **36.4** | 87.9 |

判定阈值 3.0；三个音都超出 8 倍以上 → **HDMI 音频通路工作正常，提示音经显示器喇叭可闻**。

对照：此前用交付版 MERGE18（上电只响 0.9 s）录 32 s，同一算法在编程后 ~19 s 处只有 2~5 倍比值，
无法判定——短促单次提示音在房间噪声下不够，这也是改用"常响诊断位流"的原因。

## 3. 收尾

验证后已刷回交付版 `v7_MERGE18_AUDIO.bit`（2,838,420 B / `E96C05BF…FF58C`），
并重新上传定版固件 `tinyml_pdti8_v292_day_lpfix.bin`（300,938 B / `BC37FEAB`）。

## 4. 复现

```powershell
# 1) 刷常响诊断位流
powershell -File D:\v30_build\flash_vendor_utf8.ps1 -Bit D:\v30_build\m17\out\v7_MERGE19_AUDIO_ON.bit `
  -Sha256 2B8ABD8C3B002778119A888F02BDD53DB547304E0AC315092CF0EB80CE00AA03 -Force
# 2) 录音 + FFT（12 s，需要 sounddevice/numpy 的 python）
py -3 D:\v30_build\rec_analyze_on.py
# 3) 刷回交付版并重传固件
```
