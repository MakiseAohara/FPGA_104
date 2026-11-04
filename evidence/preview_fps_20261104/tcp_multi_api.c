#include <string.h>
#include "../v30_mot/net_core.h"
#include "../v30_mot/net_core_impl.h"
static net_t net;
/* Deliberately shared callback buffer: a second GET overwrites it while the
 * first client has sent only its first packet. Each connection must own a copy. */
static uint8_t temporary[24000];
static int get_fixture(void* ignored,const char* path,const uint8_t** body,int* len,const char** type) {
 int i,n,variant;(void)ignored;
 if(!strcmp(path,"/html")){n=20000;variant=1;*type="text/html; charset=utf-8";}
 else if(!strcmp(path,"/binary")){n=10000;variant=2;*type="application/octet-stream";}
 else return 0;
 for(i=0;i<n;i++)temporary[i]=variant==1?(uint8_t)('a'+i%26):(uint8_t)(i*17+119);
 if(variant==1){memcpy(temporary,"<html><body>",12);memcpy(temporary+n-14,"</body></html>",14);}
 *body=temporary;*len=n;return 1;
}
__declspec(dllexport) void reset(void) {
 net_cfg_t cfg;static net_cb_t cb;
 memset(&cfg,0,sizeof(cfg));memset(&net,0,sizeof(net));
 cfg.mac[0]=0;cfg.mac[1]=10;cfg.mac[2]=53;cfg.mac[3]=1;cfg.mac[4]=254;cfg.mac[5]=192;
 cfg.ip[0]=169;cfg.ip[1]=254;cfg.ip[2]=47;cfg.ip[3]=63;cfg.port=80;
 cb.get=get_fixture;cb.user=0;cfg.cb=&cb;net_init(&net,&cfg);
}
__declspec(dllexport) int feed(const uint8_t* p,int len,uint8_t* out,int cap,uint32_t now) {return net_input(&net,p,len,out,cap,now);}
__declspec(dllexport) int tick(uint8_t* out,int cap,uint32_t now) {return net_tick(&net,out,cap,now);}
__declspec(dllexport) int connections(void) {return NET_CONN_COUNT;}
__declspec(dllexport) int memory_bytes(void) {return (int)sizeof(net_t);}
__declspec(dllexport) int slot_used(int slot) {return slot>=0 && slot<NET_CONN_COUNT?nc_slot(&net,(unsigned)slot)->used:-1;}
__declspec(dllexport) int slot_port(int slot) {return slot>=0 && slot<NET_CONN_COUNT?nc_slot(&net,(unsigned)slot)->port:-1;}
__declspec(dllexport) uint32_t next_seq(int port) {
 unsigned slot;
 for(slot=0;slot<NET_CONN_COUNT;slot++){net_conn_t* c=nc_slot(&net,slot);if(c->used&&c->port==port)return c->snd_nxt;}
 return 0;
}
__declspec(dllexport) uint32_t unacked_seq(int port) {
 unsigned slot;
 for(slot=0;slot<NET_CONN_COUNT;slot++){net_conn_t* c=nc_slot(&net,slot);if(c->used&&c->port==port)return c->snd_una;}
 return 0;
}
