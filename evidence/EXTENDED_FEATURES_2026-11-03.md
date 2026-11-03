# 拓展功能对照表（2026-11-03 晚）

按"算法层能解决的先做"的顺序推进：网口 → 网页 → 多目标 → 预测。语音播报按要求不做。

| # | 赛题拓展项 | 实现位置 | 验证方式 | 结论 | 证据 |
|---|---|---|---|---|---|
| 1 | 千兆以太网数据上报（类型/时间/位置/置信度/缩略图） | `evidence/v30_mot/main_live30.cc`（`ge_udp_pkt/ge_ev_*/ge_thumb_*`）+ `rtl/ge_raw_tx.v` | `tools/acceptance.py` 实板 30 s / 300 s | ✅ 通过（6/6 项） | `evidence/eth_rgmii/UDP_EVENT_2026-11-03.md`、`accept_5min_2026-11-03.json` |
| 2 | RISC-V 软核决策控制（多目标/轨迹/预测/协议） | 同 `main_live30.cc` + `mot_core.h`（跑在 Efinix Sapphire RISC-V 上） | 板上运行 + `MMT_DEC/MMT_MOT/MMT_TRK` 串口 | ✅ 运行中（`camfps=59`） | 同上 |
| 3 | 多目标跟踪（IOU Tracker，多人体轨迹） | `mot_core.h`：IOU 一级关联 + 质心距离二级关联 + 速度外推 + 合并/切分 | 离线回放 `tools/mot_replay.py`；整幅块统计 `tools/fullframe_stats.py` | 🟡 已按数据打开 GATE；ID 稳定性需真人两次对比 | `evidence/v30_mot/MOT_PRED_2026-11-03.md` |
| 4 | 行为预测（速度向量外推 + 提前响应） | `mot_core.h`：1/2 阻尼速度预测、面积增长 ETA；`main_live30.cc`：`MOT_PRE_ON` 预警 + UDP `type=2 TREND` | 离线 `tools/pred_eval.py`（37 航迹）+ `tools/eta_sim.py`（合成序列自检） | 🟡 算法自检 PASS；真人靠近的提前量待现场 | `evidence/v30_mot/MOT_PRED_2026-11-03.md` 第 2/2.5 节 |
| 5 | 低功耗场景管理（无人降帧/关推理/保留温度/有人恢复） | 既有 `LOWPOWER_ON` 逻辑（未改动） | 空场自动进 LP、有人恢复 | ✅ 正常 | `comms/dsh/20261103_extended_features.md` |
| 6 | Web 远程监控 | PC 端 `tools/web_monitor.py` + `tools/page.html`（单文件页面） | 实板截图（串口 / 纯 UDP 两种） | ✅ 页面可用；板内 HTTP 协议栈因 RX 未通未启用 | `evidence/web/dashboard_live_2026-11-03.png`、`dashboard_udp_2026-11-03.png` |
| 7 | 语音播报 | —— | —— | 按要求不做 | —— |

## 关键数字

- 上报链路：心跳 2.58 s/条（低功耗下主循环量化）、事件包 21 B、缩略图分片 1000 B×9+216 B；
- 5 分钟空场：411 包、0 坏帧、103 心跳、0 误报事件；
- 预测：1/2 阻尼速度把"下一帧位置"中位误差从 7.07 px（全速）降到 5.00 px（静止 6.00 px）；
- ETA：站定 -1、慢走近 35 帧给出提前量、快走近 4 帧；
- 多目标：整幅块占 15.6% 且 100% 出现在 AI 判无人帧 → GATE 默认开。

## 复现命令

```powershell
# 板子：位流 + 固件
& D:\v30_build\flash_vendor_utf8.ps1 -Bit D:\eth_build\m17_ge\outflow\ti60f225_oob.bit     -Sha256 9A62F22A3A989944622E414C20030D6F8A8F9E47F9A99393F15287E3C7BAB8EF -Force
py -3 D:30_buildload_v30.py --image D:30_buildout_v30_e15	inyml_pdti8.bin --out D:30_buildout_load_e15

# PC：监控页 + 验收
.	oolsstart_demo.ps1 -Port COM15
py -3 toolsacceptance.py --secs 30
```
