#include <string.h>
#include "../v30_mot/net_core.h"
#include "../v30_mot/net_core_impl.h"
#define HTTP_APP_IMPL
#include "../v30_mot/http_app.h"
static net_t net;
static uint8_t pixels[96*96];
__declspec(dllexport) void reset(void) {
 net_cfg_t cfg;static net_cb_t cb;static http_state_t st;int i;
 memset(&cfg,0,sizeof(cfg));memset(&net,0,sizeof(net));
 cfg.mac[0]=0;cfg.mac[1]=10;cfg.mac[2]=53;cfg.mac[3]=1;cfg.mac[4]=254;cfg.mac[5]=192;
 cfg.ip[0]=169;cfg.ip[1]=254;cfg.ip[2]=47;cfg.ip[3]=63;cfg.port=80;
 cb.get=http_get;cb.user=&st;cfg.cb=&cb;
 st.tracking_json="{\"schema\":1,\"frame_id\":12,\"width\":96,\"height\":96,\"tracks\":[]}";st.frame_id=12;
 st.status_json="{\"alarm\":0,\"f\":123}";st.events_json="[]";
 for(i=0;i<96*96;i++)pixels[i]=(uint8_t)i;
 st.thumb=pixels;st.thumb_w=96;st.thumb_h=96;http_set_state(&st);net_init(&net,&cfg);
}
__declspec(dllexport) int feed(const uint8_t* p,int len,uint8_t* out,int cap,uint32_t now) {return net_input(&net,p,len,out,cap,now);}
__declspec(dllexport) int tick(uint8_t* out,int cap,uint32_t now) {return net_tick(&net,out,cap,now);}

__declspec(dllexport) int snapshot_integrity(void) {
 static unsigned char expected[16384];const unsigned char* b;const char* ct;int size,n;
 if(!http_get(&g_http,"/api/state",&b,&size,&ct))return 0;
 if(http_get(&g_http,"/frame.png?seq=13",&b,&size,&ct))return 0;
 if(http_get(&g_http,"/frame.png?seq=",&b,&size,&ct))return 0;
 if(!http_get(&g_http,"/frame.png?seq=12",&b,&size,&ct))return 0;
 if(!http_get(&g_http,"/frame.png",&b,&size,&ct))return 0;
 memcpy(expected,b,size);memset(pixels,255,sizeof(pixels));
 if(!http_get(&g_http,"/frame.png",&b,&n,&ct))return 0;
 return n==size && memcmp(b,expected,n)==0;
}

__declspec(dllexport) int two_reader_snapshots(void) {
 static unsigned char expected[16384];http_state_t local=g_http;
 const unsigned char* b;const char* ct;int size,n;
 local.tracking_json="{\"frame_id\":101}";local.frame_id=101;
 if(!http_get(&local,"/api/state",&b,&n,&ct))return 0;
 if(!http_get(&local,"/frame.png?seq=101",&b,&size,&ct))return 0;
 memcpy(expected,b,size);memset(pixels,70,sizeof(pixels));
 local.tracking_json="{\"frame_id\":102}";local.frame_id=102;
 if(!http_get(&local,"/api/state",&b,&n,&ct))return 0;
 if(!http_get(&local,"/frame.png?seq=101",&b,&n,&ct))return 0;
 return n==size && memcmp(b,expected,n)==0;
}
