# mot_offline — v30 MOT 离线回放数据

- 测试内容：A–E 六段与 D/E 两段的离线日志，用于 `replay_mot.c` 回放与 `pred_eval.py` 评估。
- 固件：v30 第二轮 `fw_v30_final.bin`（318,322 B / CRC32 `E6535D37`）。
- 结论：基线 下一帧误差 3.87/23.41 px（n=534）、2 帧 7.28/27.46（n=485）、ROI 47 进 6 中、提前量 250 ms、误预警 2；`r3_offline/` 为第三轮离线输出（缩略图 2× 回放，仅供相对对比）。
- 原始日志：`serial_A-E_v30q.log`（2.31 MB）、`serial_DE_v30s.log`（0.39 MB）；`r3_offline/`。
- 对应技术文档：`evidence/v30_mot/FIX_REPORT.md` 第九节。
