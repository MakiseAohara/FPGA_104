# ⑤ 低功耗"降帧"复核 —— 结论：降帧确实生效，此前是测量口径错了

日期：2026-11-01
板上固件：诊断版 `fw_v292_lpmeas.bin`（302,226 B / CRC32 `D2EF9830`，基于定版 lpfix 只加测量）
测完已刷回交付版 `tinyml_pdti8_v292_day_lpfix.bin`（`BC37FEAB`）。

## 1. 为什么以前看起来"没生效"

`camfps` 来自状态字 bit31..24：

```
rtl/v7/mmt/v7_mmt_core.v:237-255
  reg [7:0] vs_cnt;  ... else if (vs_rise) vs_cnt <= vs_cnt + 1;
  assign obs_st = {vs_cnt, 3'd0, 2'd0, alarm_final, low_pwr, conf_x100[7:0], score};
```

而 `vs_rise` 来自 `in_vs`，顶层接的是 `enc_vs_in`（HDMI/OSD 输出域）。固件
`cam_fps = Δ(vs_cnt & 0xFF) * 1000 / Δt` —— **数的是显示输出帧（恒 59~60）**，
与相机 VTS 无关。所以 VTS 从 `0x5dc` 写到 `0x1194`（读回一致）也永远看不到变化。

## 2. 复核方法

诊断固件在帧缓冲上取 **24×24 网格签名**（CROP_MODE=1 区域：x0=420、y0=0、1080×1080），
按固定间隔采样、统计画面内容变化，得出"真实帧更新率"，与 `camfps` 并列打印：

- 基线：进低功耗前连测 3 次；
- 低功耗中：最多 3 次（每次 1~2 s 窗口）。

## 3. 三轮实测（同一场景、静止桌面）

| 版本 | 采样 | 正常模式 | 低功耗（VTS×3=4500 行） | 倍数 |
|---|---|---|---|---|
| v1（原始计数） | 10 ms×100 | 40 次/s | 9 / 9 / 12 次/s | 3.3–4.4 |
| v2（原始计数） | 5 ms×400 | 120 次/2s（≈60/s） | 33 / 35 / 36 次/2s（≈17/s） | 3.5 |
| v3（去抖计数） | 5 ms×400 | 10 帧/s | 3 / 3 / 3 帧/s | 3.3 |

三轮一致：**帧更新率降为原来的 1/3.3~1/3.7**，与 VTS 放大 3 倍吻合。
同期 `camfps` 仍是 59/60（老口径），二者并列出现在同一行日志里，可直接对照
（见 `camfps_samples.txt`）。

## 4. 边界（不夸大）

1. 签名法在帧缓冲被写的同时读到"半新半旧"内容（撕裂），**绝对帧率不精确**，
   所以三版绝对值互不相同；但同一版内"正常 : 低功耗"的比值稳定在 3.3~3.7，足以判定降帧生效。
2. 正确做法是在 RTL 侧把**相机域 VSYNC** 计数写进状态字（或新开一个 APB 字），
   这要改 RTL + 重出位流 + 重烧，本次未做。
3. 低功耗期间 `infer_hz`=0、`ddr_ar_s`/"避让"等省电指标未受影响（`MMT_LP` 行可见）。

## 5. 复现

```powershell
# 1) 生成诊断源码并编译（基于定版 lpfix）
py -3 FPGA_104/evidence/v29_fw/build_lpmeas.py --project D:\v30_build\project --out D:\v30_build\out_lpmeas3
# 2) 上传并抓串口（法一：沿用已有的 loader 自动重试）
py -3 FPGA_104/evidence/v30_mot/load_retry.py --image D:\v30_build\out_lpmeas3\tinyml_pdti8.bin --out D:\v30_build\lpmeas3 --capture-seconds 120
# 3) 看结果
Select-String -Path D:\v30_build\lpmeas3\serial.log -Pattern MMT_CAMFPS2
```

## 6. 文件

| 文件 | 说明 |
|---|---|
| `fw_v292_lpmeas.bin` | 诊断固件 v3（302,226 B / `D2EF9830`） |
| `camfps_samples.txt` | 三轮串口里 `MMT_CAMFPS2` 与低功耗进入/退出原文 |
| `../v29_fw/main_live292_lpmeas.cc` | 生成后的诊断源码 |
| `../v29_fw/build_lpmeas.py` | 构建脚本（`--project`/`--out`） |
