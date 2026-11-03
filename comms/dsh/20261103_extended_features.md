# 扩展功能推进（网口 → 网页 → 多目标 → 预测）2026-11-03 晚

按优先级完成情况（90 min 窗口）：

## 1. 千兆网口事件上报 —— ✅ 真正打通（之前一直没通）

**根因不是协议格式，是 RTL 预取错位**：`ge_raw_tx.v` 的 `S_PRE` 每拍都重写 `cur/rdaddr`，
而 RAM 是同步读 → 发出去的整帧相对缓冲区前移 4 字节，目的 MAC 已成垃圾，网卡全判坏帧
（现象就是"pkt_cnt 一直涨、err 一直涨、应用层 0 包"）。

修 `S_PRE` 后实测（位流 `9A62F22A…8EF`）：

- 心跳 type=2 每 2 s 一条；
- 报警事件 type=1（`INTRUDE x=28 y=47 conf=100 obs=2`）到达并写入 events.jsonl；
- 空场 110 s 无 INTRUDE（误报正常）；
- 缩略图链路：固件本轮补上了 `ge_thumb_pump()` 的主循环调用（之前只 prepare 不 pump，
  一片都发不出去），PC 端 10×1000 B 重组已用 `tools/fake_board.py` 验证；
- **v5.2 新增实时画面**：空场每 500 ms 推一帧 96×96（eid 0xFFFF0001），
  纯 `--udp` 模式下页面也有画面（截图 `evidence/web/dashboard_udp_2026-11-03.png`）。

## 2. 网页 —— ✅ 重做，单文件 `tools/page.html`

链路/帧率/推理/温度/低功耗胶囊、实时灰度画面、事件时间线（可点开缩略图）、
缩略图墙、nt/obs 走势图、报警横幅。页面只认 `/api/state`，串口与 UDP 两种数据源通用。

## 3. 多目标 —— 🟡 算法改动已上板，缺"有人的两版对比"

- 现有记录（ev1..ev3）三条硬指标：框高几乎恒为 96（整幅）、ID 存活中位 1~3 帧、
  预测从未生效（`pre_eta=-1` 恒成立）；
- 已改：面积增长率 EMA → `mot_eta_frames` 两路取最小（靠近镜头给 3~10 帧提前量），
  `mot_predict_box` 用 1/2 阻尼速度；
- `MOT_V16_GATE/KEEP` 与新的 `MOT_GATE_SIZE_DIV` **保持默认关闭**：现有日志里带检测框的帧
  只有 6/5/14 帧，三种配置回放结果完全一致，不足以判定，按"不要默认打开"执行；
- 需要的下一步（只能人来做）：`py -3 tools\capture_mot.py --port COM15 --out out\mot_A`
  跑一遍基线固件（`out_v30_e7`, AA5188F9），再用当前固件跑一遍 `out\mot_B`，
  然后 `py -3 tools\mot_analyze.py out\mot_A\serial.log out\mot_B\serial.log --md out\mot_cmp.md`。

## 4. 预测 —— 🟡 逻辑通了、可上报，缺真人触发

- 数据驱动选了 1/2 阻尼速度（离线 37 条航迹：中位误差 5.00 px，全速 7.07，静止 6.00）；
- ETA 逻辑用 `tools/eta_sim.py` 做了合成序列自检（站定 -1 / 慢走近 35 帧 / 快走近 2~4 帧），
  并据此修掉三个实现问题（EMA 冷启动、阈值不一致、地平线太短）；
- 预警触发时会额外发一个 **UDP type=2 (TREND)** 事件，页面能提前看到"正在靠近"；
- 空场验证无虚假预警（`pre=0`）；真人靠近时的 `pre_eta` 数值需要现场确认。

## 交付物

| 文件 | 说明 |
|---|---|
| `evidence/eth_rgmii/UDP_EVENT_2026-11-03.md` | 网口打通全过程（根因/修复/实测/复现） |
| `evidence/eth_rgmii/rtl/ge_raw_tx.v` | 修好的 TX 模块 |
| `evidence/v30_mot/MOT_PRED_2026-11-03.md` | 离线指标与预测器对比表 |
| `evidence/v30_mot/MOT_PRED_RUN_2026-11-03.md` | 上板验证记录 |
| `tools/web_monitor.py` + `tools/page.html` | PC 端监控（串口/UDP/HTTP） |
| `tools/mot_analyze.py` `tools/pred_eval.py` `tools/mot_replay.py` `tools/cap.py` `tools/fake_board.py` | 离线分析与联调工具 |

固件：`out_v30_e13` CRC32 **76188F5F**（实时画面 + TREND 事件 + v17.2 ETA）；留档：e12 `A1CD467E`、e11 `B2F8AC11`、e9 `98AE9A19`、e7 `AA5188F9`。
位流：`D:\eth_build\m17_ge\outflow\ti60f225_oob.bit` SHA256 `9A62F22A…8EF`。
