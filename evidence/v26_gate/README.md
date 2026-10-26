# v26 离线候选，尚未上板

原任务要求只改两个宏；`main_live26.cc` 相对 `evidence/v19/main_live19.cc` 仅更改 AI_P_OFF=-80 和 AI_AREA_MAX=20000，差异保存在 parameters.patch。三个头文件与 sw/tinyml_live/v16 原文件逐字节相同。

实际 C 回放使用 v25 的 ticks.csv 和 ai_samples.csv，复用 v23 的编译器包装器，在 Unicorn RV32IM 中执行提取的原函数。v19 的 alarm/cand/rel/person 876/876 一致，未跳过初始片段或用日志状态覆盖内部状态。v26 得到 9 个报警段。区间以 MMT_DEC 的 device_ms 为采样边界，故不等于现场 MMT_ALARM 打印的精确时刻；固定输入回放也不等同于新的实测。

AI on-vote 不变，两版 person 序列完全相同。原固件低功耗分支只依赖 motion/last_person，不依赖 alarm_on，因此这两个参数下可沿用同一输入日志的低功耗/推理执行序列。

独立人在场设备 ms 标注未提供：覆盖率、人在场最长中断和实际离开后的释放延迟均保持未定。首 30 秒/末 60 秒仅是按原协议取的参考空场，不能代替真实标注。参见 replay_results.json 和 comms/codex/20261026_v26_replay_build.md。

完整候选已构建，CRC/SHA、原始及宏展开后的函数 SHA1 均在 manifest.json。为遵守“两处宏”约束，启动字符串仍是 v19，IMG_DUMP_EVERY 仍为官方源的 40；按 CRC、SHA 与 AREA 参数识别候选。

本目录没有 v26 实测日志、ticks.csv 或转储图。红外诊断接口及实物在场标注尚未补齐，未刷写候选或做十分钟自由走动。现有板卡状态未被本阶段更改。

复现回放需要仓库的 evidence/v23_offline/replay_actual_c.py、Unicorn 和 RV32 GCC：

```text
python evidence/v26_gate/replay_v26.py --repo . --work <scratch> --vendor <unicorn-directory> --toolchain <riscv-bin-directory>
```

该命令仅编译独立回放程序，不构建/刷写完整固件。完整构建使用既有 sw/tinyml_live/build_tinyml_firmware.py；实际编译、链接命令与构建输出保留在本目录。
