# UDP 事件包格式（v1）

> 用途：板端（RISC-V/固件）通过 UDP 把事件与缩略图上报给 PC 端 `tools/web_monitor.py --udp <port>`。
> 字节序：**大端**（网络序）。所有字段无填充。

## 1 通用包头（16 B）

| 偏移 | 长度 | 字段 | 说明 |
|---|---|---|---|
| 0 | 2 | 魔数 | 固定 `0x4D 0x54`（ASCII `"MT"`） |
| 2 | 1 | 版本 | 固定 `0x01` |
| 3 | 1 | 包类型 | 1=事件、2=心跳、3=缩略图分片 |
| 4 | 4 | 事件 id | 同一次事件的所有包使用同一 id（心跳填 0） |
| 8 | 2 | 序号 | 缩略图分片从 1 开始；事件/心跳填 0 |
| 10 | 2 | 总片数 | 缩略图分片总数；事件/心跳填 1 |
| 12 | 4 | 时间戳 | 板端毫秒计数（`uint32`，回绕可接受） |

## 2 包类型 1：事件（负载 5 B）

| 偏移 | 长度 | 字段 | 取值 |
|---|---|---|---|
| 16 | 1 | 事件类型 | 0=NORMAL、1=INTRUDE、2=TREND、3=PERSON、4=LOWPWR |
| 17 | 1 | 位置 x | 0–95（96×96 画面坐标） |
| 18 | 1 | 位置 y | 0–95 |
| 19 | 1 | 置信度 | 0–100 |
| 20 | 1 | 画面人数 obs | 0–255 |

## 3 包类型 2：心跳（负载 0 B）

仅 16 B 包头；PC 端计入心跳统计，不落盘事件。

## 4 包类型 3：缩略图分片（负载 ≤1000 B）

- 负载为 96×96 灰度像素（9216 B）按固定 1000 B 切片，顺序号 1..N（N=10，最后一片 216 B）。
- PC 端按 `事件 id` 聚合，`序号 → 负载` 存表；收齐 `总片数` 后拼成 96×96 灰度 PNG（`out/live/thumbs/thumb_<id>.png`），并在 `events.jsonl` 追加一条 `kind="THUMB"`、带 `thumb` 字段的记录。
- **乱序/重复**：以序号为键覆盖写，重复片不报错。
- **缺片**：等待 3 s 仍不齐时，写一条 `kind="THUMB"`、`thumb_incomplete=true` 的记录（含 `got/total`），**不丢弃**。

## 5 PC 端落盘

| 文件 | 内容 |
|---|---|
| `out/live/events.jsonl` | 每行一条事件（`kind/ts/detail/thumb/id`；缺片时 `thumb_incomplete=true`） |
| `out/live/thumbs/thumb_<id>.png` | 重组后的 96×96 灰度缩略图（192×192 显示） |

## 6 示例（Python 发送）

```python
import socket, struct
def hdr(ptype, eid, seq=0, total=1, ts=0):
    return b"MT" + bytes([1, ptype]) + struct.pack(">IHHI", eid, seq, total, ts)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# 事件：INTRUDE, x=30, y=40, conf=77, obs=2
s.sendto(hdr(1, 1001) + bytes([1, 30, 40, 77, 2]), ("127.0.0.1", 8080))
# 缩略图：96×96 灰度，切成 10 片
raw = bytes(96 * 96)
for i in range(10):
    part = raw[i*1000:(i+1)*1000]
    s.sendto(hdr(3, 1001, seq=i+1, total=10, ts=0) + part, ("127.0.0.1", 8080))
```

## 7 自测

`py -3 tools/udp_event_selftest.py`：本机发送「正常事件 + 乱序/重复缩略图 + 缺片 + 心跳 + 无图事件」，验证重组与落盘；全部 PASS 才算通过。
