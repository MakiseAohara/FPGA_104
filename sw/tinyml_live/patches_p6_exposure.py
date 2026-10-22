"""P6: lower the sensor exposure back to the commented original.

Current active values (SC431HAI long-exposure registers):
    0x3e00 = 0x01
    0x3e01 = 0xbb
    0x3e02 = 0xf0      -> exposure 0x01BBF0 = 113,648

The line comments next to them record the previous values:
    0x00 / 0xba / 0xd0 -> exposure 0x00BAD0 =  47,824  (2.4x darker)

The measurements showed the model's person score is dominated by overall
brightness: b0m=166 with 21% of pixels clipped at 0xff gives p>0 (false
positive), while b0m=108 with no clipping gives p~-70. So reduce the exposure
back to the recorded original and re-measure.
"""
from pathlib import Path

ROM = Path(r"_p2a\v7_camera_ai\rtl\cam_i2c_ctrl\i2c\i2c_master_reg_rom.v")
ENC = "gb18030"

PAIRS = [
    ("ROM[8'h73] = {16'h3e00,8'h01,1'b0};", "ROM[8'h73] = {16'h3e00,8'h00,1'b0};"),
    ("ROM[8'h74] = {16'h3e01,8'hbb,1'b0};", "ROM[8'h74] = {16'h3e01,8'hba,1'b0};"),
    ("ROM[8'h75] = {16'h3e02,8'hf0,1'b0};", "ROM[8'h75] = {16'h3e02,8'hd0,1'b0};"),
]


def main():
    s = ROM.read_bytes().decode(ENC)
    for old, new in PAIRS:
        if old not in s:
            raise SystemExit("anchor not found: %r" % old)
        s = s.replace(old, new, 1)
    ROM.write_bytes(s.encode(ENC))
    print("exposure lowered: 0x01BBF0 -> 0x00BAD0 (113648 -> 47824, 2.38x darker)")
    for line in s.splitlines():
        if "3e00" in line or "3e01" in line or "3e02" in line:
            print("   ", line.strip())


if __name__ == "__main__":
    main()
