#ifndef HTTP_APP_H
#define HTTP_APP_H
/* http_app.h - firmware HTTP responses: page / status JSON / 96x96 PNG */
#include <stdint.h>

typedef struct {
   const char* status_json;
   const char* events_json;
   const uint8_t* thumb;
   int thumb_w, thumb_h;
} http_state_t;

int http_get(void* user, const char* path, const uint8_t** body, int* blen, const char** ctype);
int png_gray(const uint8_t* pix, int w, int h, uint8_t* out, int cap);
void http_set_state(const http_state_t* st);

#ifdef HTTP_APP_IMPL
#include "page_html.h"

static http_state_t g_http;
static uint8_t g_png[16384];

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
   if (path[1] == 0x61 && path[2] == 0x70 && path[3] == 0x69) {
      const char* s = (path[5] == 0x65 && path[6] == 0x76) ? st->events_json : st->status_json;
      if (!s) return 0;
      while (s[i]) i++;
      *body = (const uint8_t*)s; *blen = i; *ctype = "application/json; charset=utf-8";
      return 1;
   }
   if (path[1] == 0x66 && path[2] == 0x72) {
      int n = png_gray(st->thumb, st->thumb_w, st->thumb_h, g_png, (int)sizeof(g_png));
      if (n <= 0) return 0;
      *body = g_png; *blen = n; *ctype = "image/png";
      return 1;
   }
   return 0;
}
#endif
#endif /* HTTP_APP_H */
