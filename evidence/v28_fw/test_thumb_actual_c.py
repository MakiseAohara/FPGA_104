"""Exercise the actual C thumb function, including signed-byte boundaries."""
import json
import struct
from pathlib import Path
import replay_v28 as replay

source=(replay.HERE/'main_live28.cc').read_text(encoding='utf-8')
code='''#include <stdint.h>
#include <stdarg.h>
#define THUMB_W 48
static const char HEXD[]="0123456789abcdef";
static uint32_t g_dec_ms=123456;
static int alarm_on=1;
volatile int meta[4];
volatile char result[4609];
int8_t image_input[9216];
static void bsp_printf(const char *fmt,...){
 va_list ap;va_start(ap,fmt);for(int i=0;i<4;i++)meta[i]=va_arg(ap,int);
 const char* p=va_arg(ap,const char*);for(int i=0;i<4609;i++)result[i]=p[i];va_end(ap);
}
'''+replay.actual.function(source,'dump_thumb')+'''
void replay_frame(void){dump_thumb(image_input,92,-61);}
'''
u,symbols=replay.compile_code(code,replay.WORK/'thumb','thumb')
pixels=bytes((i*37+113)%256 for i in range(9216))
u.mem_write(symbols['image_input'],pixels)
u.reg_write(replay.UC_RISCV_REG_RA,0x8fff0)
u.emu_start(symbols['replay_frame'],0x8fff0,count=2000000)
assert u.reg_read(replay.UC_RISCV_REG_PC)==0x8fff0
raw=bytes(u.mem_read(symbols['result'],4609))
assert raw[-1]==0 and len(raw[:-1])==4608
actual=bytes.fromhex(raw[:-1].decode('ascii'))
expected=bytes(sum(pixels[(2*y+dy)*96+2*x+dx] for dy,dx in [(0,0),(0,1),(1,0),(1,1)])//4 for y in range(48) for x in range(48))
assert actual==expected
assert struct.unpack('<4i',u.mem_read(symbols['meta'],16))==(123456,92,1,-61)
result=dict(actual_c_function=True,grayscale_view='uint8 bytes, identical view to MMT_IMG',pixels_compared=2304,hex_characters=4608,header_arguments_match=True,signed_boundary_test=True)
(replay.HERE/'thumb_c_checks.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(result))
