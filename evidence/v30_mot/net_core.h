#ifndef NET_CORE_H
#define NET_CORE_H
/*
 * net_core.h - 极简 IPv4/ARP/ICMP/UDP/TCP + HTTP，给 RISC-V 固件和 PC 上跑同一个实现
 *   - 无动态内存、无 libc 依赖（只需要 <stdint.h>）
 *   - 有界 TCP 连接槽：PC 镜像与板端浏览器可同时取帧
 *   - 帧的以太头/IP 头/TCP 头都在这里组，FCS 由调用方（或这里）拼
 */
#include <stdint.h>

#define NET_MAX_FRAME   32768    /* complete dashboard and bounded track snapshots */
#define NET_MSS         1400     /* 单段 TCP 最大负载（RTL TX 缓冲 2KB） */
#define NET_WIN         4096
#ifndef NET_TX_SEGMENTS
#define NET_TX_SEGMENTS 2       /* bounded response flight; 1 restores stop-and-wait */
#endif
#if NET_TX_SEGMENTS < 1 || NET_TX_SEGMENTS > 4
#error NET_TX_SEGMENTS must be between 1 and 4
#endif
#ifndef NET_PAIR_TAIL
#define NET_PAIR_TAIL   1       /* two short tail packets avoid delayed-ACK latency */
#endif
#ifndef NET_CONN_COUNT
#define NET_CONN_COUNT  2       /* PC mirror plus a board browser; 1 is rollback */
#endif
#if NET_CONN_COUNT < 1 || NET_CONN_COUNT > 4
#error NET_CONN_COUNT must be between 1 and 4
#endif

typedef struct {
   /* 给上层取 HTTP 内容；返回 0 表示 404 */
   int  (*get)(void* user, const char* path, const uint8_t** body, int* blen, const char** ctype);
   void* user;
} net_cb_t;

typedef struct {
   uint8_t  mac[6];          /* 本机 MAC */
   uint8_t  ip[4];           /* 本机 IP */
   uint16_t port;            /* HTTP 端口，通常 80 */
   const net_cb_t* cb;
} net_cfg_t;

typedef struct {
   int      used;
   uint8_t  mac[6];
   uint8_t  ip[4];
   uint16_t port;
   uint16_t state;           /* 1=SYN_RCVD 2=ESTABLISHED 3=FIN_WAIT */
   uint32_t iss;             /* 本端初始序号 */
   uint32_t snd_una;
   uint32_t snd_nxt;
   uint32_t rcv_nxt;
   uint16_t peer_window;     /* unscaled: this endpoint never negotiates window scaling */
   const uint8_t* resp;      /* 待发响应体（含 HTTP 头）*/
   int      resp_len;
   int      resp_off;
   int      tail_paired;     /* at most one short-tail split per response */
   uint32_t last_ms;
   uint32_t retx_ms;
   int      retx;
   uint32_t last_seq;        /* 最近一段的起点，用于重传 */
   int      last_len;
   uint8_t  last_flags;
   int      request_len;
   char     request[1024];
} net_conn_t;

typedef struct {
   net_cfg_t   cfg;
   net_conn_t  conn;
   uint8_t     rbuf[NET_MAX_FRAME];
   uint8_t     ctype[32];
#if NET_CONN_COUNT > 1
   net_conn_t  extra_conn[NET_CONN_COUNT-1];
   uint8_t     extra_rbuf[NET_CONN_COUNT-1][NET_MAX_FRAME];
#endif
   unsigned    active_slot;   /* callback/TX context, not a copied connection */
   unsigned    tick_slot;     /* next periodic service candidate */
} net_t;

void net_init(net_t* n, const net_cfg_t* cfg);
/* 输入一整帧（不含 FCS），有回包时写入 out 并返回长度，否则 0 */
int  net_input(net_t* n, const uint8_t* frame, int len, uint8_t* out, int out_cap, uint32_t now_ms);
/* 周期调用：处理超时重传 */
int  net_tick(net_t* n, uint8_t* out, int out_cap, uint32_t now_ms);

#endif
