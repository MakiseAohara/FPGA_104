#include <stdint.h>
#include "../v30_mot/frame_layout.h"
__declspec(dllexport) uint32_t capture_base(void){return MMT_FB_CAPTURE_BASE;}
__declspec(dllexport) uint32_t bank_stride(void){return MMT_FB_BANK_STRIDE_BYTES;}
__declspec(dllexport) uint32_t row_stride(void){return MMT_FB_ROW_BYTES;}
__declspec(dllexport) uint32_t sample_offset(uint32_t x,uint32_t y){
 return MMT_FB_CAPTURE_BASE-MMT_FB_DDR_BASE+y*MMT_FB_ROW_BYTES+x;
}
