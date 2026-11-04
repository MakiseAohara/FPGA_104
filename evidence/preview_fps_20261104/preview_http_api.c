#include "../mot_web_20261104/net_test_api.c"
__declspec(dllexport) int packed_snapshot(unsigned char* out,int cap) {
 const unsigned char* p;const char* type;int n;
 if(!http_get(&g_http,"/api/preview",&p,&n,&type)||n>cap)return 0;
 memcpy(out,p,n);return n;
}
