#ifndef NET_CORE_IMPL
#define NET_CORE_IMPL

static uint32_t nc_csum_add(uint32_t s, const uint8_t* d, int n)
{
   int i;
   for (i = 0; i + 1 < n; i += 2) s += ((uint32_t)d[i] << 8) | d[i + 1];
   if (n & 1) s += (uint32_t)d[n - 1] << 8;
   return s;
}

static uint16_t nc_fold(uint32_t s)
{
   while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
   return (uint16_t)(~s & 0xFFFFu);
}

static int nc_eq(const uint8_t* a, const uint8_t* b, int n)
{ int i; for (i = 0; i < n; ++i) if (a[i] != b[i]) return 0; return 1; }

static void nc_cpy(uint8_t* d, const uint8_t* s, int n)
{ int i; for (i = 0; i < n; ++i) d[i] = s[i]; }

static void nc_put32(uint8_t* p, uint32_t v)
{ p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
static uint32_t nc_get32(const uint8_t* p)
{ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static void nc_put16(uint8_t* p, uint16_t v) { p[0]=v>>8; p[1]=v; }
static uint16_t nc_get16(const uint8_t* p) { return (uint16_t)(((uint16_t)p[0]<<8)|p[1]); }

static int nc_frame(net_t* n, const uint8_t* dmac, const uint8_t* dip, uint8_t proto,
                    const uint8_t* payload, int plen, uint8_t* out)
{
   uint8_t* ip = out + 14;
   int total = 20 + plen;
   nc_cpy(out, dmac, 6);
   nc_cpy(out + 6, n->cfg.mac, 6);
   out[12] = 0x08; out[13] = 0x00;
   ip[0] = 0x45; ip[1] = 0x00;
   nc_put16(ip + 2, (uint16_t)total);
   ip[4]=0; ip[5]=0; ip[6]=0; ip[7]=0;
   ip[8] = 64; ip[9] = proto;
   ip[10] = 0; ip[11] = 0;
   nc_cpy(ip + 12, n->cfg.ip, 4);
   nc_cpy(ip + 16, dip, 4);
   nc_put16(ip + 10, nc_fold(nc_csum_add(0, ip, 20)));
   nc_cpy(out + 34, payload, plen);
   return 14 + total;
}

void net_init(net_t* n, const net_cfg_t* cfg)
{
   int i;
   n->cfg = *cfg;
   n->conn.used = 0; n->conn.state = 0; n->conn.resp = 0;
   for (i = 0; i < NET_MAX_FRAME; ++i) n->rbuf[i] = 0;
   for (i = 0; i < 32; ++i) n->ctype[i] = 0;
}

static int nc_arp(net_t* n, const uint8_t* f, int len, uint8_t* out)
{
   uint8_t r[28];
   if (len < 42) return 0;
   if (nc_get16(f + 20) != 1) return 0;
   if (!nc_eq(f + 38, n->cfg.ip, 4)) return 0;
   nc_put16(r, 1); nc_put16(r + 2, 0x0800);
   r[4] = 6; r[5] = 4; nc_put16(r + 6, 2);
   nc_cpy(r + 8, n->cfg.mac, 6);
   nc_cpy(r + 14, n->cfg.ip, 4);
   nc_cpy(r + 18, f + 22, 6);
   nc_cpy(r + 24, f + 28, 4);
   nc_cpy(out, f + 6, 6);
   nc_cpy(out + 6, n->cfg.mac, 6);
   out[12] = 0x08; out[13] = 0x06;
   nc_cpy(out + 14, r, 28);
   return 42;
}

static int nc_icmp(net_t* n, const uint8_t* f, int len, uint8_t* out)
{
   int plen = len - 34;
   uint8_t tmp[NET_MAX_FRAME];
   if (len < 42) return 0;
   if (f[34] != 8) return 0;
   if (plen > (int)sizeof(tmp)) plen = sizeof(tmp);
   nc_cpy(tmp, f + 34, plen);
   tmp[0] = 0; tmp[2] = 0; tmp[3] = 0;
   nc_put16(tmp + 2, nc_fold(nc_csum_add(0, tmp, plen)));
   return nc_frame(n, f + 6, f + 26, 1, tmp, plen, out);
}

static int nc_tcp_send(net_t* n, uint8_t* out, uint32_t seq, uint8_t flags,
                      const uint8_t* data, int dlen)
{
   uint8_t seg[20 + NET_MSS];
   uint32_t s;
   int i;
   net_conn_t* c = &n->conn;
   if (dlen > NET_MSS) dlen = NET_MSS;
   nc_put16(seg + 0, n->cfg.port);
   nc_put16(seg + 2, c->port);
   nc_put32(seg + 4, seq);
   nc_put32(seg + 8, c->rcv_nxt);
   seg[12] = 0x50;
   seg[13] = flags;
   nc_put16(seg + 14, NET_WIN);
   nc_put16(seg + 16, 0);
   nc_put16(seg + 18, 0);
   for (i = 0; i < dlen; ++i) seg[20 + i] = data[i];
   s = 0;
   s = nc_csum_add(s, n->cfg.ip, 4);
   s = nc_csum_add(s, c->ip, 4);
   s += 6u; s += (uint32_t)(20 + dlen);
   s = nc_csum_add(s, seg, 20 + dlen);
   nc_put16(seg + 16, nc_fold(s));
   c->snd_nxt = seq + (uint32_t)dlen + ((flags & 0x02) ? 1u : 0u) + ((flags & 0x01) ? 1u : 0u);
   c->last_seq = seq;
   c->last_len = dlen;
   return nc_frame(n, c->mac, c->ip, 6, seg, 20 + dlen, out);
}

static char* nc_str(char* d, const char* s) { while (*s) *d++ = *s++; return d; }

static int nc_http(net_t* n, const char* path)
{
   const uint8_t* body = 0;
   const char* ctype = 0;
   int blen = 0, hl;
   char hdr[192];
   char* w = hdr;
   int ok = (n->cfg.cb && n->cfg.cb->get) ? n->cfg.cb->get(n->cfg.cb->user, path, &body, &blen, &ctype) : 0;
   if (!ok || !body) {
      body = (const uint8_t*)"not found"; blen = 9; ctype = "text/plain";
   }
   w = nc_str(w, ok ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found");
   w = nc_str(w, "\r\nContent-Type: "); w = nc_str(w, ctype);
   w = nc_str(w, "\r\nContent-Length: ");
   {
      char nb[12]; int k = 0, j;
      if (blen == 0) nb[k++] = 0x30;
      while (blen > 0 && k < 11) { nb[k++] = (char)(0x30 + (blen % 10)); blen /= 10; }
      for (j = k - 1; j >= 0; --j) *w++ = nb[j];
   }
   w = nc_str(w, "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
   hl = (int)(w - hdr);
   if (hl + blen > (int)sizeof(n->rbuf)) blen = (int)sizeof(n->rbuf) - hl;
   nc_cpy(n->rbuf, (const uint8_t*)hdr, hl);
   nc_cpy(n->rbuf + hl, body, blen);
   n->conn.resp = n->rbuf;
   n->conn.resp_len = hl + blen;
   n->conn.resp_off = 0;
   return n->conn.resp_len;
}

static int nc_tcp(net_t* n, const uint8_t* f, int len, uint8_t* out, int out_cap, uint32_t now)
{
   const uint8_t* ip = f + 14;
   const uint8_t* tcp = f + 34;
   int ihl = (ip[0] & 0x0F) * 4;
   int thl = (tcp[12] >> 4) * 4;
   int dlen = len - 14 - ihl - thl;
   uint32_t seq = nc_get32(tcp + 4);
   uint32_t ack = nc_get32(tcp + 8);
   uint8_t flags = tcp[13];
   uint16_t dport = nc_get16(tcp + 2);
   net_conn_t* c = &n->conn;
   (void)out_cap; (void)now;
   if (dport != n->cfg.port && c->state == 0) return 0;

   if ((flags & 0x02) && !(flags & 0x10)) {
      c->used = 1; c->state = 1;
      nc_cpy(c->mac, f + 6, 6);
      nc_cpy(c->ip, ip + 12, 4);
      c->port = nc_get16(tcp + 0);
      c->iss = 0x1000u;
      c->snd_una = c->iss; c->snd_nxt = c->iss;
      c->rcv_nxt = seq + 1u;
      c->resp = 0; c->resp_len = 0; c->resp_off = 0;
      c->retx_ms = 0; c->retx = 0;
      return nc_tcp_send(n, out, c->iss, 0x12, 0, 0);
   }
   if (c->state == 0) return 0;

   if (flags & 0x10) {
      if ((int32_t)(ack - c->snd_una) > 0) c->snd_una = ack;
      if (c->state == 1) { c->state = 2; }
      if (c->resp && c->resp_off < c->resp_len) {
         int n2 = c->resp_len - c->resp_off;
         if (n2 > NET_MSS) n2 = NET_MSS;
         {
            int r = nc_tcp_send(n, out, c->iss + 1u + (uint32_t)c->resp_off, 0x18,
                                c->resp + c->resp_off, n2);
            c->resp_off += n2;
            return r;
         }
      }
   }

   if (dlen > 0 && seq == c->rcv_nxt) {
      char path[96];
      int k, j = 0;
      const uint8_t* d = tcp + thl;
      c->rcv_nxt = seq + (uint32_t)dlen;
      for (k = 4; k < dlen && d[k] != 0x20 && j < 95; ++k) path[j++] = (char)d[k];
      path[j] = 0;
      if (j == 0) { path[0] = 0x2F; path[1] = 0; }
      nc_http(n, path);
      {
         int n2 = c->resp_len;
         int r;
         if (n2 > NET_MSS) n2 = NET_MSS;
         c->resp_off = n2;
         r = nc_tcp_send(n, out, c->iss + 1u, 0x18, c->resp, n2);
         return r;
      }
   }

   if (flags & 0x01) {
      c->rcv_nxt = seq + 1u;
      c->state = 3;
      return nc_tcp_send(n, out, c->snd_nxt, 0x11, 0, 0);
   }
   return 0;
}

int net_input(net_t* n, const uint8_t* f, int len, uint8_t* out, int out_cap, uint32_t now_ms)
{
   uint16_t et;
   if (len < 14) return 0;
   et = nc_get16(f + 12);
   if (et == 0x0806) return nc_arp(n, f, len, out);
   if (et != 0x0800) return 0;
   if (len < 34) return 0;
   if (!nc_eq(f + 30, n->cfg.ip, 4)) {
      if (!(f[30] == 0xFF && f[31] == 0xFF && f[32] == 0xFF && f[33] == 0xFF)) return 0;
   }
   if (f[23] == 1) return nc_icmp(n, f, len, out);
   if (f[23] == 6) return nc_tcp(n, f, len, out, out_cap, now_ms);
   return 0;
}
int net_tick(net_t* n, uint8_t* out, int out_cap, uint32_t now_ms)
{
   net_conn_t* c = &n->conn;
   int off;
   (void)out_cap;
   if (!c->used || c->resp == 0) return 0;
   if (c->snd_una == c->snd_nxt) return 0;
   if (c->retx_ms == 0) { c->retx_ms = now_ms; return 0; }
   if ((uint32_t)(now_ms - c->retx_ms) < 300u) return 0;
   c->retx_ms = now_ms;
   c->retx++;
   if (c->retx > 6) { c->used = 0; c->state = 0; return 0; }
   off = (int)(c->last_seq - (c->iss + 1u));
   if (off < 0) off = 0;
   if (off > c->resp_len) return 0;
   return nc_tcp_send(n, out, c->last_seq, 0x18, c->resp + off, c->last_len);
}
#endif