# v27 MERGE15 + v26 实际采集

正式数据：2026-10-27 15:13:47.707–15:18:17.184（UTC+08:00），269.477 秒。479 条 DEC、383 次实际 AI、10 张完整 96×96 图；GAP 0、重连 0。字节、逐 DEC 字段、图像像素、人工表及 irhot 行数已独立核对。

manual_events_raw.csv 是实际按键，manual_timetable.csv 只作设备时钟映射。存在重复 ENTER、缺少 EMPTY_CONFIRMED、最后 LEAVE 后低头/侧身前缺少新 ENTER，详见 summary.md 与 manual_annotation_notes.json。不补造事件，不自动判断有效性。

ir_observation.csv/JSON 的分段只是沿用最后一条实际 E/L/Space；漏按会使延续状态不能代表真实画面。irhot 本次有 0 和 1，不据此宣布红外恢复。没有手机视频文件。

## 当前采集流程

1. load_merge15_once.py 验证指定 MERGE15 SHA256、v26 CRC32/SHA256，调用原有已使用过的加载协议；主机错误不自动回刷。
2. open_manual_flow.py 打开 manual_smoke_panel.ps1。串口只由 capture_v27.py 后端打开；面板经标准输入/输出发送实际按键。
3. 冒烟只按目视记录 Space → E → 报警确认 A → L → 释放确认 R；串口输出不判定任何真值。五类实际输入依次齐备并保存后，整个冒烟记录器退出，才打开正式面板。
4. 正式 manual_label_panel.ps1 沿用 1512f07 的操作者开始/T0、九个大按钮/快捷键、红色计时及结束保存；仅增加接受新的人工冒烟记录作为准入。正式采集由操作者点开始，不自动开始。
5. build_v27_board.py、derive_ir.py、verify_v27_board.py 在采集结束后导出并核对事实。

run_merge15_smoke.py 是前三轮旧流程的历史代码/加载辅助，直接入口已停用，不再自动用串口判真值或因主机错误回退。新的加载器只复用其中的原始加载辅助函数。

## 证据范围

- log_v27_gate.log / uart_bytes.bin：正式连续日志及收到的字节。
- ticks.csv、ai_samples.csv、frames/、frames.csv、contact_sheet_p1.png：正式派生数据；每页最多 40 图，按同帧设备 ms 和 p 标注。
- load_attempt4/、manual_smoke_attempt4/、manual_flow_transition.json：最终 MERGE15 加载、实际目视标注及进程退出/启动衔接。
- smoke/、smoke_attempt2/、smoke_attempt3/、rollback_merge14*/、board_setup_attempt*.json：早先的中断和回退记录，不能混作正式数据。
- com15_process_audit.json / com15_exclusive_check.json：事后进程检查与独占打开结果。历史报错时没有句柄快照，不臆造当时占用者。
- software_preparation/：1512f07 时缺位流的软件准备状态，属于历史快照，不是当前状态。
- ui_validation/：离线检查和明确标注的模拟界面预览；不包含模拟 UART/人工动作表。

固件与 RTL 未修改、未重新编译；没有 VIO/LA、白平衡、曝光/AE 或相机命令。当前实际加载的 MERGE15 及原 v26 身份见 board_setup.json。数据有效性和报警判定由 Claude 分析。
