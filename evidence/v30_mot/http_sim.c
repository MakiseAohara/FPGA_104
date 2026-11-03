#include <stdio.h>
#include <string.h>
#define HTTP_APP_IMPL
#include "http_app.h"

static uint8_t thumb[96 * 96];
static uint8_t png[16384];

int main(void)
{
   int i, j, n;
   static http_state_t st;
   static const uint8_t* body;
   static int blen;
   static const char* ctype;
   FILE* f;

   for (j = 0; j < 96; ++j)
      for (i = 0; i < 96; ++i)
         thumb[j * 96 + i] = (uint8_t)((i * 2 + j) & 0xFF);

   n = png_gray(thumb, 96, 96, png, (int)sizeof(png));
   printf("png bytes=%d (expect ~%d)\n", n, 96 * 97 + 100);
   if (n <= 0) { printf("PNG FAIL\n"); return 1; }
   f = fopen("out_frame.png", "wb");
   fwrite(png, 1, n, f); fclose(f);

   st.thumb = thumb; st.thumb_w = 96; st.thumb_h = 96;
   st.status_json = "{\"obs\":1,\"alarm\":0}";
   st.events_json = "[]";
   http_set_state(&st);

   printf("GET /      -> %d ", http_get(&st, "/", &body, &blen, &ctype));
   printf("len=%d type=%s head=\"%.15s\"\n", blen, ctype, (const char*)body);
   printf("GET status -> %d ", http_get(&st, "/api/status", &body, &blen, &ctype));
   printf("len=%d %.*s\n", blen, blen, (const char*)body);
   printf("GET frame  -> %d ", http_get(&st, "/frame.png", &body, &blen, &ctype));
   printf("len=%d type=%s\n", blen, ctype);
   printf("GET nope   -> %d (expect 0)\n", http_get(&st, "/nope", &body, &blen, &ctype));
   return 0;
}