# T8 Web 远程监控（拓展项 ⑥）

> 固件 v29.2 DAY（306,194 B / CRC32 `C15D47FD`）· 位流 MERGE17（SHA256 `3A69AAFB…087CF`）

## 做了什么

`tools/web_monitor.py` 把串口变成实时监控服务：

- `GET /`：页面（画面缩略图 + p/person/motion/area + ALARM/LOWPWR 状态 + 温湿度 + 统计 + 最近事件）
- `GET /api/status`：当前状态 JSON
- `GET /api/summary`：本次运行统计（帧数、有人帧、运动帧、报警起报次数、低功耗帧与占比）
- `GET /api/events`：最近 50 条事件
- `GET /frame.png`：最新 48×48 缩略图放大 4×

事件（alarm_start/alarm_end/lowpwr_enter/lowpwr_exit）写 `out/live/events.jsonl`，每次事件同时落一张缩略图到 `out/live/thumbs/`。

## 常驻运行（不用手动启动）

- `tools/mot_service.cmd`：看门狗循环，`web_monitor.py` 退出 5 秒后自动重拉；
- 登录自启：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `MMT_WebMonitor` 项 + 启动文件夹 `MMT_WebMonitor.cmd`；
- 实测：杀掉 monitor 进程后 18 秒内被看门狗拉起，`/api/status` 恢复 200。

## 本目录证据

| 文件 | 说明 |
|---|---|
| `page.html` | 实际抓取的页面源码 |
| `summary.json` | 抓取时刻的统计接口返回 |
| `frame.png` | 抓取时刻的画面缩略图 |
| `events.jsonl` | 事件流（含缩略图路径） |

## 边界（如实）

HTTP 服务跑在 PC 侧、通过串口取数；RISC-V 核内没有网络栈（拓展项 ① 的 RGMII 物理链路未接），
所以这一项是"远程监控能力已具备、载体在 PC 端"。