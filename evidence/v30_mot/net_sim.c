#include <stdio.h>
#include <string.h>
#include "net_core.h"
#include "net_core_impl.h"

static const char* g_page = "<!doctype html><meta charset=utf-8><title>MMT</title><h1>hello</h1>";

static int my_get(void* u, const char* path, const uint8_t** body, int* blen, const char** ctype)
{
   (void)u;
   if (strcmp(path, "/") == 0) {
      *body = (const uint8_t*)g_page; *blen = (int)strlen(g_page); *ctype = "text/html; charset=utf-8";
      return 1;
   }
   return 0;
}

static int csum_ok(const uint8_t* ip)
{
   int ihl = (ip[0] & 0x0F) * 4, i;
   uint32_t s = 0;
   for (i = 0; i < ihl; i += 2) s += ((uint32_t)ip[i] << 8) | ip[i + 1];
   while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
   return (s & 0xFFFFu) == 0xFFFFu;
}

static int tcp_csum_ok(const uint8_t* f, int len)
{
   const uint8_t* ip = f + 14;
   const uint8_t* tcp = f + 34;
   int ihl = (ip[0] & 0x0F) * 4;
   int tlen = len - 14 - ihl;
   uint8_t buf[1600];
   uint32_t s = 0;
   int i;
   uint16_t want = (uint16_t)((tcp[16] << 8) | tcp[17]);
   memcpy(buf, tcp, tlen);
   buf[16] = 0; buf[17] = 0;
   for (i = 0; i < 4; i += 2) s += ((uint32_t)ip[12 + i] << 8) | ip[13 + i];
   for (i = 0; i < 4; i += 2) s += ((uint32_t)ip[16 + i] << 8) | ip[17 + i];
   s += 6u; s += (uint32_t)tlen;
   for (i = 0; i < tlen; i += 2) {
      uint32_t w = (uint32_t)buf[i] << 8;
      if (i + 1 < tlen) w |= buf[i + 1];
      s += w;
   }
   while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
   return (uint16_t)(~s & 0xFFFFu) == want;
}

static int build_tcp(uint8_t* f, int sport, int dport, uint32_t seq, uint32_t ack, uint8_t flags,
                     const char* data)
{
   int dlen = data ? (int)strlen(data) : 0;
   int i, total = 20 + 20 + dlen;
   uint8_t* ip = f + 14;
   uint8_t* tcp = f + 34;
   uint32_t s = 0;
   static const uint8_t dm[6] = {0x00,0x0a,0x35,0x01,0xfe,0xc0};
   static const uint8_t sm[6] = {0x11,0x22,0x33,0x44,0x55,0x66};
   static const uint8_t sip[4] = {169,254,47,61};
   static const uint8_t dip[4] = {169,254,47,62};
   memcpy(f, dm, 6); memcpy(f + 6, sm, 6); f[12] = 0x08; f[13] = 0x00;
   ip[0] = 0x45; ip[1] = 0; ip[2] = total >> 8; ip[3] = total & 0xFF;
   ip[4] = ip[5] = ip[6] = ip[7] = 0; ip[8] = 64; ip[9] = 6; ip[10] = ip[11] = 0;
   memcpy(ip + 12, sip, 4); memcpy(ip + 16, dip, 4);
   tcp[0] = sport >> 8; tcp[1] = sport & 0xFF;
   tcp[2] = dport >> 8; tcp[3] = dport & 0xFF;
   tcp[4] = seq >> 24; tcp[5] = seq >> 16; tcp[6] = seq >> 8; tcp[7] = seq;
   tcp[8] = ack >> 24; tcp[9] = ack >> 16; tcp[10] = ack >> 8; tcp[11] = ack;
   tcp[12] = 0x50; tcp[13] = flags; tcp[14] = 0x20; tcp[15] = 0x00;
   tcp[16] = tcp[17] = tcp[18] = tcp[19] = 0;
   if (dlen) memcpy(tcp + 20, data, dlen);
   for (i = 0; i < 4; i += 2) s += ((uint32_t)sip[i] << 8) | sip[i + 1];
   for (i = 0; i < 4; i += 2) s += ((uint32_t)dip[i] << 8) | dip[i + 1];
   s += 6u; s += (uint32_t)(20 + dlen);
   for (i = 0; i < 20 + dlen; i += 2) {
      uint32_t w = (uint32_t)tcp[i] << 8;
      if (i + 1 < 20 + dlen) w |= tcp[i + 1];
      s += w;
   }
   while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
   {
      uint16_t c = (uint16_t)(~s & 0xFFFFu);
      tcp[16] = c >> 8; tcp[17] = c & 0xFF;
   }
   {
      uint32_t s2 = 0;
      for (i = 0; i < 20; i += 2) s2 += ((uint32_t)ip[i] << 8) | ip[i + 1];
      while (s2 >> 16) s2 = (s2 & 0xFFFFu) + (s2 >> 16);
      {
         uint16_t c = (uint16_t)(~s2 & 0xFFFFu);
         ip[10] = c >> 8; ip[11] = c & 0xFF;
      }
   }
   return 14 + total;
}

int main(void)
{
   static net_t net;
   static uint8_t in[1600], out[1600];
   net_cfg_t cfg;
   int n, fails = 0;

   memset(&cfg, 0, sizeof(cfg));
   cfg.mac[0]=0x00; cfg.mac[1]=0x0a; cfg.mac[2]=0x35; cfg.mac[3]=0x01; cfg.mac[4]=0xfe; cfg.mac[5]=0xc0;
   cfg.ip[0]=169; cfg.ip[1]=254; cfg.ip[2]=47; cfg.ip[3]=62;
   cfg.port = 80;
   { static net_cb_t cb; cb.get = my_get; cb.user = 0; cfg.cb = &cb; }
   net_init(&net, &cfg);

   /* 1) ARP request for our IP */
   {
      static const uint8_t a[42] = {
         0xFF,0xFF,0xFF,0xFF,0xFF,0xFF, 0x11,0x22,0x33,0x44,0x55,0x66, 0x08,0x06,
         0x00,0x01, 0x08,0x00, 0x06, 0x04, 0x00,0x01,
         0x11,0x22,0x33,0x44,0x55,0x66, 169,254,47,61,
         0x00,0x00,0x00,0x00,0x00,0x00, 169,254,47,62
      };
      memcpy(in, a, 42);
      n = net_input(&net, in, 42, out, sizeof(out), 0);
      printf("ARP  reply len=%d ", n);
      if (n == 42 && out[20] == 0x00 && out[21] == 0x02 && memcmp(out + 28, cfg.ip, 4) == 0)
         printf("[OK]\n");
      else { printf("[FAIL]\n"); fails++; }
   }

   /* 2) SYN */
   {
      n = build_tcp(in, 40000, 80, 1000, 0, 0x02, 0);
      {
         int r = net_input(&net, in, n, out, sizeof(out), 0);
         printf("SYN  reply len=%d flags=0x%02x seq=%u ack=%u ", r, out[34 + 13],
                (unsigned)((out[38]<<24)|(out[39]<<16)|(out[40]<<8)|out[41]),
                (unsigned)((out[42]<<24)|(out[43]<<16)|(out[44]<<8)|out[45]));
         printf(" csum=%02x%02x ok=%d", out[34 + 16], out[34 + 17], tcp_csum_ok(out, r));
         if (r > 0 && (out[34 + 13] & 0x12) == 0x12 && tcp_csum_ok(out, r)) printf("[OK]\n");
         else { printf("[FAIL]\n"); fails++; }
      }
   }

   /* 3) ACK + GET / */
   {
      n = build_tcp(in, 40000, 80, 1001, 0x1001, 0x10, 0);
      net_input(&net, in, n, out, sizeof(out), 1);
      n = build_tcp(in, 40000, 80, 1001, 0x1001, 0x18, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
      {
         int r = net_input(&net, in, n, out, sizeof(out), 2);
         int thl = (out[34 + 12] >> 4) * 4;
         printf("GET  reply len=%d ", r);
         if (r > 0 && memcmp(out + 34 + thl, "HTTP/1.1 200 OK", 15) == 0 && tcp_csum_ok(out, r) && csum_ok(out + 14))
            { int q, b0 = -1; for (q = 34 + thl; q + 3 < r; ++q)
                 if (out[q]==13 && out[q+1]==10 && out[q+2]==13 && out[q+3]==10) { b0 = q + 4; break; }
              if (b0 > 0) printf("[OK] body=\"%.16s\"\n", (const char*)(out + b0));
              else printf("[OK]\n"); }
         else { printf("[FAIL]\n"); fails++; }
      }
   }

   printf(fails ? "RESULT FAIL(%d)\n" : "RESULT PASS\n", fails);
   return fails ? 1 : 0;
}