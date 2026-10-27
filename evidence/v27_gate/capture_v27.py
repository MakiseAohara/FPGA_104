"""Operator controlled, receive-only UART capture. No scheduled action events.

JSON lines on stdin: START / LABEL / STOP / QUIT, with the operator's wall time.
JSON state on stdout. Simulator support is restricted to a separate test folder.
No serial port is opened, and no evidence is created, before START.
"""
import argparse
import csv
import datetime as dt
import json
import os
from pathlib import Path
import queue
import re
import sys
import threading
import time

sys.dont_write_bytecode = True
TZ = dt.timezone(dt.timedelta(hours=8))
EVENTS = {'ENTER', 'LEAVE', 'CHAIR_START', 'CHAIR_END', 'HEAD_DOWN_START',
          'HEAD_DOWN_END', 'SIDE_START', 'SIDE_END', 'EMPTY_CONFIRMED',
          'ALARM_CONFIRMED', 'RELEASE_CONFIRMED'}
FIELDS = ['event', 'wall', 'elapsed_s', 'device_ms_latest', 'source']


def wall():
    return dt.datetime.now(TZ).isoformat(timespec='milliseconds')


def stamp(value):
    parsed = dt.datetime.fromisoformat(value)
    if parsed.utcoffset() != dt.timedelta(hours=8):
        raise ValueError('Operator timestamp must explicitly use UTC+08:00')
    return parsed


class Recorder:
    def __init__(self, out, port='COM15', port_factory=None, mode='formal'):
        self.out, self.port_name, self.port_factory, self.mode = Path(out), port, port_factory, mode
        self.lock = threading.RLock()
        self.stop_signal = threading.Event()
        self.thread = self.port = None
        self.log_file = self.byte_file = self.event_file = None
        self.t0 = self.ended = self.error = None
        self.state = 'IDLE'
        self.latest = None
        self.lines = self.gaps = self.reconnects = self.event_count = 0
        self.last_rx = self.last_gap = time.monotonic()
        self.recent = []
        self.boot_lines = []
        self.reader_tail = b''
        self.serial_opened_wall = None

    def status(self):
        with self.lock:
            return dict(state=self.state, t0=self.t0, ended_wall=self.ended,
                        device_ms=self.latest, serial_lines=self.lines,
                        gaps=self.gaps, reconnects=self.reconnects,
                        events=self.event_count, recent=list(self.recent), error=self.error,
                        mode=self.mode, serial_opened_wall=self.serial_opened_wall)

    def log(self, text, received_wall=None):
        with self.lock:
            self.log_file.write((received_wall or wall()) + '\t' + text + '\n')
            self.log_file.flush()

    def event(self, name, operator_wall, source):
        elapsed = (stamp(operator_wall) - stamp(self.t0)).total_seconds()
        if elapsed < 0:
            raise ValueError('Operator event precedes T0')
        row = dict(event=name, wall=operator_wall, elapsed_s=f'{elapsed:.3f}',
                   device_ms_latest=self.latest, source=source)
        self.events_writer.writerow(row)
        self.event_file.flush()
        os.fsync(self.event_file.fileno())
        self.event_count += 1
        self.recent = (self.recent + [row])[-5:]
        self.log('### HUMAN_EVENT ' + json.dumps(row, ensure_ascii=False))

    def start(self, operator_wall, source='human_button'):
        with self.lock:
            if self.state != 'IDLE':
                raise RuntimeError('This run can be started only once')
            stamp(operator_wall)
            self.out.mkdir(parents=True, exist_ok=True)
            targets = ['log_v27_gate.log', 'uart_bytes.bin', 'manual_events_raw.csv', 'run_metadata.json']
            if any((self.out / name).exists() for name in targets):
                raise FileExistsError('Existing capture files are protected; use a new run directory')
            self.log_file = (self.out / targets[0]).open('x', encoding='utf-8', newline='\n')
            self.byte_file = (self.out / targets[1]).open('xb')
            self.event_file = (self.out / targets[2]).open('x', encoding='utf-8', newline='')
            self.events_writer = csv.DictWriter(self.event_file, fieldnames=FIELDS)
            self.events_writer.writeheader()
            self.t0 = operator_wall
            self.state = 'STARTING'
            self.event('CAPTURE_START', operator_wall, source)
            self.log('### CAPTURE_START t0=' + self.t0 + ' mode=' + self.mode + ' operator_controlled=1')
        try:
            self.port = self.open_port()
            self.serial_opened_wall = wall()
            self.last_rx = self.last_gap = time.monotonic()
            self.state = 'RECORDING'
            self.thread = threading.Thread(target=self.receive, name='v27-uart', daemon=True)
            self.thread.start()
        except Exception as exc:
            self.error = repr(exc)
            self.finish(None, 'serial_open_failed')
            raise

    def open_port(self):
        if self.port_factory:
            return self.port_factory()
        sys.path.append(r'D:\Efinity\2026.1\python311\Lib\site-packages')
        import serial
        port = serial.Serial(port=None, baudrate=115200, timeout=0.05, write_timeout=1)
        # Inactive line state is selected before opening; no reset pulse.
        port.dtr = False
        port.rts = False
        port.port = self.port_name
        try:
            port.open()
        except BaseException:
            port.close()
            raise
        return port

    def label(self, event, operator_wall, source='human_key'):
        with self.lock:
            if self.state != 'RECORDING':
                raise RuntimeError('Labels are accepted only during recording')
            if event not in EVENTS:
                raise ValueError('Unknown action event')
            if source not in ('human_key', 'human_button'):
                raise ValueError('An action event must come from an operator input')
            self.event(event, operator_wall, source)

    def gap_check(self):
        with self.lock:
            now = time.monotonic()
            if now - self.last_rx > 5 and now - self.last_gap >= 5:
                self.gaps += 1
                self.log(f'### GAP idle_s={now-self.last_rx:.3f} device_ms={self.latest}')
                self.last_gap = now

    def receive(self):
        buf = b''
        try:
            while not self.stop_signal.is_set():
                try:
                    data = self.port.read(min(4096, max(1, self.port.in_waiting)))
                except Exception as exc:
                    self.log('### RECONNECT_TRY error=' + repr(exc))
                    if buf:
                        self.log('### PARTIAL_LINE_HEX ' + buf.hex())
                        buf = b''
                    self.port.close()
                    deadline = time.monotonic() + 30
                    while not self.stop_signal.is_set():
                        self.gap_check()
                        if time.monotonic() >= deadline:
                            raise RuntimeError('UART unavailable for 30 s; no reflash during capture')
                        try:
                            self.port = self.open_port()
                            self.reconnects += 1
                            self.log(f'### RECONNECTED count={self.reconnects} no_reflash=1')
                            break
                        except Exception:
                            self.stop_signal.wait(0.5)
                    continue
                if data:
                    self.byte_file.write(data)
                    self.byte_file.flush()
                    self.last_rx = self.last_gap = time.monotonic()
                    buf += data
                    while b'\n' in buf:
                        raw, buf = buf.split(b'\n', 1)
                        text = raw.strip(b'\r').decode('ascii', errors='replace')
                        self.log(text)
                        self.lines += 1
                        match = re.search(r'^MMT_DEC t=(\d+)', text)
                        if match:
                            value = int(match[1])
                            if self.latest is not None and value < self.latest:
                                raise RuntimeError('Device clock moved backwards during capture')
                            self.latest = value
                        if text.startswith(('MMT_LIVE_BOOT', 'MMT_CAM')):
                            self.boot_lines.append(text)
                        if text.startswith(('MMT_DDR_FAIL', 'MMT_AI_FAIL', 'MMT_LOAD_FAIL', 'MMT_LOADER_READY')):
                            raise RuntimeError('Unexpected board state: ' + text)
                else:
                    self.gap_check()
        except Exception as exc:
            self.error = repr(exc)
            self.log('### ACQUISITION_ERROR ' + self.error)
            self.stop_signal.set()
        finally:
            self.reader_tail = buf

    def finish(self, operator_wall, source='human_button'):
        if self.state not in ('RECORDING', 'STARTING'):
            return
        self.stop_signal.set()
        if self.thread:
            self.thread.join(timeout=3)
            if self.thread.is_alive():
                raise RuntimeError('UART thread did not stop; files kept open')
        with self.lock:
            if operator_wall is not None:
                self.event('CAPTURE_END', operator_wall, source)
            self.ended = operator_wall or wall()
            if self.reader_tail:
                self.log('### FINAL_PARTIAL_LINE_HEX ' + self.reader_tail.hex())
            if self.port:
                self.port.close()
            self.log(f'### CAPTURE_END gaps={self.gaps} reconnects={self.reconnects} error={self.error}')
            self.state = 'ERROR' if self.error else 'SAVED'
            metadata = dict(self.status(), observation_started_wall=self.t0,
                            observation_ended_wall=self.ended, started_wall=self.t0,
                            ended_wall=wall(), port=self.port_name, baudrate=115200,
                            firmware_crc32='B7CCB8D0', firmware_bytes=477722,
                            firmware_modified=False, camera_commands_sent=False,
                            exposure_modified=False, reset_after_firmware_upload=False,
                            action_prompts=False, enter_leave_markers='actual_operator_input_only',
                            acquisition_error=self.error, boot_lines=self.boot_lines,
                            automatic_action_events=False, simulation_only=self.port_factory is not None)
            (self.out / 'run_metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
            for handle in (self.log_file, self.byte_file, self.event_file):
                handle.close()


class TestPort:
    """Explicitly labelled simulation, for tests outside evidence/ only."""
    in_waiting = 1
    def __init__(self):
        self.n = 0
    def read(self, size):
        time.sleep(0.02)
        self.n += 1
        return (f'MMT_DEC t={self.n*20} f={self.n} motion=0 area=0 person=0 alarm_req=0 irhot=0\n\r').encode()
    def close(self):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--port', default='COM15')
    parser.add_argument('--mode', choices=['formal', 'smoke'], default='formal')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test and 'evidence' in [p.lower() for p in args.out.resolve().parts]:
        parser.error('Simulated serial logs must be outside evidence/')
    capture = Recorder(args.out, args.port, TestPort if args.self_test else None, args.mode)
    commands = queue.Queue()
    def stdin_reader():
        for line in sys.stdin:
            try:
                commands.put(json.loads(line))
            except ValueError:
                commands.put({'command': 'INVALID'})
        commands.put({'command': 'EOF'})
    threading.Thread(target=stdin_reader, daemon=True).start()
    last_state = None
    try:
        while True:
            try:
                packet = commands.get(timeout=0.1)
            except queue.Empty:
                packet = None
            command_error = None
            if packet:
                try:
                    command = packet['command']
                    if command == 'START':
                        capture.start(packet['wall'], packet.get('source', 'human_button'))
                    elif command == 'LABEL':
                        capture.label(packet['event'], packet['wall'], packet.get('source', 'human_key'))
                    elif command == 'STOP':
                        capture.finish(packet['wall'], packet.get('source', 'human_button'))
                    elif command in ('QUIT', 'EOF'):
                        if capture.state == 'RECORDING':
                            capture.error = 'Panel disconnected before an operator STOP'
                            capture.finish(None, 'panel_disconnected')
                        break
                    else:
                        raise ValueError('Unknown command')
                except Exception as exc:
                    command_error = repr(exc)
            if capture.state == 'RECORDING' and capture.stop_signal.is_set():
                capture.finish(None, 'serial_error')
            state = capture.status()
            if command_error:
                state['command_error'] = command_error
            if state != last_state or packet:
                print(json.dumps(state, ensure_ascii=False), flush=True)
                last_state = state
    finally:
        if capture.state in ('RECORDING', 'STARTING'):
            capture.error = capture.error or 'Backend terminated without operator STOP'
            capture.finish(None, 'backend_exit')


if __name__ == '__main__':
    main()
