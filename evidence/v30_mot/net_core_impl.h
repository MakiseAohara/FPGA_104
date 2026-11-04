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

/* Slot zero keeps the original public conn/rbuf fields for native wrappers.
 * Other slots own separate response bytes; no connection or 32 KiB buffer is
 * copied while selecting the active connection. */
static net_conn_t* nc_slot(net_t* n,unsigned slot)
{
#if NET_CONN_COUNT > 1
   if(slot)return &n->extra_conn[slot-1];
#else
   (void)slot;
#endif
   return &n->conn;
}
static net_conn_t* nc_current(net_t* n) {return nc_slot(n,n->active_slot);}
static uint8_t* nc_response_buffer(net_t* n)
{
#if NET_CONN_COUNT > 1
   if(n->active_slot)return n->extra_rbuf[n->active_slot-1];
#endif
   return n->rbuf;
}

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
   int i;unsigned slot;
   n->cfg = *cfg;
   for(slot=0;slot<NET_CONN_COUNT;slot++) {
      net_conn_t* c=nc_slot(n,slot);uint8_t* buf;
      c->used=0;c->state=0;c->resp=0;
      n->active_slot=slot;buf=nc_response_buffer(n);
      for(i=0;i<NET_MAX_FRAME;++i)buf[i]=0;
   }
   n->active_slot=0;n->tick_slot=0;
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
   net_conn_t* c = nc_current(n);
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
   {
      uint32_t end=seq+(uint32_t)dlen+((flags&0x02)?1u:0u)+((flags&0x01)?1u:0u);
      /* Replaying an older segment must not move the high-water mark back. */
      if((int32_t)(end-c->snd_nxt)>0)c->snd_nxt=end;
   }
   c->last_seq = seq;
   c->last_len = dlen;
   return nc_frame(n, c->mac, c->ip, 6, seg, 20 + dlen, out);
}

static char* nc_str(char* d, const char* s) { while (*s) *d++ = *s++; return d; }

static int nc_http(net_t* n, const char* path)
{
   net_conn_t* c=nc_current(n);
   uint8_t* response=nc_response_buffer(n);
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
      char nb[12]; int k = 0, j, digits = blen;
      if (digits == 0) nb[k++] = 0x30;
      while (digits > 0 && k < 11) { nb[k++] = (char)(0x30 + (digits % 10)); digits /= 10; }
      for (j = k - 1; j >= 0; --j) *w++ = nb[j];
   }
   w = nc_str(w, "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
   hl = (int)(w - hdr);
   if (hl + blen > (int)sizeof(n->rbuf)) blen = (int)sizeof(n->rbuf) - hl;
   nc_cpy(response, (const uint8_t*)hdr, hl);
   nc_cpy(response + hl, body, blen);
   c->resp=response;c->resp_len=hl+blen;c->resp_off=0;c->tail_paired=0;
   return c->resp_len;
}


/* A small bounded flight avoids waiting for the receiver's delayed ACK after
 * every segment. Response bytes remain in rbuf until cumulatively acknowledged. */
static int nc_emit(net_t* n, uint8_t* out, uint32_t seq, uint8_t flags,
                   const uint8_t* data, int size, uint32_t now)
{
   net_conn_t* c=nc_current(n);
   int was_empty=(c->snd_una==c->snd_nxt);
   int r=nc_tcp_send(n,out,seq,flags,data,size);
   c->last_flags=flags;c->last_ms=now;
   /* Sending a second packet must not postpone an older packet's timeout. */
   if(was_empty){c->retx_ms=now;c->retx=0;}
   return r;
}
static int nc_again(net_t* n,uint8_t* out)
{
   net_conn_t* c=nc_current(n);
   if(c->state==1)return nc_tcp_send(n,out,c->iss,0x12,0,0);
   if(c->state==3)return nc_tcp_send(n,out,c->snd_nxt-1u,0x11,0,0);
   if(c->state==2 && c->resp) {
      int off=(int)(c->snd_una-(c->iss+1u));
      uint32_t count=c->snd_nxt-c->snd_una;
      if(off<0 || off>=c->resp_len || !count)return 0;
      if(count>NET_MSS)count=NET_MSS;
      if(count>(uint32_t)(c->resp_len-off))count=(uint32_t)(c->resp_len-off);
      /* A closed receive window permits only a one-byte persist probe. */
      if(!c->peer_window)count=1;
      else if(count>c->peer_window)count=c->peer_window;
      return nc_tcp_send(n,out,c->snd_una,0x18,c->resp+off,(int)count);
   }
   return 0;
}
static int nc_response(net_t* n,uint8_t* out,uint32_t now)
{
   net_conn_t* c=nc_current(n);
   uint32_t flight,limit,room;
   int count,off;
   if(c->state!=2 || !c->resp)return 0;
   flight=c->snd_nxt-c->snd_una;
   limit=NET_TX_SEGMENTS*NET_MSS;
   if(limit>c->peer_window)limit=c->peer_window;
   if(flight>=limit)return 0;
   room=limit-flight;
   count=c->resp_len-c->resp_off;
   if(count>0) {
      if(count>NET_MSS)count=NET_MSS;
      if((uint32_t)count>room)count=(int)room;
#if NET_TX_SEGMENTS > 1 && NET_PAIR_TAIL
      /* A single short last packet can otherwise wait hundreds of ms for ACK.
       * Split only when its complete remainder fits the peer's current window. */
      if(!c->tail_paired && !flight && count>1 && c->resp_len-c->resp_off<=NET_MSS &&
         (uint32_t)(c->resp_len-c->resp_off)<=room) {
         count=(count+1)/2;c->tail_paired=1;
      }
#endif
      if(count<=0)return 0;
      off=c->resp_off;c->resp_off+=count;
      return nc_emit(n,out,c->snd_nxt,0x18,c->resp+off,count,now);
   }
   if(!flight) {
      c->state=3;return nc_emit(n,out,c->snd_nxt,0x11,0,0,now);
   }
   return 0;
}
static int nc_tcp(net_t* n, const uint8_t* f, int len, uint8_t* out, int cap, uint32_t now)
{
   const uint8_t* ip=f+14;const uint8_t* tcp=f+34;
   net_conn_t* c=0;
   int thl,dlen,i,complete=0,can_send=0;
   int found=-1,available=-1;unsigned slot;
   uint32_t seq,ack;
   uint8_t flags;
   if(len<54 || cap<54+NET_MSS)return 0;
   thl=(tcp[12]>>4)*4;
   if(thl<20 || 34+thl>len)return 0;
   dlen=len-34-thl;seq=nc_get32(tcp+4);ack=nc_get32(tcp+8);flags=tcp[13];
   if(nc_get16(tcp+2)!=n->cfg.port)return 0;
   /* Match before interpreting ACK/RST; a client can only mutate its own slot.
    * Expired slots are reusable, occupied live slots are never overwritten. */
   for(slot=0;slot<NET_CONN_COUNT;slot++) {
      net_conn_t* candidate=nc_slot(n,slot);
      if(candidate->used && (uint32_t)(now-candidate->last_ms)>=10000u) {
         candidate->used=0;candidate->state=0;
      }
      if(!candidate->used) {if(available<0)available=(int)slot;continue;}
      if(candidate->port==nc_get16(tcp) && nc_eq(candidate->ip,ip+12,4))found=(int)slot;
   }
   if((flags&0x02) && !(flags&0x10)) {
      if(found>=0) {
         n->active_slot=(unsigned)found;c=nc_current(n);
         if(c->state==1 && c->rcv_nxt==seq+1u)
            return nc_emit(n,out,c->iss,0x12,0,0,now);
         return 0;
      }
      if(available<0)return 0;
      n->active_slot=(unsigned)available;c=nc_current(n);
      c->used=1;c->state=1;nc_cpy(c->mac,f+6,6);nc_cpy(c->ip,ip+12,4);
      c->port=nc_get16(tcp);c->iss=0x1000u+now*31u;
      c->snd_una=c->iss;c->snd_nxt=c->iss;c->rcv_nxt=seq+1u;
      c->peer_window=nc_get16(tcp+14);
      c->resp=0;c->resp_len=0;c->resp_off=0;c->tail_paired=0;c->request_len=0;
      return nc_emit(n,out,c->iss,0x12,0,0,now);
   }
   if(found<0)return 0;
   n->active_slot=(unsigned)found;c=nc_current(n);
   if(flags&0x04) {c->used=0;c->state=0;return 0;}
   if(!(flags&0x10) || (int32_t)(ack-c->snd_nxt)>0)return 0;
   c->last_ms=now;
   if(c->state==1) {
      if(ack!=c->snd_nxt || seq!=c->rcv_nxt)return 0;
      c->state=2;
   }
   if((int32_t)(ack-c->snd_una)>=0 && seq==c->rcv_nxt) {
      uint16_t window=nc_get16(tcp+14);
      if(window>c->peer_window)can_send=1;
      c->peer_window=window;
   }
   if((int32_t)(ack-c->snd_una)>0) {c->snd_una=ack;c->retx=0;c->retx_ms=now;can_send=1;}
   if(c->state==3) {
      if(flags&1) {
         c->rcv_nxt=seq+1u;
         if(c->snd_una==c->snd_nxt) {c->used=0;c->state=0;}
         return nc_tcp_send(n,out,c->snd_nxt,0x10,0,0);
      }
      if(c->snd_una==c->snd_nxt) {c->used=0;c->state=0;}
      return 0;
   }
   if(dlen>0 && !c->resp) {
      if(seq!=c->rcv_nxt)return nc_tcp_send(n,out,c->snd_nxt,0x10,0,0);
      if(c->request_len+dlen>=(int)sizeof(c->request)) {c->used=0;c->state=0;return 0;}
      for(i=0;i<dlen;i++)c->request[c->request_len++]=(char)tcp[thl+i];
      c->request[c->request_len]=0;c->rcv_nxt+=dlen;
      for(i=3;i<c->request_len;i++)
         if(c->request[i-3]=='\r' && c->request[i-2]=='\n' && c->request[i-1]=='\r' && c->request[i]=='\n')complete=1;
      if(!complete)return nc_tcp_send(n,out,c->snd_nxt,0x10,0,0);
      if(c->request_len<5 || c->request[0]!='G' || c->request[1]!='E' || c->request[2]!='T' || c->request[3]!=' ') {
         c->used=0;c->state=0;return 0;
      }
      {char path[96];int j=0;
       for(i=4;i<c->request_len && c->request[i]!=' ' && j<95;i++)path[j++]=c->request[i];
       path[j]=0;if(!j) {path[0]='/';path[1]=0;}
       nc_http(n,path);
       can_send=1;
      }
   }
   if(can_send) {int r=nc_response(n,out,now);if(r)return r;}
   if(flags&1) {
      c->rcv_nxt=seq+dlen+1u;c->state=3;
      return nc_emit(n,out,c->snd_nxt,0x11,0,0,now);
   }
   if(dlen>0 && c->resp)return nc_tcp_send(n,out,c->snd_nxt,0x10,0,0);
   return 0;
}

int net_input(net_t* n,const uint8_t* f,int len,uint8_t* out,int cap,uint32_t now)
{
   uint16_t et;int total;uint32_t sum;
   if(len<14 || cap<54)return 0;
   et=nc_get16(f+12);
   if(et==0x0806)return nc_arp(n,f,len,out);
   if(et!=0x0800 || len<34 || f[14]!=0x45)return 0;
   total=nc_get16(f+16);
   /* Ignore Ethernet padding/FCS, never advance TCP sequence over them. */
   if(total<20 || total>len-14 || (nc_get16(f+20)&0x3FFFu))return 0;
   if(nc_fold(nc_csum_add(0,f+14,20))!=0)return 0;
   len=14+total;
   if(!nc_eq(f+30,n->cfg.ip,4))return 0;
   if(f[23]==1 && len<=cap)return nc_icmp(n,f,len,out);
   if(f[23]!=6 || total<40)return 0;
   sum=nc_csum_add(0,f+26,8)+6u+(uint32_t)(total-20);
   if(nc_fold(nc_csum_add(sum,f+34,total-20))!=0)return 0;
   return nc_tcp(n,f,len,out,cap,now);
}
int net_tick(net_t* n,uint8_t* out,int cap,uint32_t now)
{
   unsigned scan,slot;
   if(cap<54+NET_MSS)return 0;
   for(scan=0;scan<NET_CONN_COUNT;scan++) {
      int r;net_conn_t* c;
      slot=(n->tick_slot+scan)%NET_CONN_COUNT;
      n->active_slot=slot;c=nc_current(n);
      if(!c->used)continue;
      if((uint32_t)(now-c->last_ms)>=10000u) {c->used=0;c->state=0;continue;}
      if(c->snd_una!=c->snd_nxt && (uint32_t)(now-c->retx_ms)>=500u) {
         c->retx_ms=now;
         if(++c->retx>12) {c->used=0;c->state=0;continue;}
         r=nc_again(n,out);
      } else r=nc_response(n,out,now);
      if(r) {n->tick_slot=(slot+1u)%NET_CONN_COUNT;return r;}
   }
   n->tick_slot=(n->tick_slot+1u)%NET_CONN_COUNT;
   return 0;
}
#endif
