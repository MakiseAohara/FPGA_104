"""Offline protocol tests; synthetic data stays in a temporary directory."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from PIL import Image

HERE=Path(__file__).resolve().parent
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

thumbs=load('derive_thumbs')
capture=load('capture_v28')


class Checks(unittest.TestCase):
    def test_thumb_without_dec_survives_a_reconnect(self):
        bodies=['MMT_LIVE_BOOT v28 test','### RECONNECTED count=1 no_reflash=1',
                'MMT_THUMB t=2000 f=8 alarm=0 p=-128 '+'00'*2304]
        with tempfile.TemporaryDirectory(prefix='v28_orphan_') as folder:
            root=Path(folder)
            (root/'log_v28_gate.log').write_text(''.join('2026-10-27T18:00:00.000+08:00\t'+b+'\n' for b in bodies),encoding='utf-8',newline='\n')
            result=thumbs.decode(root)
            self.assertEqual(result['thumbnail_lines'],1);self.assertEqual(result['missing_dec'],1)
            self.assertTrue((root/'thumbs/thumb_2000_a0_p-128.png').exists())

    def test_long_line_is_fully_buffered(self):
        line='MMT_THUMB t=120000 f=0 alarm=1 p=-61 '+'ab'*2304
        data=(line+'\n\r').encode()
        class Port:
            def __init__(self):self.data=data
            @property
            def in_waiting(self):return min(113,len(self.data))
            def read(self,n):value,self.data=self.data[:n],self.data[n:];return value
        with tempfile.TemporaryDirectory(prefix='v28_protocol_') as folder:
            cap=capture.Capture(Path(folder));reader=capture.loader.Reader(Port(),cap)
            found=None
            for _ in range(100):
                result=reader.next_line()
                if result is not None:found=result;break
            self.assertEqual(found,line);self.assertEqual(cap.thumbs,1);self.assertEqual(cap.invalid_thumbs,0)
            cap.fh.close();cap.uart_fh.close()

    def test_complete_thumb_matches_original_and_invalid_is_not_invented(self):
        raw=bytes((i*37+113)%256 for i in range(9216))
        small=bytes(sum(raw[(y*2+dy)*96+x*2+dx] for dy,dx in [(0,0),(0,1),(1,0),(1,1)])//4 for y in range(48) for x in range(48))
        bodies=['MMT_LIVE_BOOT v28 test','MMT_DEC t=1000 f=4 alarm_req=1','MMT_IMGSTAT f=4 p=-61']
        bodies.extend('MMT_IMG %02d %s'%(y,raw[y*96:(y+1)*96].hex()) for y in range(96))
        bodies.extend(['MMT_THUMB t=1000 f=4 alarm=1 p=-61 '+small.hex(),'MMT_THUMB t=2000 f=8 alarm=0 p=-128 ff'])
        with tempfile.TemporaryDirectory(prefix='v28_decode_') as folder:
            root=Path(folder)
            (root/'log_v28_gate.log').write_text(''.join('2026-10-27T18:00:00.000+08:00\t'+b+'\n' for b in bodies),encoding='utf-8',newline='\n')
            result=thumbs.decode(root)
            self.assertEqual(result['thumbnail_lines'],1);self.assertEqual(len(result['invalid_lines']),1)
            self.assertEqual(result['matched_96x96_averages'],1)
            with Image.open(root/'thumbs/thumb_1000_a1_p-61.png') as image:
                self.assertEqual(image.size,(192,192));self.assertEqual(image.resize((48,48),Image.Resampling.NEAREST).tobytes(),small)


if __name__=='__main__':unittest.main(verbosity=2)
