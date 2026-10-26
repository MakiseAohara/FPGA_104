"""Offline checks of passive UART safety and factual evidence joins."""
import argparse
import contextlib
import csv
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capture = load("capture_v25")
builder = load("build_v25")


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Port:
    """Only read/open/close are available; any serial write/reset would fail."""
    def __init__(self, clock, chunks):
        self.clock = clock
        self.chunks = list(chunks)
        self.opened = False
        self.closed = False
        self.controls = []

    @property
    def in_waiting(self):
        return 0

    def __setattr__(self, key, value):
        if key in ("dtr", "rts") and "controls" in self.__dict__:
            if self.opened:
                raise AssertionError("Control line changed after port opened")
            self.controls.append((key, value))
        super().__setattr__(key, value)

    def open(self):
        self.opened = True

    def read(self, size):
        self.clock.sleep(0.2)
        value = self.chunks.pop(0) if self.chunks else b""
        if isinstance(value, Exception):
            raise value
        return value

    def close(self):
        self.closed = True


class Backend:
    def __init__(self, clock, chunks):
        self.clock, self.chunks, self.ports = clock, list(chunks), []

    def Serial(self, **kwargs):
        port = Port(self.clock, self.chunks.pop(0) if self.chunks else [])
        self.ports.append(port)
        return port


class CaptureTests(unittest.TestCase):
    def run_capture(self, folder, chunks, seconds=2):
        clock = Clock()
        backend = Backend(clock, chunks)
        args = argparse.Namespace(out=Path(folder), port="COM_TEST", seconds=seconds, resume=False)
        with patch.object(capture.time, "monotonic", clock.monotonic), patch.object(capture.time, "sleep", clock.sleep), contextlib.redirect_stdout(io.StringIO()):
            capture.capture(args, backend)
        return backend

    def test_passive_capture_without_boot_preserves_received_bytes(self):
        data = b"MMT_DEC t=1000 f=1 motion=1 area=300 person=0 alarm_req=0\n\r"
        with tempfile.TemporaryDirectory(prefix="v25_", dir=Path.cwd()) as folder:
            self.assertTrue(Path(folder).resolve().is_relative_to(Path.cwd().resolve()))
            backend = self.run_capture(folder, [[data[:20], data[20:]]])
            root = Path(folder)
            self.assertEqual((root / "uart_bytes.bin").read_bytes(), data)
            meta = json.loads((root / "run_metadata.json").read_text(encoding="utf-8"))
            self.assertTrue(meta["completed"])
            self.assertEqual(meta["last_device_ms"], 1000)
            self.assertFalse(meta["flashed"])
            self.assertFalse(meta["reset_requested"])
            self.assertEqual(meta["serial_writes"], 0)
            self.assertEqual(backend.ports[0].controls, [("dtr", False), ("rts", False)])
            log = (root / "log_v25_gate.log").read_bytes()
            self.assertNotIn(b"### EVT", log)
            self.assertNotIn(b"ENTER1", log)

    def test_disconnect_reconnects_without_any_write_or_reset(self):
        with tempfile.TemporaryDirectory(prefix="v25_", dir=Path.cwd()) as folder:
            self.assertTrue(Path(folder).resolve().is_relative_to(Path.cwd().resolve()))
            backend = self.run_capture(folder, [[b"partial", OSError("unplugged")], [b"MMT_DEC t=2000 f=2\n\r"]])
            meta = json.loads((Path(folder) / "run_metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(meta["reconnects"], 1)
            self.assertEqual(len(backend.ports), 2)
            self.assertTrue(all(p.closed for p in backend.ports))
            self.assertIn(b"### PARTIAL_LINE_HEX", (Path(folder) / "log_v25_gate.log").read_bytes())

    def test_zero_bytes_stops_after_three_passive_open_cycles(self):
        with tempfile.TemporaryDirectory(prefix="v25_", dir=Path.cwd()) as folder:
            self.assertTrue(Path(folder).resolve().is_relative_to(Path.cwd().resolve()))
            with self.assertRaisesRegex(RuntimeError, "three passive open cycles"):
                self.run_capture(folder, [[], [], []], seconds=600)
            meta = json.loads((Path(folder) / "run_metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(meta["open_cycles"], 3)
            self.assertFalse(meta["completed"])
            self.assertGreater(meta["gaps"], 0)


class BuilderTests(unittest.TestCase):
    def test_actual_ai_counts_images_and_same_frame_joins_without_boot(self):
        with tempfile.TemporaryDirectory(prefix="v25_", dir=Path.cwd()) as folder:
            root = Path(folder)
            self.assertTrue(root.resolve().is_relative_to(Path.cwd().resolve()))
            stamp = "2026-10-26T17:00:00+08:00\t\r"
            lines = [
                "MMT_OSD f=1 p=7",
                "MMT_DEC t=1000 f=1 motion=1 area=300 person=0 alarm_req=0",
                "MMT_AI f=2 p=-5 person=0", "MMT_PP mean_sensor=40",
                "MMT_DEC t=2000 f=2 motion=0 area=0 person=0 alarm_req=0",
                "MMT_LP f=2 lowpwr=0 fw_lp=1", "MMT_IMGSTAT f=2 p=-5",
            ] + ["MMT_IMG %02d %s" % (y, "20"*96) for y in range(96)]
            (root / "log_v25_gate.log").write_bytes("\n".join(stamp+s for s in lines).encode())
            (root / "run_metadata.json").write_text(json.dumps({"mode":"free_movement_after_authorized_flash"}), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                result = builder.build(root)
            with (root / "ticks.csv").open(encoding="utf-8", newline="") as f:
                ticks = list(csv.DictReader(f))
            self.assertEqual([x["p"] for x in ticks], ["7", "-5"])
            self.assertEqual(ticks[1]["lp"], "1")
            self.assertEqual(result["ai_samples"], 1)
            self.assertEqual(result["motion_frames"], 1)
            self.assertEqual(result["complete_images"], 1)
            self.assertTrue((root / "frames/frame_0001_ms_2000_f_2.png").is_file())
            self.assertTrue((root / "contact_sheet_p1.png").is_file())
            self.assertFalse((root / "script_events.csv").exists())
            summary = (root / "summary.md").read_text(encoding="utf-8")
            self.assertIn("不发动作提示", summary)
            self.assertNotIn("无效窗口", summary)


if __name__ == "__main__":
    unittest.main(verbosity=2)
