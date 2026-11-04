#ifndef HTTP_APP_H
#define HTTP_APP_H
/* http_app.h - firmware HTTP responses: page / status JSON / 96x96 PNG */
#include <stdint.h>
#include <string.h>

typedef struct {
   const char* status_json;
   const char* events_json;
   const uint8_t* thumb;
   int thumb_w, thumb_h;
   const char* tracking_json;
   uint32_t frame_id;
} http_state_t;

int http_get(void* user, const char* path, const uint8_t** body, int* blen, const char** ctype);
int png_gray(const uint8_t* pix, int w, int h, uint8_t* out, int cap);
void http_set_state(const http_state_t* st);

#ifdef HTTP_APP_IMPL
#include "page_html.h"
#include "preview_packet.h"

static http_state_t g_http;
static uint8_t g_png[16384];
#define HTTP_SNAPSHOT_SLOTS 8
static uint8_t g_view_pixels[HTTP_SNAPSHOT_SLOTS][96*96];
static int g_view_valid=0;
static uint32_t g_view_seq[HTTP_SNAPSHOT_SLOTS];
static int g_view_slot=0;
static char g_view_state[12288];
static char g_snapshot_info[128];
static uint8_t g_preview_packet[32768];

static uint32_t http_frame_id(const char* json) {
   const char* p=json?strstr(json,"\"frame_id\":"):0;uint32_t n=0;
   if(!p)return 0;p+=11;
   while(*p==' ')p++;
   while(*p>='0' && *p<='9')n=n*10u+(uint32_t)(*p++-'0');
   return n;
}
static char* http_uint(char* p,uint32_t n) {
   char digits[10];int count=0;
   do{digits[count++]=(char)('0'+n%10u);n/=10u;}while(n);
   while(count)*p++=digits[--count];return p;
}

void http_set_state(const http_state_t* st) { g_http = *st; }

static uint32_t png_adler(const uint8_t* d, int n)
{
   uint32_t a = 1, b = 0; int i;
   for (i = 0; i < n; ++i) { a = (a + d[i]) % 65521u; b = (b + a) % 65521u; }
   return (b << 16) | a;
}
static void put32(uint8_t* p, uint32_t v)
{ p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v; }
static uint32_t crc32_of(const uint8_t* d, int n)
{
   uint32_t c = 0xFFFFFFFFu; int i, k;
   for (i = 0; i < n; ++i) {
      c ^= d[i];
      for (k = 0; k < 8; ++k) c = (c & 1u) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
   }
   return ~c;
}
static int png_chunk(uint8_t* out, int o, const char* type, const uint8_t* data, int len)
{
   int i;
   put32(out + o, (uint32_t)len);
   for (i = 0; i < 4; ++i) out[o + 4 + i] = (uint8_t)type[i];
   for (i = 0; i < len; ++i) out[o + 8 + i] = data[i];
   put32(out + o + 8 + len, crc32_of(out + o + 4, len + 4));
   return o + 12 + len;
}
int png_gray(const uint8_t* pix, int w, int h, uint8_t* out, int cap)
{
   int stride = w + 1, raw = (w + 1) * h, o = 8, i;
   int nblk = (raw + 65534) / 65535;
   int need = 8 + 25 + 12 + (2 + raw + 5 * nblk) + 12;
   static const uint8_t sig[8] = {0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A};
   uint8_t ihdr[13];
   if (cap < need) return 0;
   for (i = 0; i < 8; ++i) out[i] = sig[i];
   put32(ihdr, (uint32_t)w); put32(ihdr + 4, (uint32_t)h);
   ihdr[8] = 8; ihdr[9] = 0; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
   o = png_chunk(out, o, "IHDR", ihdr, 13);
   {
      int z = 2, src = 0;
      uint32_t ad_a = 1, ad_b = 0;
      uint8_t* q = out + o + 8;
      q[0] = 0x78; q[1] = 0x01;
      while (src < raw) {
         int left = raw - src;
         int len = (left > 65535) ? 65535 : left;
         int last = (src + len >= raw) ? 1 : 0;
         int k;
         q[z++] = (uint8_t)last;
         q[z++] = (uint8_t)(len & 0xFF); q[z++] = (uint8_t)(len >> 8);
         q[z++] = (uint8_t)((~len) & 0xFF); q[z++] = (uint8_t)(((~len) >> 8) & 0xFF);
         for (k = 0; k < len; ++k) {
            int idx = src + k, col = idx % stride, row = idx / stride;
            uint8_t byte = (col == 0) ? 0 : pix[row * w + col - 1];
            q[z++] = byte;
            ad_a = (ad_a + byte) % 65521u;
            ad_b = (ad_b + ad_a) % 65521u;
         }
         src += len;
      }
      put32(q + z, (ad_b << 16) | ad_a);
      z += 4;
      o = png_chunk(out, o, "IDAT", q, z);
   }
   o = png_chunk(out, o, "IEND", 0, 0);
   return o;
}
int http_get(void* user, const char* path, const uint8_t** body, int* blen, const char** ctype)
{
   http_state_t* st = (http_state_t*)user;
   int i = 0;
   if (path[0] != 0x2F) return 0;
   if (path[1] == 0) { *body = page_html; *blen = PAGE_HTML_LEN; *ctype = "text/html; charset=utf-8"; return 1; }
   if(!strcmp(path,"/api/preview")) {
      const uint8_t* json;const char* json_type;int json_len,n;
      if(!http_get(user,"/api/state",&json,&json_len,&json_type) || !g_view_valid)return 0;
      n=preview_packet_write((const char*)json,json_len,g_view_pixels[g_view_slot],96,96,
                             g_view_seq[g_view_slot],g_preview_packet,(int)sizeof(g_preview_packet));
      if(!n)return 0;
      *body=g_preview_packet;*blen=n;*ctype="application/x-mmt-preview";return 1;
   }
   if (!strcmp(path,"/api/state") || !strcmp(path,"/api/status") || !strcmp(path,"/api/events")) {
      const char* s = !strcmp(path,"/api/events") ? st->events_json : st->status_json;
      if (!s) return 0;
      while (s[i]) i++;
      if (strcmp(path,"/api/events") && st->tracking_json && st->tracking_json[0]=='{' && i>0 && s[i-1]=='}') {
         int n=(int)strlen(st->tracking_json);
         if(i+n+13>=(int)sizeof(g_view_state))return 0;
         memcpy(g_view_state,s,i-1);
         memcpy(g_view_state+i-1,",\"tracking\":",12);
         memcpy(g_view_state+i+11,st->tracking_json,n);
         g_view_state[i+11+n]='}';g_view_state[i+12+n]=0;
         s=g_view_state;i=i+12+n;
      }
      // Retain eight immutable images: PC mirroring and a board browser may
      // interleave their state/image requests while the MOT frame advances.
      if(strcmp(path,"/api/events") && st->thumb && st->thumb_w==96 && st->thumb_h==96) {
         uint32_t seq=http_frame_id(st->tracking_json);int slot=-1,k;
         for(k=0;k<g_view_valid;k++)if(g_view_seq[k]==seq)slot=k;
         if(slot<0){slot=g_view_valid<HTTP_SNAPSHOT_SLOTS?g_view_valid++:(g_view_slot+1)%HTTP_SNAPSHOT_SLOTS;
            memcpy(g_view_pixels[slot],st->thumb,sizeof(g_view_pixels[slot]));g_view_seq[slot]=seq;}
         g_view_slot=slot;
      }
      *body = (const uint8_t*)s; *blen = i; *ctype = "application/json; charset=utf-8";
      return 1;
   }
   if(!strcmp(path,"/api/snapshot")) {
      char* p=g_snapshot_info;
      memcpy(p,"{\"frame_id\":",12);p+=12;p=http_uint(p,g_view_seq[g_view_slot]);
      memcpy(p,",\"current\":",11);p+=11;p=http_uint(p,st->frame_id);
      memcpy(p,",\"valid\":",9);p+=9;*p++=g_view_valid?'1':'0';*p++='}';*p=0;
      *body=(const uint8_t*)g_snapshot_info;*blen=(int)(p-g_snapshot_info);*ctype="application/json";return 1;
   }
   if (!strcmp(path,"/frame.png") || !strncmp(path,"/frame.png?",11)) {
      int slot=g_view_slot;
      if(!strncmp(path,"/frame.png?seq=",15)) {
         const char* p=path+15;uint32_t seq=0;
         if(!*p)return 0;
         while(*p) {if(*p<'0'||*p>'9')return 0;seq=seq*10+(unsigned)(*p++-'0');}
         int k;slot=-1;
         for(k=0;k<g_view_valid;k++)if(seq==g_view_seq[k])slot=k;
         if(slot<0)return 0;
      }
      int n = png_gray(g_view_valid ? g_view_pixels[slot] : st->thumb, st->thumb_w, st->thumb_h, g_png, (int)sizeof(g_png));
      if (n <= 0) return 0;
      *body = g_png; *blen = n; *ctype = "image/png";
      return 1;
   }
   return 0;
}
#endif
#endif /* HTTP_APP_H */
