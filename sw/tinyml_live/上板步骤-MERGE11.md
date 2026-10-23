# MERGE11 上板步骤（② RISC-V 决策 + ⑤ 低功耗）

> 位流：`project/v7_camera_ai/bitstream/v7_MERGE11.bit`
> 固件：`sw/tinyml_live/tinyml_pdti8_merge11.bin`（469,434 B，CRC32 `0C587DBF`；源码 `sw/tinyml_live/main_live15.cc`）
> 前提：这台机器上已装好 FTDI + Efinity + RISC-V 工具链；本机没有板子，以下步骤给有板子的队友。

---

## 1. 烧位流 + 灌固件（顺序不能反）

先起加载器（它在等 `MMT_BOOT`），再烧位流触发复位上载：

```powershell
# 窗口 A：加载器（成功判据：出现 MMT_LIVE_BOOT）
cd <仓库>\sw\tinyml_live
python load_and_run.py --port COM15 --image ..\tinyml_live\tinyml_pdti8_merge11.bin ^
    --out .\capture_merge11 --boot-timeout 45 --run-timeout 180

# 窗口 B：烧位流（JTAG 临时加载，会触发复位）
powershell -ExecutionPolicy Bypass -File <mmt>\tools\flash_vendor.ps1 ^
    -Bit <仓库>\project\v7_camera_ai\bitstream\v7_MERGE11.bit
```

> 若加载器在 65 KB 左右偶发中断，**重试即可**（历史已知的 UART 偶发问题，不是镜像问题）。

---

## 2. 开机应出现的日志（MERGE11 标志）

```
MMT_LIVE_BOOT v15_merge11 FW_DEC=1 LOWPOWER=1
MMT_LIVE_MODEL in_bytes=9216 in_type=9
MMT_LIVE_HW_READY uuid=0x4923687a
MMT_CAM_VTS ok=1 vts=0x05dc rom_vts=0 fallback=1     ← 相机 VTS 只读一次；rom_vts=0 表示开机 ROM 表无该寄存器
MMT_OSD f=0 chk=... p=... a=... v=... osd=... ci=... ms=... b0m=... raw=...   ← 与旧版一致
MMT_DEC f=0 score=... mean=... slope=... con=... trend=... evt=0 alarm_req=0 conf=... motion=... irhot=... area=... rtl_conf=... rtl_alarm=... fw_en=0 win=...
MMT_LP f=0 lowpwr=0 paused=0 camfps=0 inf_hz=0 ddr_ar_s=... tml_ar_s=... infer=... sht_upd=0 ir_upd=0 sht=... rh=... body=... vts=0x05dc vts_ok=1 fallback=1
```

要点：
- `FW_DEC=1 LOWPOWER=1` → 两个功能都编进了固件；
- `MMT_DEC` / `MMT_LP` 行开始出现 → 位流/固件是 MERGE11 这一套；
- `fw_en` 在 2 个样本后变为 1（此时 RTL 的最终报警才开始受固件 `alarm_req` 门控）。

---

## 3. 验证 ②（RISC-V 决策控制）

1. 空场静止：`MMT_DEC score≈0..40 mean≈0..40 alarm_req=0 evt=0`；
2. 人进入画面 1–1.5 m 站立 2–3 秒：
   - `area` 明显变大、`motion=1`；
   - `score/mean` 上升，`con` 递增到 3 → `alarm_req=1`、`evt=1`；
   - 若同时有红外热点，OSD 红框/LED/蜂鸣器出现（最终报警 = RTL 报警 & 固件 alarm_req）；
3. 人离开：`mean` 降到 `<=70` 后 `alarm_req=0`（迟滞，不抖）；
4. **对比演示（可选项）**：短促挥手 <1.3 s 时，RTL 可能瞬时给出报警，但固件 `con` 还没到 3，
   `alarm_req=0` ⇒ 红框/蜂鸣被抑制（体现"历史确认滤除瞬态"）。若想复现旧行为，见 §5 关掉 ②。

判读阈值：`score/mean` 是 RTL 融合得分（0..511）；`alarm_req` 是固件写入字14 的决策位。

---

## 4. 验证 ⑤（低功耗场景管理）

1. 清空画面、保持无人，等待约 **15 秒**（RTL `PWR_IDLE_FRAMES=900` @60 fps）：
   - `MMT_LP_ENTER f=... lp=1` 打印一次；
   - 之后 `MMT_LP lowpwr=1 paused=1 inf_hz=0`；
   - `infer=` 不再增长（神经网络推理已暂停）；
   - `ddr_ar_s` / `tml_ar_s` 明显下降（不再读帧缓冲 / 不跑加速器）；
   - `sht_upd` / `ir_upd` 仍持续增加（温度监测未停，SHT30 1 Hz、MLX90640 2 Hz 由 RTL 保持）；
   - `MMT_DEC` 仍每 500 ms 更新一次（低功耗期间 ② 决策不停止，只是降频）；
   - 位流层面 `v7_pwr_ctl` 把视觉处理帧率降到 1/4（帧差处理），摄像头输出帧率**不变**（见 §6）。
2. 人回到画面（或挥手）：
   - `MMT_LP_EXIT f=... lp=...` 打印；
   - `paused=0`，`inf_hz` 恢复 ≈2，`MMT_OSD` 恢复每帧输出；
   - 恢复时延：RTL 同帧清 `low_pwr`，固件最坏 500 ms 内看到并恢复。

> **首次进入低功耗需要 15 秒无人**；演示时建议先拍"无人等待→MMT_LP lowpwr=1→人回来→恢复"的完整过程。

---

## 5. 出问题时如何关掉 ② 或 ⑤

两个功能由 `sw/tinyml_live/main_live15.cc` 顶部宏控制（默认都开）：

```c
#define FW_DECISION_ON   1       // ②
#define LOWPOWER_ON      1       // ⑤
```

- 只关 ②：把 `FW_DECISION_ON` 改成 `0` 重新编译固件 → 固件不再写 APB 字14/15，
  RTL 的 `fw_decision_enable` 保持复位值 0，**最终报警与 MERGE10 完全一致**；
- 只关 ⑤：把 `LOWPOWER_ON` 改成 `0` → 推理不暂停（仍打印 low_pwr 状态，供观察）；
- 两个都关：固件行为回到 main_live14 的"连续推理"，仅多打印 `MMT_DEC/MMT_LP` 观测行。

**注意**：开了 ② 但想临时恢复"纯 RTL 报警"，也可以趁固件运行时写 APB 字15 bit0=0
（地址 `0xF810003C`，写 0）——不需要重编固件。

---

## 6. 当前实现范围（上板前先知道）

| 项 | 状态 |
|---|---|
| 字 11/12/13 证据 / 字 14/15 决策接口 | ✅ RTL 已实现，仿真通过 |
| ② 滑动窗口/连续确认/迟滞/事件分类/趋势预警 | ✅ 固件已实现 |
| ⑤ 暂停神经网络推理（low_pwr 时） | ✅ 固件已实现（板上待验证） |
| ⑤ 保留温度监测 | ✅ RTL 未改，固件日志有 `sht_upd/ir_upd` 证据 |
| ⑤ 降低摄像头帧率（VTS） | ❌ 未实现：开机 ROM 表无 `0x320e/0x320f`，按约定回退；`vts=` 只是只读记录 |
| 功耗数字 | ❌ 无功率计；用 `camfps/inf_hz/ddr_ar_s` 作系统活动量指标 |

---

## 7. 日志采集（给报告用）

```powershell
# 把串口日志存文件（若用串口助手/daemon，确保从 MMT_BOOT 开始录）
python load_and_run.py ... --out .\capture_merge11 --run-timeout 180
# capture_merge11\ 下有 uart_capture.txt / result.json / osd_hosttime.log
```

建议视频分段：
1. 空场 → MMT_DEC 低分；
2. 人进入站 2–3 s → alarm_req=1、红框/蜂鸣；
3. 人离开 → alarm_req=0；
4. 无人静置 15 s → `MMT_LP_ENTER`、`paused=1`、`inf_hz=0`、`sht_upd` 仍涨；
5. 人回来 → `MMT_LP_EXIT`、`inf_hz` 恢复。
