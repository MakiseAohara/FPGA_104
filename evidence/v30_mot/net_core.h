#ifndef NET_CORE_H
#define NET_CORE_H
/*
 * net_core.h - 极简 IPv4/ARP/ICMP/UDP/TCP + HTTP，给 RISC-V 固件和 PC 上跑同一个实现
 *   - 无动态内存、无 libc 依赖（只需要 <stdint.h>）
 *   - 单 TCP 连接（HTTP 用），足够一个浏览器反复刷新
 *   - 帧的以太头/IP 头/TCP 头都在这里组，FCS 由调用方（或这里）拼
 */
#include <stdint.h>

#define NET_MAX_FRAME   1536
#define NET_MSS         1000     /* 单段 TCP 最大负载 */
#define NET_WIN         4096

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
   const uint8_t* resp;      /* 待发响应体（含 HTTP 头）*/
   int      resp_len;
   int      resp_off;
   uint32_t last_ms;
   uint32_t retx_ms;
   int      retx;
   uint32_t last_seq;        /* 最近一段的起点，用于重传 */
   int      last_len;
} net_conn_t;

typedef struct {
   net_cfg_t   cfg;
   net_conn_t  conn;
   uint8_t     rbuf[NET_MAX_FRAME];
   uint8_t     ctype[32];
} net_t;

void net_init(net_t* n, const net_cfg_t* cfg);
/* 输入一整帧（不含 FCS），有回包时写入 out 并返回长度，否则 0 */
int  net_input(net_t* n, const uint8_t* frame, int len, uint8_t* out, int out_cap, uint32_t now_ms);
/* 周期调用：处理超时重传 */
int  net_tick(net_t* n, uint8_t* out, int out_cap, uint32_t now_ms);

#endif