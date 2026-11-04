#include <string.h>
#include "../v30_mot/net_core.h"
#include "../v30_mot/net_core_impl.h"
static net_t net;
static uint8_t fixture[24000];
static int fixture_size;
static int get_fixture(void* ignored,const char* path,const uint8_t** body,int* len,const char** type) {
 (void)ignored;
 if(strcmp(path,"/fixture"))return 0;
 *body=fixture;*len=fixture_size;*type="application/octet-stream";return 1;
}
__declspec(dllexport) void reset(int size) {
 net_cfg_t cfg;static net_cb_t cb;int i;
 memset(&cfg,0,sizeof(cfg));memset(&net,0,sizeof(net));
 cfg.mac[0]=0;cfg.mac[1]=10;cfg.mac[2]=53;cfg.mac[3]=1;cfg.mac[4]=254;cfg.mac[5]=192;
 cfg.ip[0]=169;cfg.ip[1]=254;cfg.ip[2]=47;cfg.ip[3]=63;cfg.port=80;
 cb.get=get_fixture;cb.user=0;cfg.cb=&cb;net_init(&net,&cfg);
 fixture_size=size<0?0:(size>24000?24000:size);
 for(i=0;i<fixture_size;i++)fixture[i]=(uint8_t)(i*37+11);
}
__declspec(dllexport) int feed(const uint8_t* p,int len,uint8_t* out,int cap,uint32_t now) {return net_input(&net,p,len,out,cap,now);}
__declspec(dllexport) int tick(uint8_t* out,int cap,uint32_t now) {return net_tick(&net,out,cap,now);}
__declspec(dllexport) uint32_t snd_nxt(void) {return net.conn.snd_nxt;}
__declspec(dllexport) uint32_t snd_una(void) {return net.conn.snd_una;}
__declspec(dllexport) int peer_window(void) {return net.conn.peer_window;}
__declspec(dllexport) int segments(void) {return NET_TX_SEGMENTS;}
