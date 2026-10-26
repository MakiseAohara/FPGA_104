# 先读这个（给 Codex）——今天是关口日，时间紧

更新：2026-10-26 13:10（Claude / Kevin）

## 现在只做一件事

补测 v19 入侵→报警关口，6 轮真人。其余一律排后。

1. 板子上跑的就是 v19（串口日志持续输出，MMT_DEC 行带 t= 与 person= 列）。不需要再烧录。若日志里没有 person= 列，才烧 evidence/v19/tinyml_pdti8_v19_dump.bin（CRC32 9410DBEF）。
2. 用现成的 capture_v22.py 抓：空场 30 s → 6 轮[走入站稳 20 s → 走出 → 空场 30 s] → 空场 60 s，约 8 分钟。
3. 开始前看显示器，确认人站在镜头前约 1–2 m 时全身在画面里；窗帘开、主灯开、台灯不对着人、不穿白色或纯黑。
4. 数据推到 evidence/v25_gate/，并在 comms/codex/ 写一条说明（做了什么、没做什么、问题）。

目标：今天 16:00 前推上来，Claude 当天给结论。

## 今天明确不做

- VIO / LA / debug_profile.wizard.json / USER TAP 调试通道：v24_wb 的记录已足够（三轮 IDCODE 正确、VIO/LA 全 FF），不要继续排查，不要向用户要这些文件。
- 白平衡增益、AE/曝光、红外排查、帧缓冲核对、新 RTL、新固件、重新编译。
这些已排到 10/27 以后，见 comms/claude/20261026_schedule.md。

## 卡住时

任何单个障碍超过 15 分钟没进展：在 comms/codex/ 写说明（做了什么、卡在哪、需要谁回答什么），然后换下一项能做的，不要等用户。烧录失败不是阻塞，板子本来就在跑 v19。

## 约定

- 证据（日志/脚本/图）只放 evidence/；判断与建议放 comms/。
- 决策函数 ai_vote_update / ai_reset / dec_update / dec_log 的 sha1 必须与 v19 相同（02d4d67f9d / d94890eb6c / 367d08c50a / b82cff3903）；变了先报告再动。
- 详细材料：comms/URGENT.md、comms/claude/20261026_gate_review.md、comms/claude/20261026_schedule.md、docs/Codex对接说明.md。
