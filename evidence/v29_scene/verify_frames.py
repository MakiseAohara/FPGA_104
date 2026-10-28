"""Verify every valid scene PNG against strict raw-byte log decoding."""
from pathlib import Path
import json
import numpy as np
from PIL import Image
from export_scene import parse,HERE

def main():
    frames,_=parse()
    for row in frames:
        path=HERE/'frames'/f"{row['stage']}_t{row['t']:07d}_p{row['p']}.png"
        with Image.open(path) as png:
            assert png.size==(96,96) and png.mode=='L' and png.tobytes()==row['pixels'].tobytes(),path.name
    assert len(list((HERE/'frames').glob('*.png')))==len(frames)
    print(json.dumps(dict(verified_raw_byte_pngs=len(frames),conversion='u unchanged; no +128 or int8 flip')))
    return 0
if __name__=='__main__':raise SystemExit(main())
