"""Offline checks only. All synthetic captures live in TemporaryDirectory."""
import csv
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE/(name+'.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

capture = load('capture_v27')
builder = load('build_v27_board')
infrared = load('derive_ir')
verifier = load('verify_v27_board')


class Port:
    def __init__(self, data=b'', disconnect=False):
        self.data, self.disconnect = data, disconnect
        self.closed = False
    @property
    def in_waiting(self):
        return len(self.data)
    def read(self, size):
        if self.data:
            data, self.data = self.data[:size], self.data[size:]
            return data
        if self.disconnect:
            self.disconnect = False
            raise OSError('test unplug')
        time.sleep(0.005)
        return b''
    def close(self):
        self.closed = True
    def write(self, data):
        raise AssertionError('Receive-only capture attempted a serial write')


class Checks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v27_offline_')
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)

    def read_events(self):
        with (self.out/'manual_events_raw.csv').open(encoding='utf-8', newline='') as stream:
            return list(csv.DictReader(stream))

    def wait_for(self, predicate):
        deadline = time.monotonic()+2
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.005)
        self.fail('Offline serial condition timed out')

    def test_no_prestart_io_no_planned_labels_and_exact_operator_t0(self):
        ports = []
        def factory():
            ports.append(Port(b'MMT_DEC t=1200 f=1 motion=0 area=0 person=0 alarm_req=0 irhot=0\n\r'))
            return ports[-1]
        run = capture.Recorder(self.out, port_factory=factory)
        self.assertEqual(list(self.out.iterdir()), [])
        self.assertEqual(ports, [])
        with self.assertRaises(RuntimeError):
            run.label('ENTER', capture.wall())
        t0 = capture.wall()
        run.start(t0)
        self.addCleanup(lambda: run.finish(None))
        self.wait_for(lambda: run.latest == 1200)
        # Waiting/GAP bookkeeping must never create action labels.
        with run.lock:
            run.last_rx = run.last_gap = time.monotonic()-6
            run.gap_check()
            self.assertEqual(run.gaps, 1)
        self.assertEqual([x['event'] for x in self.read_events()], ['CAPTURE_START'])
        action_wall = capture.wall()
        run.label('ENTER', action_wall, 'human_key')
        run.finish(capture.wall())
        rows = self.read_events()
        self.assertEqual([x['event'] for x in rows], ['CAPTURE_START','ENTER','CAPTURE_END'])
        self.assertEqual(rows[0]['wall'], t0)
        self.assertEqual(rows[1]['wall'], action_wall)
        self.assertEqual(rows[1]['device_ms_latest'], '1200')
        expected = (dt.datetime.fromisoformat(action_wall)-dt.datetime.fromisoformat(t0)).total_seconds()
        self.assertEqual(rows[1]['elapsed_s'], f'{expected:.3f}')
        self.assertTrue(ports[0].closed)

    def test_disconnect_preserves_raw_bytes_and_does_not_add_actions(self):
        payloads = [b'MMT_DEC t=100 f=1 irhot=0\n\rBROKEN', b'MMT_DEC t=200 f=2 irhot=1\n\r']
        ports = [Port(payloads[0], disconnect=True), Port(payloads[1])]
        remaining = list(ports)
        run = capture.Recorder(self.out, port_factory=lambda: remaining.pop(0))
        run.start(capture.wall())
        self.addCleanup(lambda: run.finish(None))
        self.wait_for(lambda: run.latest == 200)
        run.finish(capture.wall())
        self.assertEqual((self.out/'uart_bytes.bin').read_bytes(), b''.join(payloads))
        self.assertEqual(run.reconnects, 1)
        self.assertEqual([x['event'] for x in self.read_events()], ['CAPTURE_START','CAPTURE_END'])
        log = (self.out/'log_v27_gate.log').read_text()
        self.assertIn('### PARTIAL_LINE_HEX ', log)
        self.assertIn('no_reflash=1', log)
        builder.build(self.out)
        infrared.build(self.out)
        self.assertTrue(verifier.verify(self.out)['serial_payload_matches_received_bytes'])

    def test_open_failure_is_not_saved_success_and_existing_run_is_protected(self):
        def fail_open():
            raise OSError('test serial missing')
        run = capture.Recorder(self.out, port_factory=fail_open)
        with self.assertRaises(OSError):
            run.start(capture.wall())
        self.assertEqual(run.state, 'ERROR')
        self.assertIsNotNone(json.loads((self.out/'run_metadata.json').read_text())['acquisition_error'])
        before = (self.out/'manual_events_raw.csv').read_bytes()
        another = capture.Recorder(self.out, port_factory=Port)
        with self.assertRaises(FileExistsError):
            another.start(capture.wall())
        self.assertEqual((self.out/'manual_events_raw.csv').read_bytes(), before)

    def test_passive_parser_needs_no_boot_and_ir_uses_only_manual_phases(self):
        # Includes an actual 96x96 dump format; values are explicitly synthetic.
        rows = []
        pixels = bytes(range(96))
        for index, ms in enumerate((1000,2000,3000), 1):
            wall = f'2026-10-27T12:00:0{index}.000+08:00'
            rows.extend([f'{wall}\tMMT_AI f={index} p=-100 person=0',
                         f'{wall}\tMMT_DEC t={ms} f={index} motion=0 area=0 person=0 alarm_req=0 irhot={index%2}',
                         f'{wall}\tMMT_LP f={index} fw_lp=0 body={200+index}'])
            if index==1:
                rows.append(f'{wall}\tMMT_IMGSTAT f=1 p=-100')
                rows.extend(f'{wall}\tMMT_IMG {y} {pixels.hex()}' for y in range(96))
        (self.out/'log_v27_gate.log').write_text('\n'.join(rows)+'\n', encoding='utf-8')
        (self.out/'uart_bytes.bin').write_bytes(b''.join((row.split('\t',1)[1]+'\n').encode('ascii') for row in rows))
        metadata = dict(mode='formal', observation_started_wall='2026-10-27T12:00:00.000+08:00',
                        observation_ended_wall='2026-10-27T12:00:04.000+08:00')
        (self.out/'run_metadata.json').write_text(json.dumps(metadata))
        with (self.out/'manual_events_raw.csv').open('w', newline='',encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=capture.FIELDS)
            writer.writeheader()
            for event, second in [('EMPTY_CONFIRMED','01.500'),('ENTER','02.500')]:
                writer.writerow(dict(event=event, wall='2026-10-27T12:00:'+second+'+08:00',source='human_key'))
        counts = builder.build(self.out)
        self.assertEqual((counts['dec'],counts['ai_samples'],counts['complete_images']), (3,3,1))
        from PIL import Image
        with Image.open(next((self.out/'frames').glob('*.png'))) as image:
            self.assertEqual(image.tobytes(), pixels*96)
        result = infrared.build(self.out)
        self.assertEqual(result['irhot_by_operator_phase'], {'unlabelled':{'1':1},'empty':{'0':1},'person':{'1':1}})
        with (self.out/'ir_observation.csv').open(encoding='utf-8') as stream:
            self.assertEqual([row['body10'] for row in csv.DictReader(stream)],['201','202','203'])
        with (self.out/'manual_timetable.csv').open(encoding='utf-8') as stream:
            mapped = list(csv.DictReader(stream))
        self.assertEqual([row['event'] for row in mapped], ['EMPTY_CONFIRMED','ENTER'])
        self.assertEqual([row['device_ms_interpolated'] for row in mapped], ['1500','2500'])
        self.assertFalse(json.loads((self.out/'annotation_status.json').read_text())['required_transitions_present'])
        self.assertEqual(verifier.verify(self.out)['exact_pixel_frames'], 1)

    def test_no_empty_dataset_is_manufactured(self):
        with self.assertRaises(FileNotFoundError):
            builder.build(self.out)
        self.assertEqual(list(self.out.iterdir()), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
