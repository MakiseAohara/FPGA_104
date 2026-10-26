"""Offline checks: candidate isolation and actual manual labels versus prompts."""
import argparse
import contextlib
import csv
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
here=Path(__file__).resolve().parent
def module(name):
    spec=importlib.util.spec_from_file_location(name,here/(name+".py"))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result
builder=module("build_v26_board")
capture=module("capture_v26")

class Artifacts(unittest.TestCase):
    def test_old_firmware_excluded_manual_rows_preserved_and_mapped(self):
        with tempfile.TemporaryDirectory(prefix="v26_",dir=Path.cwd()) as folder:
            root=Path(folder);self.assertTrue(root.resolve().is_relative_to(Path.cwd().resolve()))
            lines=[
                "2026-10-26T19:00:00+08:00\tMMT_AI f=99 p=100 person=1",
                "2026-10-26T19:00:00+08:00\tMMT_DEC t=900000 f=99 motion=1 area=300 person=1 alarm_req=1",
                "2026-10-26T19:00:01+08:00\tMMT_LIVE_BOOT v19",
                "2026-10-26T19:00:02+08:00\tMMT_AI f=0 p=-10 person=0",
                "2026-10-26T19:00:02+08:00\tMMT_DEC t=121000 f=0 motion=0 area=0 person=0 alarm_req=0",
                "2026-10-26T19:00:02.5+08:00\tMMT_AI f=1 p=5 person=0",
                "2026-10-26T19:00:02.5+08:00\tMMT_DEC t=121500 f=1 motion=1 area=500 person=0 alarm_req=0",
                "2026-10-26T19:00:02.5+08:00\tMMT_IMGSTAT f=1 p=5",
            ]+["2026-10-26T19:00:02.6+08:00\tMMT_IMG %02d %s"%(y,"20"*96) for y in range(96)]
            log=("\n".join(lines)+"\n").encode();(root/"log_v26_gate.log").write_bytes(log)
            (root/"run_metadata.json").write_text(json.dumps(dict(mode="manual_protocol_v26")),encoding="utf-8")
            (root/"manual_events_raw.csv").write_text("event,wall,elapsed_s,device_ms_latest,prompt_phase,source\nENTER,2026-10-26T19:00:02.4+08:00,1.4,121000,ENTER_FIRST,human_button\n",encoding="utf-8")
            (root/"script_prompts.csv").write_text("scheduled_s,wall,event\n120,2026-10-26T19:02:01+08:00,ENTER_FIRST\n",encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()): result=builder.build(root)
            self.assertEqual(result["pre_candidate_dec"],1);self.assertEqual(result["dec"],2)
            self.assertEqual(result["complete_images"],1)
            with (root/"ticks.csv").open(newline="",encoding="utf-8") as stream: ticks=list(csv.DictReader(stream))
            self.assertEqual([x["device_ms"] for x in ticks],["121000","121500"])
            with (root/"manual_timetable.csv").open(newline="",encoding="utf-8") as stream: labels=list(csv.DictReader(stream))
            self.assertEqual(len(labels),1);self.assertEqual(labels[0]["wall"],"2026-10-26T19:00:02.4+08:00")
            self.assertEqual(labels[0]["source"],"human_button")
            self.assertEqual(labels[0]["device_ms_nearest"],"121500")
            self.assertEqual(int(labels[0]["device_ms_interpolated"]),121400)
            self.assertEqual(hashlib.sha256((root/"log_v26_gate.log").read_bytes()).digest(),hashlib.sha256(log).digest())
            self.assertFalse(json.loads((root/"annotation_status.json").read_text(encoding="utf-8"))["required_transitions_present"])

    def test_no_human_input_never_creates_action_labels(self):
        with tempfile.TemporaryDirectory(prefix="v26_",dir=Path.cwd()) as folder:
            root=Path(folder);self.assertTrue(root.resolve().is_relative_to(Path.cwd().resolve()))
            (root/"log_v26_gate.log").write_text("2026-10-26T19:00:00+08:00\tMMT_LIVE_BOOT v19\n### PROMPT event=ENTER_FIRST\n",encoding="utf-8")
            (root/"manual_events_raw.csv").write_text("event,wall,elapsed_s,device_ms_latest,prompt_phase,source\n",encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()): builder.build(root)
            status=json.loads((root/"annotation_status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["records"],0);self.assertFalse(status["required_transitions_present"])

    def test_protocol_600_seconds_with_no_manual_side_effects(self):
        with tempfile.TemporaryDirectory(prefix="v26_",dir=Path.cwd()) as folder:
            root=Path(folder);self.assertTrue(root.resolve().is_relative_to(Path.cwd().resolve()))
            clock=[0.0]
            class Stop:
                def wait(self,seconds): clock[0]+=seconds;return False
            class Cap:
                out=root;t0=None;phase="LOADING";last_dec=121000;fatal=None;stop=Stop()
                def log(self,text): pass
            metadata={}
            stamp=lambda: (dt.datetime(2026,10,26,19,tzinfo=dt.timezone(dt.timedelta(hours=8)))+dt.timedelta(seconds=clock[0])).isoformat()
            with patch.object(capture.time,"monotonic",lambda:clock[0]),patch.object(capture,"wall",stamp),patch.object(capture,"say",lambda text:None),contextlib.redirect_stdout(io.StringIO()):
                capture.run_protocol(Cap(),argparse.Namespace(out=root),metadata)
            self.assertEqual(clock[0],600)
            self.assertTrue(metadata["observation_completed"])
            self.assertFalse((root/"manual_events_raw.csv").exists())
            schedule={event:offset for offset,event,note in capture.PROTOCOL}
            self.assertEqual(schedule["ENTER_FIRST"],120)
            self.assertEqual(schedule["LEAVE_FIRST"],240)
            self.assertEqual(schedule["CHAIR_START"],270)
            self.assertEqual(schedule["ENTER_SECOND"],300)
            self.assertEqual(schedule["ENTER_WAKE"],480)
            self.assertEqual(schedule["HEAD_UP"]-schedule["HEAD_DOWN"],10)
            self.assertEqual(schedule["FACE_FRONT"]-schedule["SIDE_BODY"],10)

if __name__=="__main__": unittest.main(verbosity=2)
