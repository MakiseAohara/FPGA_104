# v27 操作者控制的标注面板

当前仅完成软件准备与离线检查。MERGE15 文件未找到，未烧录、未执行冒烟、未正式采集；没有真实 v27 日志、动作 CSV 或手机视频。状态见 preflight.json、summary.md 与 comms/codex/20261027_v27_panel_merge15.md。

## 面板

`manual_label_panel.ps1`：大号绿色开始按钮，点击时刻即 T0；红底显示录制计时，结束后显示已保存。E/L、C/V、H/J、S/D、Space 与九个按钮对应，触发时响一声并闪黄。按住快捷键不重复记事件；快捷键只在窗口有焦点时生效。下方显示最近五条已落盘事件。建议流程只显示文字。

开始前不打开串口，也不创建日志或动作文件。开始/结束点击分别记 CAPTURE_START/CAPTURE_END；动作只来自操作者按键或按钮。不按键不生成动作。串口设备时间尚未收到时留空，不借用旧运行的 device_ms。关闭正在录制的窗口会按实际关闭时刻停止并保存，不补写离开事件。

正式模式要求 `board_ready.json` 中四项冒烟事实全部为 true、位流/固件身份匹配、rollback_required 为 false。`smoke_status.template.json` 的 null 仅为待填写结构，不能启用采集；此文件不得冒充实测。冒烟结论需来自本次实际日志与操作者 HDMI/OSD 观察，不能仅凭模板生成。

```powershell
# 在仓库根目录；需先完成 MERGE15 加载及四项冒烟检查。
pwsh -NoProfile -STA -File evidence/v27_gate/manual_label_panel.ps1

# 冒烟串口记录可使用独立目录；不包含刷写或复位。
pwsh -NoProfile -STA -File evidence/v27_gate/manual_label_panel.ps1 `
  -Mode smoke -Evidence evidence/v27_gate/smoke
```

操作者先在 HDMI 确认人距镜头 1.5–2 米、上半身到腰部入画，窗帘和主灯开，台灯不直照人，避免纯白/纯黑衣服。人先退出视野，Kevin 再点击开始。每次实际进入/完全离开分别按 E/L；椅子、低头、侧身按对应开始/结束键，确认真实空场按 Space。结束点红色区域下方的“结束采集并保存”。开始后不发相机命令、不复位、不刷写。

视频由现场手机录制 HDMI 右侧热力图；重测后手在 MLX 前约 20 cm 停 10 秒再拿开 10 秒也录入。没有视频文件就保留缺失状态，不作画面观察结论。

## 接收与派生文件

`capture_v27.py` 是接收后端，无烧录或串口发送逻辑；断线自动重连，不重刷，超过 5 秒空闲写 GAP。保留连续时间戳日志和收到的原始字节；断线时未完成的行另记十六进制，避免拼接不同连接的碎片。30 秒无法重连或设备时钟倒退时保存异常。现有采集文件受保护，不允许覆盖。

```powershell
# 真实采集结束后再运行，不产生缺失数据的空替代文件。
python evidence/v27_gate/build_v27_board.py --evidence evidence/v27_gate
python evidence/v27_gate/derive_ir.py --evidence evidence/v27_gate
python evidence/v27_gate/verify_v27_board.py --evidence evidence/v27_gate
```

派生格式沿用 v26：ticks.csv、ai_samples.csv、frames/、frames.csv、每页 40 张的 contact_sheet_p*.png、事实 summary.md。直接抓已有运行，不要求日志中出现新的开机行。manual_timetable.csv 保留原始输入并按最近 DEC / 同分段插值映射时钟；缺失标注不从计划、运动或模型结果推断。ir_observation.csv 按实际 ENTER / LEAVE / EMPTY_CONFIRMED 划分 person / empty / unlabelled，只列收到的 irhot 与同帧 body10；不计算覆盖率或作报警判定。

## 离线检查

`test_capture_v27.py` 检查未开始不操作串口、不生成计划标注、T0/输入时刻保留、接收断线/原始字节、打开失败/保护旧数据、无需开机行的解析、图像像素、人工时钟映射及红外阶段来源。

```powershell
python evidence/v27_gate/test_capture_v27.py
pwsh -NoProfile -STA -File evidence/v27_gate/manual_label_panel.ps1 `
  -SelfTest -SelfTestOut C:/path/outside-evidence/v27_ui_test
```

UI 自测使用模拟串口，并强制把模拟日志放在 evidence/ 之外。ui_validation/ 只存自测结论和带“离线界面测试”标题的预览图，不包含模拟动作表或模拟上板日志。Windows PowerShell 5.1 与 PowerShell 7 均已运行检查；PS1 保留 UTF-8 BOM 以确保 PS5 正确显示中文。
