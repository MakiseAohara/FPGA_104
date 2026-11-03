# PC_SIDE — 2026-11-03 电脑端两件事

> 未改动：`dec_update` 判决逻辑、低功耗逻辑、位流、白平衡。所有改动均带宏开关，默认关闭。
> 未上板（本轮不需要板子）。

## 一、web_monitor 增加网口（UDP）输入

### 1.1 用法

```
# 串口模式（原样保留）
py -3 tools/web_monitor.py --port COM15 --http 8080 --out out/live

# UDP 模式
py -3 tools/web_monitor.py --udp 8080 --http 8081 --out out/live

# 两种同时开
py -3 tools/web_monitor.py --port COM15 --udp 8080 --http 8080 --out out/live
```

### 1.2 协议

已写入 `evidence/eth_rgmii/UDP_EVENT_FORMAT.md`：

- 包头 16 B：魔数 `"MT"`(2) + 版本(1) + 包类型(1) + 事件 id(4) + 序号(2) + 总片数(2) + 时间戳 ms(4)，大端。
- 包类型：1=事件（类型/位置 x,y/置信度/画面人数 obs）、2=心跳、3=缩略图分片（每片 ≤1000 B）。
- 缩略图：96×96 灰度 = 9216 B → 10 片；按 id+序号重组，乱序/重复以序号覆盖；缺片 3 s 后标 `thumb_incomplete`（不丢弃）。

### 1.3 落盘与页面

| 项 | 说明 |
|---|---|
| `out/live/events.jsonl` | 每行一条事件；含 `kind/ts/detail/thumb(eid)`；缺片带 `thumb_incomplete=true` |
| `out/live/thumbs/thumb_<id>.png` | 重组后的 96×96 灰度（192×192 显示） |
| `tools/page.html` | **唯一页面源**（web_monitor 读取它，不再内嵌）；事件列表点击展开缩略图，缺片显示 `[缩略图不全]` |

### 1.4 自测

`py -3 tools/udp_event_selftest.py`（本机发模拟包：正常事件、乱序+重复缩略图、缺 1 片、心跳、无图事件）：

```
PASS  事件落盘（3 条事件）  events=5
PASS  事件 id 完整  ids=[1001, 1002, 1003]
PASS  1001 事件类型/坐标/置信度/人数
PASS  1001 缩略图重组成功（乱序+重复）  thumbs=['thumb_1001.png']
PASS  1001 缩略图文件存在
PASS  1002 缺片被标记而不是丢弃
PASS  1002 没有生成缩略图文件
PASS  1003 无缩略图事件仍落盘
RESULT: ALL PASS
```

## 二、MOT v16 两处小改动（离线，默认关闭）

文件：`evidence/v30_mot/mot_core.h`；补丁：`evidence/session_1103/mot_v16.patch`。

| 宏 | 默认 | 行为 |
|---|---|---|
| `MOT_V16_GATE` | **0** | 宽 ≥0.9×96 且高 ≥0.9×96 且 AI 判无人（`p < MOT_P_PERSON`）的检测**不建新航迹**（滤波前景/整幅噪声） |
| `MOT_V16_KEEP` | **0** | 已确认航迹在 miss 期间若 AI 仍判有人，`MOT_MAX_MISS` 由 6 放宽到 `MOT_MAX_MISS_KEEP=10` |

编译：`-DMOT_V16_GATE=1 -DMOT_V16_KEEP=1` 打开；不传则与现网行为一致。

### 2.1 回归（test_mot.c）

- 默认（宏 0）：`MOT_TESTS PASS (fails=0)`
- 宏开（GATE=1, KEEP=1）：`MOT_TESTS PASS (fails=0)`
- 用例数：当前仓库 `test_mot.c` 含 S0–S13（含 S11 split / S13 separated pair），**全部通过**。

### 2.2 回放对比（缩略图 2× 回放，仅看有无明显退化，不作上板依据）

数据：`submission/data/mot_offline/serial_A-E_v30q.log` 的 259 帧缩略图；回放日志见 `evidence/session_1103/replay_v16{off,on}.log`。

| 指标 | V16 关闭 | V16 开启 | 变化 |
|---|---|---|---|
| 唯一 ID 总数 | 94 | **80** | −14（−15%） |
| 航迹出现帧数 | 536 | 528 | −8 |
| ID 存活中位（帧） | 2.0 | 2.0 | 不变 |
| obs(nd) 分布 | {0:62, 1:63, 2:53, 3:37, 4:23, 5:13, 6:8} | {0:62, 1:62, 2:53, 3:35, 4:26, 5:13, 6:8} | 基本不变 |

**说明**：ID 总数下降主要来自整幅大块噪声不再建轨；单人/双人检出帧数与中位存活不变，未见明显退化。回放与板上 96×96 真帧口径不同（航迹行数 −70%、ID +89%），**结论只用于相对比较**。

## 三、验收对照

| 验收项 | 结果 |
|---|---|
| UDP 自测脚本全通过 | ✅ ALL PASS（8 项） |
| test_mot 回归全通过 | ✅ 默认与宏开均 PASS |
| 对比表在仓库 | ✅ 本节 + `evidence/session_1103/replay_v16{off,on}.log` |
| 补丁在仓库 | ✅ `evidence/session_1103/mot_v16.patch` |
| 默认关闭、未合进默认构建 | ✅ 两个宏默认 0 |
| 未改 dec_update / 低功耗 / 位流 / 白平衡 | ✅ 仅改 mot_core.h 与 tools/*.py、page.html |

## 四、交付文件

| 文件 | 说明 |
|---|---|
| `tools/web_monitor.py` | 加 `--udp`，读 `page.html` |
| `tools/page.html` | 唯一页面源（缩略图点击展开） |
| `tools/udp_event_selftest.py` | UDP 自测 |
| `evidence/eth_rgmii/UDP_EVENT_FORMAT.md` | 包格式 |
| `evidence/v30_mot/mot_core.h` | v16 两个宏（默认 0） |
| `evidence/session_1103/mot_v16.patch` | 补丁 |
| `evidence/session_1103/replay_v16off.log` / `replay_v16on.log` | 回放原始输出 |
