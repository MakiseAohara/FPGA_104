# 白平衡（偏紫）根因调查：增益写了却从没生效，且 R/B 接反

日期：2026-11-02
现象：画面偏紫（只有摄像头画面偏，OSD 文字正常）；用户给定 R=0x158 / G=0x118 / B=0x1A4 也没变化。

## 1. 根因（两处，都在 RTL）

### 1.1 固件写的白平衡寄存器**根本没有译码**

固件 `wb_initialize()` 写的是 APB 字 19/20/21：

```c
#define APB_WB_R      R32(19)
#define APB_WB_G      R32(20)
#define APB_WB_B      R32(21)
```

而顶层 `ti60f225_oob_top.v` 的 APB 读译码只覆盖 0..13、16..18（第 920-941 行），
写译码只处理字 14/15/16 —— **19/20/21 没有任何模块接收**，写进去等于写到空气；
读回来恒 0。所以任何"调白平衡"的固件改动都不会改变画面。

### 1.2 彩色增益实际来自调试 VIO，且 R/B 在 debayer 里接反

真正驱动彩色增益的是 `debayer_top_2to1` 的 `rgb_gain_v1`，其输入接的是
`debug_edb_top` 的 VIO：

```verilog
debayer_top_2to1 debayer_top (
   .r_gain (|r_gain? r_gain:255 ),   // r_gain 来自 vio0_r_gain
   ...
);

// rtl/debayer/debayer_top_2to1.v 内部：
   .gain_b (r_gain),   // ← 应为 b_gain
   .gain_g (g_gain),
   .gain_r (b_gain),   // ← 应为 r_gain
```

- VIO 在**没有调试器连着的普通上电**时保持 0 → 三个通道都走 255 兜底 **= 完全不做白平衡**；
- 即使 VIO 有值，R/B 增益也是**互换**的（R 拿 B 的增益、B 拿 R 的增益）。

这两条合起来解释了：11/1 早上画面正常（当时要么光源不同、要么调试会话里 VIO 有值），
之后无论怎么调固件参数都不变紫。

## 2. 修复（RTL，已改，位流构建中）

1. 顶层增加 APB 字 19/20/21 的写译码 → `wb_r_q/wb_g_q/wb_b_q`，**默认 344/280/420**
   （与固件宏一致，Q8：344/256 = 1.344x）；
2. 彩色增益改为：`VIO 非零 → 用 VIO（现场调试）`，否则用 APB 白平衡寄存器；
3. `debayer_top_2to1.v` 里 `.gain_b(r_gain)/.gain_r(b_gain)` 改为 `.gain_b(b_gain)/.gain_r(r_gain)`。

改完先跑 `efx_map` 确认综合通过（退出码 0），再走完整 5 步流程出位流。

### 2.1 位流

| 项 | 值 |
|---|---|
| 文件 | `v7_MERGE21_WB.bit`（`D:\v30_build\m17\out\`） |
| 大小 / SHA256 | **2,806,104 B / `D165EDCA7A2272CB1AE682966BC25D38C800AFF85803C65D048003BCCE4C5AEE`** |
| 构建 | `efx_map` 退出码 0；5 步流程退出码 0 |
| 与 MERGE17 的差异 | ① 新增 APB 字 19/20/21 白平衡译码；② 彩色增益 VIO→APB 兜底；③ debayer R/B 增益接反修正。音频端口恢复为 MERGE17 原状（不接） |

刷法：`flash_vendor_utf8.ps1 -Bit ... -Sha256 D165EDCA...`，然后上传固件 `C15D47FD`。

## 3. 还没验证的（如实）

1. **没人看着屏幕**，所以"修完是否不紫"未验证；需要一次上板（刷 `MERGE21_WB` + 固件 `C15D47FD`）人眼确认；
2. 修好后固件里的 `WB_R/G/B` 才第一次真正生效，**这三个值本身可能还需要按现场光源重调**
   （备好了 6 组增益轮换固件 `415AE102`，15 s 一组，届时只需报"第几组正"）；
3. `MERGE20_AUDIO_SILENT`（音频隔离实验）仍未验证，优先级低于白平衡。

## 4. 复现要点

```powershell
# 综合检查
powershell -File D:\v30_build\map_only_ge.ps1          # 期望 MAP_EXIT=0
# 出位流（5 步：map → pnr → interface → filter → pnr+bitgen）
powershell -File D:\v30_build\v7_audio_flow.ps1 -Work D:\v30_build\m17 -Tag MERGE21_WB
```
