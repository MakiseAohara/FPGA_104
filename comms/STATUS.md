⚠ 先读根目录 AGENTS.md 与 comms/URGENT.md：今天关口日，只做能完成的事。
# 状态（谁改谁写时间）

更新：2026-10-26 13:00（Claude）

## 候选固件
- tinyml_pdti8_v19_dump.bin：477,722 B，CRC32 9410DBEF，SHA256 8C0AE09D06851257D5412EC834C5BF143D91BFE2F30D111AC298BC571F0D2AD3
- 决策函数（v19/v20/v21 完全相同）：ai_vote_update 02d4d67f9d，ai_reset d94890eb6c，dec_update 367d08c50a，dec_log b82cff3903

## 关口（入侵→报警）
- 有效的真人实测：尚未完成。
- 2026-10-25 22:26 那一轮（提交 2f43c7a…3df1f2e）无效：6 个窗口里 5 个窗口运动帧为 0，板子在低功耗。详见 comms/claude/20261026_gate_review.md。
- 决策逻辑离线回放：v23_offline 真实 C 函数 1465 帧差异 0。

## 谁在做什么
- Codex：今天白天补测关口（见 20261026_gate_review.md 第 3 节）。
- Claude：分析数据，写结论到 comms/claude/。
- Kevin：协调，提供人和场地。

## 下一步
1. 补测 6 轮并推送 evidence/v25_gate/。
2. Claude 逐窗口分析后给出关口结论。
3. 之后按 comms/claude/20261026_schedule.md 走。

## 约定
- 证据（日志/脚本/图）只放 evidence/；判断与建议只放 comms/。
- 只改固件时：决策函数四个 sha1 必须不变；变了先报告再动。
MERGE15 位流已推到 evidence/v27_rtl_ir/,请按 10/27 总任务第二步继续(烧录→冒烟→有真值重测).
