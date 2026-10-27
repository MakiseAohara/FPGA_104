"""Offline smoke-gate checks. No board access or operator evidence is written."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('smoke',Path(__file__).with_name('run_merge15_smoke.py'))
smoke=importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class Checks(unittest.TestCase):
    def setUp(self):
        self.facts=smoke.SmokeFacts()
        self.start=smoke.loader.dt.datetime.fromisoformat('2026-10-27T15:00:00+08:00').timestamp()

    def operator(self,name,second):
        wall=smoke.loader.dt.datetime.fromtimestamp(self.start+second,smoke.loader.TZ).isoformat(timespec='milliseconds')
        self.facts.operator(dict(event=name,wall=wall))

    def tick(self,second,alarm=0,fps=60):
        self.facts.serial(f'MMT_LP f={second*2:g} camfps={fps} body=220',self.start+second)
        self.facts.serial(f'MMT_DEC t={1000+int(second*1000)} alarm_req={alarm} irhot=0',self.start+second)

    def test_four_facts_require_actual_empty_and_both_visual_observations(self):
        for i in range(64): self.tick(i*.5)
        self.assertIsNone(self.facts.checks['empty_30s_no_alarm'])
        self.operator('EMPTY_CONFIRMED',32)
        for i in range(64,126): self.tick(i*.5,fps=0 if i%2 else 60)
        self.assertTrue(self.facts.checks['empty_30s_no_alarm'])
        self.assertTrue(self.facts.checks['dec_and_camera_fps'])
        self.assertIsNone(self.facts.checks['hdmi_osd'])
        self.operator('ENTER',63)
        for i in range(126,140): self.tick(i*.5,alarm=1)
        self.operator('LEAVE',70)
        for i in range(140,150): self.tick(i*.5,alarm=int(i<145))
        self.assertIsNone(self.facts.checks['enter_alarm_leave_release'])
        self.operator('HDMI_OK',75)
        self.operator('VISUAL_ALARM_RELEASE_OK',75)
        self.assertTrue(all(value is True for value in self.facts.checks.values()))
        self.assertIsNone(self.facts.failure)

    def test_confirmed_empty_alarm_stops_gate(self):
        self.operator('EMPTY_CONFIRMED',0)
        self.tick(1,alarm=1)
        self.assertFalse(self.facts.checks['empty_30s_no_alarm'])
        self.assertEqual(self.facts.failure_kind,'board_failure')

    def test_operator_reported_abnormality_stops_gate(self):
        self.operator('FAIL',0)
        self.assertEqual(self.facts.failure_kind,'operator_failure')
        self.assertFalse(any(self.facts.checks.values()))

    def test_sixty_dec_ticks_do_not_substitute_for_camera_fps(self):
        for i in range(80): self.tick(i*.5,fps=20)
        self.assertFalse(self.facts.checks['dec_and_camera_fps'])
        self.assertEqual(self.facts.failure_kind,'board_failure')


if __name__=='__main__': unittest.main(verbosity=2)
