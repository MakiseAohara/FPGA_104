"""Independent row/column oracle for the actual DDR sampling contract.

Each four-byte cell stores uint16 column-cell ID and uint16 row ID. Thus a
horizontal roll into a different row cannot pass by coincident pixel values.
The tested constants come from the actual shared C header via the C compiler.
No board access, original pixels or image transformations are used.
"""
import ctypes as C
import json
from pathlib import Path
import struct
import subprocess

HERE=Path(__file__).absolute().parent
ROOT=HERE.parents[1]
shim=HERE/'frame_layout_test_api.c'
shim.write_text('''#include <stdint.h>
#include "../v30_mot/frame_layout.h"
__declspec(dllexport) uint32_t capture_base(void){return MMT_FB_CAPTURE_BASE;}
__declspec(dllexport) uint32_t bank_stride(void){return MMT_FB_BANK_STRIDE_BYTES;}
__declspec(dllexport) uint32_t row_stride(void){return MMT_FB_ROW_BYTES;}
__declspec(dllexport) uint32_t sample_offset(uint32_t x,uint32_t y){
 return MMT_FB_CAPTURE_BASE-MMT_FB_DDR_BASE+y*MMT_FB_ROW_BYTES+x;
}
''',encoding='ascii')
vcvars=Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
batch=HERE/'build_frame_layout_test.bat'
batch.write_text('@echo off\ncall "'+str(vcvars)+'" >nul 2>&1\nif errorlevel 1 exit /b 1\ncd /d "'+str(HERE)+'"\ncl /nologo /O2 /LD frame_layout_test_api.c /Fe:frame_layout_test.dll > frame_layout_build.log 2>&1\nexit /b %errorlevel%\n',encoding='utf8')
build=subprocess.run([str(batch)],capture_output=True,text=True,errors='replace')
assert build.returncode==0,build.stdout+build.stderr
lib=C.CDLL(str(HERE/'frame_layout_test.dll'))
for name in ('capture_base','bank_stride','row_stride','sample_offset'):
 getattr(lib,name).restype=C.c_uint32
lib.sample_offset.argtypes=[C.c_uint32,C.c_uint32]

# Oracle geometry is deliberately independent of the header's address formula.
# It comes from top-level MIPI / cvo signals: 1920 uint8 Bayer pixels per row.
width,height=1920,1080
payload=bytearray(width*height)
for row in range(height):
 for col_cell in range(width//4):struct.pack_into('<HH',payload,row*width+col_cell*4,col_cell,row)

# Actual reserved bank capacity is established by elaborated RTL hierarchy.
actual_bank1=0x017E9200
old_capture=0x017E9400
new_capture=lib.capture_base()
assert new_capture==actual_bank1
assert lib.row_stride()==width
assert lib.bank_stride()==0x7E9200
old_offset=old_capture-actual_bank1
new_offset=new_capture-actual_bank1
memory=payload+bytes(width)

old_bad_rows=0;new_bad_rows=0
for row in range(height):
 oracle=payload[row*width:(row+1)*width]
 old=memory[old_offset+row*width:old_offset+(row+1)*width]
 address=lib.sample_offset(0,row)-(actual_bank1-0x01000000)
 current=memory[address:address+width]
 old_bad_rows+=old!=oracle
 new_bad_rows+=current!=oracle
assert old_bad_rows==height and new_bad_rows==0

# A row-boundary marker proves exactly where the apparent left/right join is.
row=31
legacy_row=memory[old_offset+row*width:old_offset+(row+1)*width]
before=struct.unpack_from('<HH',legacy_row,1404)
after=struct.unpack_from('<HH',legacy_row,1408)
assert before==(479,row) and after==(0,row+1)
correct_row=memory[new_offset+row*width:new_offset+(row+1)*width]
assert struct.unpack_from('<HH',correct_row,0)==(0,row)
assert struct.unpack_from('<HH',correct_row,1916)==(479,row)

result={'passed':True,'source':'synthetic exact row/column labels; shared C header addresses',
 'rtl_bank_stride_bytes':lib.bank_stride(),'image_row_bytes':lib.row_stride(),
 'old_capture_base':hex(old_capture),'correct_capture_base':hex(new_capture),
 'old_bias_bytes':old_offset,'legacy_join_x':1408,'legacy_join_width_fraction':1408/1920,
 'legacy_rows_failing_full_row_oracle':old_bad_rows,'correct_rows_failing_full_row_oracle':new_bad_rows,
 'before_join_cell':before,'after_join_cell':after,'manual_picture_confirmation':False}
(HERE/'frame_layout_test.json').write_text(json.dumps(result,indent=2),encoding='utf8')
print(json.dumps(result))
