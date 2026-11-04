#ifndef MMT_PREVIEW_PACKET_H
#define MMT_PREVIEW_PACKET_H
/* One lossless image and its tracking snapshot per HTTP response.
 * MMTP, version:u8, Gray8:u8, header_size:u16, JSON_size:u32,
 * width:u16, height:u16, capture_id:u32, pixel_bytes:u32. All integers BE. */
#include <stdint.h>
#include <string.h>
#define PV_HEADER_SIZE 24
static void pv_put16(uint8_t* p,uint16_t v){p[0]=(uint8_t)(v>>8);p[1]=(uint8_t)v;}
static void pv_put32(uint8_t* p,uint32_t v){p[0]=(uint8_t)(v>>24);p[1]=(uint8_t)(v>>16);p[2]=(uint8_t)(v>>8);p[3]=(uint8_t)v;}
static int preview_packet_write(const char* json,int json_len,const uint8_t* gray,
                               int width,int height,uint32_t seq,uint8_t* out,int cap){
 int pixels,total;
 if(!json || !gray || !out || width<1 || height<1 || width>512 || height>512 || json_len<2 || json_len>12288)return 0;
 pixels=width*height;total=PV_HEADER_SIZE+json_len+pixels;
 if(cap<total)return 0;
 memcpy(out,"MMTP",4);out[4]=1;out[5]=1;pv_put16(out+6,PV_HEADER_SIZE);
 pv_put32(out+8,(uint32_t)json_len);pv_put16(out+12,(uint16_t)width);pv_put16(out+14,(uint16_t)height);
 pv_put32(out+16,seq);pv_put32(out+20,(uint32_t)pixels);
 memcpy(out+PV_HEADER_SIZE,json,json_len);memcpy(out+PV_HEADER_SIZE+json_len,gray,pixels);
 return total;
}
#endif
