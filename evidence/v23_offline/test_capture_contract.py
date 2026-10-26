"""Offline acquisition/parser contract regressions: no UART or board access."""
import contextlib
import csv
import importlib.util
import io
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[2]
TEST_WORK=ROOT.parent/"v23_contract_work"
sys.dont_write_bytecode=True


def temporary_work():
    TEST_WORK.mkdir(parents=True,exist_ok=True)
    temporary=tempfile.TemporaryDirectory(dir=TEST_WORK)
    # Check the exact generated absolute target before its recursive cleanup.
    Path(temporary.name).resolve().relative_to(TEST_WORK.resolve())
    return temporary


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


capture=module("gate_capture",ROOT/"evidence/v22_gate/capture_v22.py")
builder=module("gate_builder",ROOT/"evidence/v22_gate/build_gate.py")


class BytesPort:
    def __init__(self,chunks): self.chunks=list(chunks)
    @property
    def in_waiting(self): return len(self.chunks[0]) if self.chunks else 0
    def read(self,n): return self.chunks.pop(0) if self.chunks else b""


class CaptureContracts(unittest.TestCase):
    def test_lfcr_and_fragmented_lines_keep_boot_tail(self):
        with temporary_work() as folder:
            cap=capture.Capture(Path(folder))
            reader=capture.Reader(BytesPort([b"MMT_LIVE_B",b"OOT v19\n\rMMT_CAM_VTS ok=1\n\rMMT_DEC t=42 f=0\n\r"]),cap)
            with contextlib.redirect_stdout(io.StringIO()): reader.until("MMT_LIVE_BOOT",1)
            self.assertEqual(reader.next_line(),"MMT_CAM_VTS ok=1")
            self.assertEqual(reader.next_line(),"MMT_DEC t=42 f=0")
            self.assertEqual(cap.last_dec,42)
            self.assertEqual(cap.cams,["MMT_CAM_VTS ok=1"])
            cap.fh.close()

    def test_host_markers_do_not_hide_serial_silence(self):
        with temporary_work() as folder:
            cap=capture.Capture(Path(folder));cap.last_rx=cap.last_gap=0
            with patch.object(capture.time,"monotonic",return_value=5.1): cap.gap_check()
            cap.log("### EVT ENTER1")
            with patch.object(capture.time,"monotonic",return_value=10.2): cap.gap_check()
            self.assertEqual(cap.gaps,2)
            self.assertEqual(cap.last_rx,0)
            cap.fh.close()

    def test_reconnect_does_not_reflash(self):
        with temporary_work() as folder:
            cap=capture.Capture(Path(folder))
            reader=SimpleNamespace(cap=cap,buf=b"unfinished",port=Mock())
            calls=[0]
            def next_line():
                calls[0]+=1
                if calls[0]==1: raise OSError("synthetic disconnect")
                cap.stop.set()
            reader.next_line=next_line
            with patch.object(capture,"port_open",return_value=Mock()) as opened, patch.object(capture,"flash_and_upload") as flashed:
                capture.pump(reader,SimpleNamespace(port="NO_REAL_PORT"),Mock())
            opened.assert_called_once()
            flashed.assert_not_called()
            self.assertEqual(cap.reconnects,1)
            self.assertEqual(reader.buf,b"")
            cap.fh.close()

    def test_schedule_is_six_rounds_and_390_seconds(self):
        with temporary_work() as folder:
            waits=[]
            cap=SimpleNamespace(last_dec=123,log=Mock(),fatal=None,
                                stop=SimpleNamespace(wait=lambda seconds: waits.append(seconds) or False))
            with patch.object(capture,"speak"),contextlib.redirect_stdout(io.StringIO()):
                capture.schedule(cap,SimpleNamespace(out=Path(folder)))
            with (Path(folder)/"script_events_raw.csv").open(encoding="utf-8",newline="") as f:
                events=[r["event"] for r in csv.DictReader(f)]
            actions=[x for x in events if x.startswith(("ENTER","LEAVE"))]
            self.assertEqual(actions,[x for k in range(1,7) for x in ("ENTER%d"%k,"LEAVE%d"%k)])
            self.assertEqual(waits,[30]+[x for _ in range(6) for x in (20,30)]+[60])
            self.assertEqual(sum(waits),390)

    def test_ps5_environment_does_not_inherit_ps7_modules(self):
        before=dict(capture.os.environ)
        with patch.dict(capture.os.environ,{"PSModulePath":"C:/PowerShell7/Modules"}):
            env=capture.powershell_env()
            self.assertNotIn("PowerShell7",env["PSModulePath"])
            self.assertIn("WindowsPowerShell",env["PSModulePath"])
        self.assertEqual(dict(capture.os.environ),before)


class ParserContracts(unittest.TestCase):
    def build(self,folder,lines):
        root=Path(folder)
        (root/"log_v22_gate.log").write_bytes("\n".join(lines).encode())
        with contextlib.redirect_stdout(io.StringIO()): builder.build(root)
        return root

    def test_lfcr_fw_lp_ffff_and_nearest_future_dec(self):
        with temporary_work() as folder:
            root=self.build(folder,[
                "2026-10-26T01:00:00+08:00\t\rMMT_LIVE_BOOT v19",
                "2026-10-26T01:00:00.1+08:00\t\rMMT_CAM exp=0xFFFF gain=0xFFFF",
                "2026-10-26T01:00:01+08:00\t\rMMT_AI f=0 p=5 person=0",
                "2026-10-26T01:00:01+08:00\t\rMMT_PP mean_sensor=31",
                "2026-10-26T01:00:01+08:00\t\rMMT_DEC t=1000 f=0 alarm_req=0 motion=0 area=0 person=0",
                "2026-10-26T01:00:01.4+08:00\t### EVT ENTER1 wall=2026-10-26T01:00:01.4+08:00",
                "2026-10-26T01:00:01.5+08:00\t\rMMT_DEC t=1500 f=1 alarm_req=0 motion=0 area=0 person=0",
                "2026-10-26T01:00:01.5+08:00\t\rMMT_LP f=1 lowpwr=0 fw_lp=1 paused=1",
            ])
            with (root/"ticks.csv").open(encoding="utf-8",newline="") as f: ticks=list(csv.DictReader(f))
            with (root/"script_events.csv").open(encoding="utf-8",newline="") as f: events=list(csv.DictReader(f))
            self.assertEqual(ticks[0]["p"],"5")
            self.assertEqual(ticks[1]["lp"],"1")
            self.assertEqual(events[0]["device_ms"],"1500")
            self.assertAlmostEqual(float(events[0]["delta_ms"]),100)
            self.assertIn("exp=0xFFFF",(root/"summary.md").read_text(encoding="utf-8"))

    def test_empty_rebuild_removes_only_old_generated_sheets(self):
        with temporary_work() as folder:
            root=Path(folder)
            (root/"contact_sheet_p9.png").write_bytes(b"old generated sheet")
            (root/"contact_sheet_personal.png").write_bytes(b"keep")
            self.build(folder,[])
            self.assertFalse((root/"contact_sheet_p9.png").exists())
            self.assertTrue((root/"contact_sheet_personal.png").exists())
            with (root/"ticks.csv").open(encoding="utf-8",newline="") as f:
                self.assertEqual(list(csv.DictReader(f)),[])

    def test_partial_image_does_not_create_a_sheet(self):
        with temporary_work() as folder:
            root=self.build(folder,["MMT_IMGSTAT f=0 p=1"]+["MMT_IMG %02d %s"%(i,"00"*96) for i in range(95)])
            self.assertEqual(list(root.glob("contact_sheet_p[0-9]*.png")),[])


if __name__=="__main__": unittest.main(verbosity=2)
