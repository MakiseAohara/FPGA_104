#!/usr/bin/env python3
"""Derive factual v22 artifacts from a single timestamped raw capture.

Uses same-frame joins, never invents an image or fills missing sensor samples.
The capture itself is not modified. Requires Pillow only for complete images.
"""
import argparse
import bisect
import csv
import datetime as dt
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path

KV = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
IMG = re.compile(r"^MMT_IMG\s+(\d{1,2})\s+([0-9a-fA-F]{192})\s*$")
TZ = dt.timezone(dt.timedelta(hours=8))


def wall_number(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=TZ)
        return parsed.timestamp()
    except (ValueError, TypeError):
        return None


def numeric(fields, key, default=None):
    try:
        return int(fields[key], 10)
    except (KeyError, ValueError, TypeError):
        return default


def load_json(path):
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8-sig"))
        except (ValueError, OSError) as exc:
            return {"读取记录": str(exc)}
    return None


def write_csv(path, fields, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def split_line(raw):
    if "\t" in raw:
        prefix, body = raw.split("\t", 1)
        if wall_number(prefix) is not None:
            return prefix, body.strip()
    return "", raw.strip()


def build(evidence):
    evidence.mkdir(parents=True, exist_ok=True)
    log_path = evidence / "log_v22_gate.log"
    # Firmware emits LF-CR. Preserve embedded CR and the timestamp attached to
    # each physical LF-delimited record; universal-newline reads lose this link.
    lines = log_path.read_bytes().decode("utf-8-sig", errors="replace").split("\n") if log_path.exists() else []
    if lines and lines[-1] == "":
        lines.pop()
    metadata = load_json(evidence / "run_metadata.json")
    attempts = load_json(evidence / "attempts.json")
    decs, boot, alarm_events, lp_events, images, events = [], [], [], [], [], []
    by_frame, scores, pps, lp_frames = {}, {}, {}, {}
    session = 0
    context_f = None
    prior_t = None
    lp_state = None
    image_group = None
    incomplete_images = 0
    gaps = reconnects = disconnects = 0
    camera_ffff = []
    camera_exp_gain = []

    def abandon_image():
        nonlocal incomplete_images, image_group
        if image_group is not None:
            incomplete_images += 1
            image_group = None

    for line_number, raw in enumerate(lines, 1):
        wall, text = split_line(raw)
        fields = dict(KV.findall(text))
        tag = text.split(" ", 1)[0]
        gaps += int(bool(re.match(r"^### GAP(?:\s|$)", text)))
        reconnects += int(bool(re.match(r"^### RECONNECTED(?:\s|$)", text)))
        disconnects += int(bool(re.match(r"^### (?:RECONNECT_TRY|DISCONNECTED|SERIAL_DISCONNECT)(?:\s|$)", text)))
        if "### EVT " in text:
            event_match = re.search(r"### EVT\s+(\S+)", text)
            if event_match:
                event_wall = fields.get("wall", wall)
                events.append({"event": event_match.group(1), "wall": event_wall, "note": text})
        if tag == "MMT_LIVE_BOOT":
            abandon_image()
            session += 1
            context_f, prior_t, lp_state = None, None, None
        if tag.startswith("MMT_CAM") or tag in ("MMT_LIVE_BOOT", "MMT_BOOT", "MMT_CFG", "MMT_LIVE_CFG"):
            boot.append((session, wall, text))
            if tag.startswith("MMT_CAM"):
                for key, value in fields.items():
                    if re.search(r"exp|gain|^gc$|^gf$", key, re.I):
                        camera_exp_gain.append((session, wall, key, value))
                        if re.fullmatch(r"(?:0x)+[fF]{4}|65535", value):
                            camera_ffff.append((session, wall, key, value))
        if tag in ("MMT_AI", "MMT_OSD"):
            f = numeric(fields, "f")
            if f is not None:
                context_f = f
                p = numeric(fields, "p")
                if p is not None:
                    scores[(session, f)] = p
        elif tag == "MMT_PP":
            frame = numeric(fields, "f", context_f)
            mean = numeric(fields, "mean_sensor")
            if frame is not None and mean is not None:
                pps[(session, frame)] = mean
        elif tag == "MMT_DEC":
            t, f = numeric(fields, "t"), numeric(fields, "f")
            if t is None:
                continue
            if prior_t is not None and t < prior_t:
                abandon_image()
                session += 1
                lp_state = None
            prior_t = t
            context_f = f
            row = {"session": session, "f": f, "wall": wall, "wall_number": wall_number(wall),
                   "device_ms": t, "motion": numeric(fields, "motion"),
                   "area": numeric(fields, "area"), "person": numeric(fields, "person"),
                   "alarm": numeric(fields, "alarm_req"), "lp_fallback": lp_state,
                   "line": line_number}
            decs.append(row)
            if f is not None:
                by_frame[(session, f)] = row
        elif tag == "MMT_LP":
            f = numeric(fields, "f")
            value = numeric(fields, "fw_lp", numeric(fields, "lowpwr"))
            if f is not None and value is not None:
                lp_frames[(session, f)] = value
            if value is not None:
                lp_state = value
        elif tag in ("MMT_LP_ENTER", "MMT_LP_EXIT"):
            kind = "enter" if tag.endswith("ENTER") else "exit"
            lp_events.append((session, kind, numeric(fields, "ms"), wall))
            lp_state = int(kind == "enter")
        elif tag == "MMT_ALARM":
            words = text.split()
            kind = words[1] if len(words) > 1 else "unknown"
            alarm_events.append((session, kind, numeric(fields, "ms"), wall, text))
        elif tag == "MMT_IMGSTAT":
            abandon_image()
            image_group = {"session": session, "f": numeric(fields, "f"), "p": numeric(fields, "p"), "rows": {}, "wall": wall}
        elif tag == "MMT_IMG":
            match = IMG.match(text)
            if match and image_group is not None:
                y = int(match.group(1))
                if 0 <= y < 96:
                    image_group["rows"][y] = bytes.fromhex(match.group(2))
                if len(image_group["rows"]) == 96:
                    image_group["pixels"] = b"".join(image_group["rows"][y] for y in range(96))
                    image_group.pop("rows")
                    images.append(image_group)
                    image_group = None
    abandon_image()

    ticks = []
    mean_bins = defaultdict(list)
    unmatched_pp = 0
    for row in decs:
        key = (row["session"], row["f"])
        row["p"] = scores.get(key)
        row["lp"] = lp_frames.get(key, row["lp_fallback"])
        ticks.append(row)
    for key, mean in pps.items():
        row = by_frame.get(key)
        if row is None:
            unmatched_pp += 1
        else:
            mean_bins[(row["session"], row["device_ms"] // 60000)].append(mean)
    write_csv(evidence / "ticks.csv", ["device_ms", "motion", "area", "p", "person", "alarm", "lp"], ticks)

    raw_event_path = evidence / "script_events_raw.csv"
    if raw_event_path.exists():
        with raw_event_path.open(encoding="utf-8-sig", newline="") as stream:
            for row in csv.DictReader(stream):
                event = row.get("event", row.get("action", ""))
                event_wall = row.get("wall", row.get("wall_time", row.get("wall_clock", "")))
                events.append({"event": event, "wall": event_wall, "note": row.get("note", "")})
    unique_events = {}
    for event in events:
        if re.match(r"^(ENTER|LEAVE)(?:\d+|\b)", event["event"]):
            unique_events[(event["event"], event["wall"])] = event
    wall_decs = sorted((row["wall_number"], i, row) for i, row in enumerate(decs) if row["wall_number"] is not None)
    wall_keys = [item[0] for item in wall_decs]
    event_rows = []
    for event in sorted(unique_events.values(), key=lambda x: wall_number(x["wall"]) or float("inf")):
        row = dict(event)
        row.update(device_ms=None, session=None, dec_wall="", delta_ms=None)
        stamp = wall_number(event["wall"])
        if stamp is not None and wall_keys:
            position = bisect.bisect_left(wall_keys, stamp)
            options = wall_decs[max(0, position - 1):position + 1]
            _, _, nearest = min(options, key=lambda item: (abs(item[0] - stamp), item[0]))
            row.update(device_ms=nearest["device_ms"], session=nearest["session"], dec_wall=nearest["wall"],
                       delta_ms=round((nearest["wall_number"] - stamp) * 1000, 3))
        event_rows.append(row)
    write_csv(evidence / "script_events.csv", ["event", "wall", "device_ms", "session", "dec_wall", "delta_ms", "note"], event_rows)

    # A rebuilt evidence directory must not retain sheets from an older run.
    # Only this generator's direct output names are replaced; raw logs remain.
    for prior_page in evidence.glob("contact_sheet_p*.png"):
        if re.fullmatch(r"contact_sheet_p\d+\.png", prior_page.name):
            prior_page.unlink()
    pages = []
    if images:
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.load_default(size=15)
        for start in range(0, len(images), 40):
            chunk = images[start:start + 40]
            cell_w, cell_h = 215, 242
            sheet = Image.new("RGB", (8 * cell_w, 5 * cell_h + 40), "white")
            draw = ImageDraw.Draw(sheet)
            page = start // 40 + 1
            draw.text((12, 8), f"v22 gate | page {page} | {len(chunk)} complete frames", fill="black", font=font)
            for offset, item in enumerate(chunk):
                row = by_frame.get((item["session"], item["f"]))
                item["device_ms"] = row["device_ms"] if row else None
                x, y = (offset % 8) * cell_w, (offset // 8) * cell_h + 40
                arr = Image.frombytes("L", (96, 96), item["pixels"]).resize((192, 192), Image.Resampling.NEAREST)
                sheet.paste(arr, (x + 10, y + 4))
                device_label = str(item["device_ms"]) if item["device_ms"] is not None else "unmatched"
                draw.text((x + 10, y + 198), f"ms={device_label} p={item['p']}", fill="black", font=font)
                draw.text((x + 10, y + 218), f"session={item['session']} f={item['f']}", fill="black", font=font)
            destination = evidence / f"contact_sheet_p{page}.png"
            sheet.save(destination)
            pages.append(destination.name)

    intervals = []
    open_alarms = {}
    for sid, kind, device_ms, wall, text in alarm_events:
        if kind == "start":
            if sid in open_alarms:
                intervals.append((sid, open_alarms[sid], None, "再次 start 前未见 end"))
            open_alarms[sid] = device_ms
        elif kind == "end":
            intervals.append((sid, open_alarms.pop(sid, None), device_ms, ""))
        else:
            intervals.append((sid, None, device_ms, f"原始事件：{kind}"))
    for sid, start in open_alarms.items():
        intervals.append((sid, start, None, "日志结束或下次启动前未见 end"))
    sessions = defaultdict(list)
    for row in decs:
        sessions[row["session"]].append(row)

    out = ["# v22 入侵→报警关口实测记录", "", "只记录采集事实与数字；硬件和检测效果的评估由操作者进行。", ""]
    def add(*parts):
        out.extend(parts)
    add("## 记录范围", "")
    add(f"- 原始日志：`log_v22_gate.log`，{len(lines)} 行。", f"- MMT_DEC：{len(decs)} 行，设备时钟分段：{len(sessions)} 段。")
    for sid, rows in sessions.items():
        add(f"- 分段 {sid}：device_ms {rows[0]['device_ms']}–{rows[-1]['device_ms']}；墙钟 {rows[0]['wall'] or '未记录'}–{rows[-1]['wall'] or '未记录'}。")
    add("- 无时区墙钟按 Asia/Shanghai（UTC+08:00）解释。", "")
    if isinstance(metadata, dict):
        add("## 固件与本次采集", "", "| 项 | 记录 |", "|---|---|")
        metadata_fields = [
            ("固件", "firmware_file"), ("固件字节数", "firmware_bytes"),
            ("固件 CRC32", "firmware_crc32"), ("固件 SHA256", "firmware_sha256"),
            ("位流", "bitstream_file"), ("位流 SHA256", "bitstream_sha256"),
            ("串口", "port"), ("波特率", "baudrate"), ("模式", "mode"),
            ("采集开始", "started_wall"), ("观察开始", "observation_started_wall"),
            ("观察结束", "observation_ended_wall"), ("采集结束", "ended_wall"),
            ("修改固件", "firmware_modified"), ("修改曝光", "exposure_modified"),
            ("发送相机命令", "camera_commands_sent"), ("上传后复位", "reset_after_firmware_upload"),
        ]
        for label, field in metadata_fields:
            if field in metadata:
                value = metadata[field]
                if isinstance(value, bool):
                    value = "是" if value else "否"
                if value is None:
                    value = "未记录"
                add(f"| {label} | `{value}` |")
        add("")
        if metadata.get("acquisition_error"):
            add("采集过程异常记录：`" + str(metadata["acquisition_error"]) + "`。", "")
            if "No MMT_CAM boot lines captured" in str(metadata["acquisition_error"]) and any(text.startswith("MMT_CAM") for _, _, text in boot):
                add("该异常由采集器的前导 CR 匹配问题触发；离线保留原始 LF/CR 重新解析后，日志内已找到下列 MMT_CAM 原始行。", "")
    if isinstance(attempts, list) and attempts:
        add("## 操作尝试记录", "", "| 轮次 | 开始墙钟 | 结束墙钟 | 固件上传完成 | 异常记录 |", "|---:|---|---|---|---|")
        for attempt in attempts:
            if not isinstance(attempt, dict):
                continue
            completed = "是" if attempt.get("upload_completed") is True else "未记录完成"
            error = str(attempt.get("error", "")).replace("|", "\\|").replace("\n", " ")
            add(f"| {attempt.get('attempt', '')} | {attempt.get('started_wall', '')} | {attempt.get('ended_wall', '')} | {completed} | {error} |")
        add("")
    boot_only = (isinstance(metadata, dict) and metadata.get("mode") == "boot_only") or any("### BOOT_ONLY_START" in raw for raw in lines)
    add("## 动作流程记录", "")
    if boot_only:
        add("用户暂缓六轮真人实测；本次仅采集上板启动后的观察数据，未执行 ENTER/LEAVE 动作流程。")
        if not event_rows:
            add("`script_events.csv` 仅有表头，对应本次未执行的动作事件。")
    else:
        add(f"记录到 ENTER/LEAVE 动作事件 {len(event_rows)} 条。")
        if not event_rows:
            add("`script_events.csv` 仅有表头；原始记录中没有 ENTER/LEAVE 事件。")
    if not images:
        add("原始日志没有完整 96×96 图组，未生成 contact_sheet_p*.png。")
    add("")
    add("## 开机与相机原始行", "")
    if boot:
        add("```text")
        for sid, wall, text in boot:
            add(f"session={sid} wall={wall or '未记录'} {text}")
        add("```", "")
    for name in ("MMT_LIVE_BOOT", "MMT_CAM"):
        count = sum(text.startswith(name) for _, _, text in boot)
        add(f"- {name} 前缀行数：{count}。")
    if camera_ffff:
        for sid, wall, key, value in camera_ffff:
            add(f"- 相机读回：session={sid} wall={wall or '未记录'} {key}={value}（65535 / 0xFFFF）。")
    elif camera_exp_gain:
        add("- 已记录的 MMT_CAM exp/gain 字段中没有 0xFFFF 值。")
    else:
        add("- MMT_CAM 原始行没有输出 exp/gain 读回字段；本次没有这些读回值。")
    add("", "## MMT_ALARM 区间（设备 ms）", "")
    if intervals:
        add("| 分段 | start_ms | end_ms | duration_ms | 记录 |", "|---|---:|---:|---:|---|")
        for sid, start, end, note in intervals:
            duration = end - start if start is not None and end is not None else ""
            add(f"| {sid} | {'' if start is None else start} | {'' if end is None else end} | {duration} | {note} |")
    else:
        add("日志中无 MMT_ALARM 行。")
    if alarm_events:
        add("", "全部 MMT_ALARM 原始事件：", "", "```text")
        for sid, kind, device_ms, wall, text in alarm_events:
            add(f"session={sid} wall={wall or '未记录'} {text}")
        add("```")
    add("", "## 低功耗进入 / 唤醒（设备 ms）", "")
    if lp_events:
        add("| 分段 | 事件 | device_ms | 墙钟 |", "|---|---|---:|---|")
        for sid, kind, device_ms, wall in lp_events:
            add(f"| {sid} | {kind} | {'' if device_ms is None else device_ms} | {wall} |")
    else:
        add("日志中无 MMT_LP_ENTER / MMT_LP_EXIT 行。")
    add("", "## mean_sensor 每 60 秒中位数", "", "按分段及设备时钟区间 [start_ms, end_ms) 统计；MMT_PP 通过同帧 f 对齐 MMT_DEC，不沿用上一帧时间。无样本区间留空。", "")
    if sessions:
        add("| 分段 | start_ms | end_ms | 样本数 | mean_sensor 中位数 |", "|---|---:|---:|---:|---:|")
        for sid, rows in sessions.items():
            for bucket in range(min(r["device_ms"] for r in rows) // 60000, max(r["device_ms"] for r in rows) // 60000 + 1):
                samples = mean_bins[(sid, bucket)]
                median = f"{statistics.median(samples):g}" if samples else ""
                add(f"| {sid} | {bucket * 60000} | {(bucket + 1) * 60000} | {len(samples)} | {median} |")
    else:
        add("无可匹配 MMT_DEC 的 mean_sensor 样本。")
    add("", "## 采集计数与字段来源", "", "| 项 | 数量 |", "|---|---:|",
        f"| GAP 行 | {gaps} |", f"| 串口重连成功（### RECONNECTED） | {reconnects} |", f"| 串口断开/重连发起标记（含 ### RECONNECT_TRY） | {disconnects} |",
        f"| 完整 96×96 图组 | {len(images)} |", f"| 未完成图组（有 IMGSTAT） | {incomplete_images} |", f"| contact sheet 页数 | {len(pages)} |",
        f"| ENTER / LEAVE 事件 | {len(event_rows)} |", f"| 无同帧 DEC 的 MMT_PP | {unmatched_pp} |",
        f"| alarm_req=1 的 DEC | {sum(r['alarm'] == 1 for r in decs)} |", f"| person=1 的 DEC | {sum(r['person'] == 1 for r in decs)} |", "",
        "- ticks.csv 的 alarm 来自 MMT_DEC.alarm_req；不是从 RTL 报警位推断。",
        "- p 来自同分段同帧 MMT_OSD.p / MMT_AI.p；lp 表示固件休眠状态，优先来自同帧 MMT_LP.fw_lp，缺失时使用同帧 lowpwr 或已记录状态，缺失值留空。",
        "- script_events.csv 在全部带墙钟的 MMT_DEC 中选绝对时间差最小的一条，允许位于动作前或后；delta_ms = DEC墙钟 − 动作墙钟。",
        "- contact sheet 每页最多 40 张，只使用收齐 96 行的原始图像，并以同帧 DEC 标注 device_ms。",
        "- 灯光只以本记录的 mean_sensor 中位数表呈现。", "")
    (evidence / "summary.md").write_text("\n".join(out), encoding="utf-8", newline="\n")
    result = {"dec": len(decs), "complete_images": len(images), "pages": len(pages), "events": len(event_rows), "alarm_events": len(alarm_events), "lp_events": len(lp_events), "gaps": gaps, "reconnects": reconnects, "unmatched_pp": unmatched_pp}
    print(json.dumps(result, ensure_ascii=False))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    build(parser.parse_args().evidence.resolve())
