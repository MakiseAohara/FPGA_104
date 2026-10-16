# 上板 checklist（2026-10-15 **v2** 位流）

> **位流：`D:\FPGA\mmt\out\mmt.bit`，2,919,486 B，2026-10-15 14:26:32（v2）**
> 时序：408 条 slack、负 0 条、最小 **+0.026 ns**；资源 XLR 45017/60800、BRAM 235/256、DSP 24/160。
> 写通路守卫 `check_wr_path.ps1` **4/4 PASS**。固件 9932 B 已逐字节核对进位流。
> 回退版位流：`out_v1_backup\mmt_v1_1414.bit`（14:14:42，无测试图案/串口命令 → 不建议，仅作回退）。
>
> v2 在 10-13 版基础上加了：**加速器完成中断接进 SoC**（修了个致命 bug，见下）+ 固件 ⑤低功耗 /
> 串口命令（昼夜+测试图案+阈值）/ 预处理（异常值剔除+滑动平均）/ 开机自动测试图案。
> 固件细节见 `docs\v2固件改动说明.md`；作战计划见 `docs\上板作战计划-2026-10-15.md`。
>
> ⚠️ **v2 的固件会开机先显示 ~10 秒测试图案再自动切回摄像头** —— 这是**故意的**：
> 原固件没有任何写 0xC8 的通路，M0 做不了；见 `v2固件改动说明.md` §2.6。
> 详细字段表以 `docs\上板判据-摄像头上游探针.md`（最新版）与 `docs\测试图案注入.md` 为准。

---

## 0. 前置（**缺一不可**，见 README §5.2）

```powershell
# ★ 2026-10-15 实测修正：只设 EFX_HIFTDI_ENABLE 直接调 python3.bat 在**干净 shell 里会失败**，
#   实测两次：① "Fatal Python error: init_fs_encoding ... No module named 'encodings'"（缺 PYTHONHOME）
#             ② 补 PYTHONHOME 后 "KeyError: 'EFXPGM_HOME'"（efx_dbg\openocd_manager.py:44 要它）
#   必须先把 Efinity 运行环境补全。下面这段已实测能走到 JTAG 连接阶段
#   （无板子时报 "ERROR: No USB target detected, aborting!" 即为链路正常）。
$efi = "D:/Efinity/2026.1"
$env:EFINITY_HOME                = $efi
$env:EFINITY_USER_DIR_INI        = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity/user_dir.ini'
$env:EFINITY_USER_DIR            = ($env:LOCALAPPDATA -replace '\\','/') + '/efinity'
$env:EFXPT_HOME  = "$efi/pt";  $env:EFXPGM_HOME = "$efi/pgm"
$env:EFXDBG_HOME = "$efi/debugger"; $env:EFXIPM_HOME = "$efi/ipm"
$env:PYTHONHOME  = "$efi/python311"
$env:QT_PLUGIN_PATH = "$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH = "$efi/python311/platforms"
$env:PATH = "$efi/python311/bin;$efi/bin;$efi/scripts;" + $env:PATH
$env:EFX_HIFTDI_ENABLE = "1"      # 否则报 No Board Profile Selected

# FTDI 驱动版本必须统一（ftdibus/ftdiport 同版本 2.12.36.4），否则 0x000000FC 蓝屏
& "$efi/bin/python3.bat" "$efi/pgm/bin/efx_pgm/ftdi_program.py" `
  "D:\FPGA\mmt\out\mmt.bit" -m jtag -b "Generic Board Profile Using FT4232H"
```

> ★ 上面这一整套已经封装成 **`tools\flash_mmt.ps1`**（含位流时间戳核对、FTDI 驱动版本检查、
> 烧录判据自动检查、日志留档）。推荐直接用：
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\flash_mmt.ps1
> ```

**成功判据**：`Connecting to JTAG_TAP: efx_ti` → `Device ID read from JTAG: 0x10660A79` → `finished with JTAG programming`
（注意：**必须是 `.bit`**，传 `.hex` 会报格式错）

---

## 1. 先确认"烧对了版本 + 系统活着"（不用插摄像头）

串口 **COM19 @115200**，应出现 4 行：
```
T=0.0C RH=0.0% IR=0.0C score=0.0
ALM=0 AUTH=0 EVT=0 ST=0x00000000 thr=154 hr=0 auth22-6
[WR] AW=0(d=0) W=0(d=0) st=0x00 FRM=367(d=11) [AMAX] ... [FS] ... [VW] vis=0x00
[CAM] SCL=..(d=..) CK=..(d=..) PCLK=..(d=..) DE=..(d=..) HS=..(d=..) VS=..(d=..) st=0x.... wc=..(d=..) link=0x........
```
| 看什么 | 说明 |
|---|---|
| **在位流魔数**（`link` 的 `[31:17] == 0x2A5C`）| 证明**烧的是新版**；读不到魔数 ⇒ 位流没生效，别往下走 |
| `[WR] AW/W = 0` | **正常**（没摄像头就没数据）|
| `FRM` 持续增长 | 显示**读**通路在跑（读的是 DDR 里的旧数据）✓ |
| `PCLK` 一直涨 | **正常且无意义**：它是 PLL 输出，与摄像头无关 ⇒ 只能当参照尺 |

---

## 2. ★ M0：不插摄像头，先证明"写 DDR → 读 DDR → 显示"

```powershell
# 用你的调试方式写 SoC 寄存器（APB 基址 0xF8100000）
#   0xF81000C8 = 0x00000001     # 开彩条+方块（mode: 1=纯红 2=纯绿 3=纯蓝）
```
**预期**（同时满足才算过）：
1. **HDMI 上出现 8 色彩条 + 横向移动的方块**，且**红是红、蓝是蓝**（这是今天修掉 R/B 交叉后的验证点）
2. 串口 `[WR] AW` 与 `W` **持续增长**、`st≠0`
3. `[AMAX] amax` 落在 **`[0x02000000, 0x02BDDE00)`** 且 `az=OK` ⇒ **帧步长修复在硬件上生效**
4. `0xCC/0xD0/0xD4`：`LINES_PER_FRAME ≈ 1080`、`PIXELS_PER_LINE ≈ 480`、`VID_FRAME_CNT` 增长

**失败分支**：
- **没画面但 `AW/W` 在涨** ⇒ 断点在**读通路或 HDMI**（查 `hdmi_tx_*`、dvi_encoder、屏本身）
- **`AW/W` 不涨** ⇒ 先**读回 `0xC8`** 确认寄存器真的写进去了；再查测试图案是否真的在跑（`0xD4` 帧计数是否增长）
- **画面是紫的** ⇒ 说明烧的不是这版位流（R/B 修复没进去）

---

## 3. 插摄像头**之前**的硬件检查 ⚠️

1. **J2/J3 跳线 = 1.2V**（MIPI bank 电压；厂商文档里是"**会烧 IO**"级警告）
2. FPC 插到底并**压紧翻盖**；只有一个方向（已确认）
3. **断电插拔**

---

## 4. 关掉测试图案，按判据顺序读 `[CAM]`

```powershell
#   0xF81000C8 = 0x00000000     # 切回摄像头
```
**按顺序看，第一个"不动"的就是断点**：

| 步 | 看什么 | 结论 |
|---|---|---|
| 1 | 魔数 `0x2A5C` | 位流里确有探针 |
| 2 | `w_arstn` / `pix_rstn` 位（都为 1）| 三个 PLL 锁定、复位已释放 |
| 3 | SCL **总数**（不是 `d=`）与 **ACK 数** | SCL 有总数但 **ACK = 0** ⇒ 传感器没响应（**硬件**：供电/排线/地址）；`SCL(d=0)` 是配置发完的**正常**现象 |
| 4 | **HS_ENA**（ck 与 d0~d3）| 恒 0 ⇒ 摄像头没进入 HS（**硬件**）；拉起过 ⇒ 摄像头在说话 |
| 5 | `word_count` / `datatype` / `vc` | 非零 ⇒ 包头解析成功；`wc(d=0)` 是**正常**现象 |
| 6 | `de` / `hs` / `vs` | VS ≈ 2×帧率；有 DE 无 VS ⇒ 多半是噪声 |

**两个分界线**：
- **SCL 有总数但 ACK=0** 或 **HS_ENA 恒 0** ⇒ **硬件侧**（排线 / 供电 / 复位脚 / 跳线）
- **HS_ENA 拉起但 `de/vs` 不动** ⇒ **IP 内部或工具版本**（我们与厂商摄像头 demo 唯一的实质差异是 **Efinity 2026.1.132 vs demo 的 2024.1.163**，而 2026.1 已知会误折写通路 ⚠️）

---

## 5. 出问题时**别忘**的三件事

1. **把原始串口整段贴出来**（尤其 `[CAM]` 整行）—— 判读坑很多（`PCLK` 无意义、`SCL(d=0)`/`wc(d=0)` 是正常、`fifo_rd_empty` 不能当证据、`d=` 无固定时间基准）
2. **记下你改过的每个寄存器**（`0xC8` 切回 0 了吗？）
3. **烧录/串口异常先看 README §5.2**（前置条件四条 + 已知坑）
