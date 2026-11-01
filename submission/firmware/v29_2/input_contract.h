#pragma once
#include <stdint.h>
// MMT_IMG/MMT_THUMB retain raw u; inference alone is centered.
static void prepare_model_input(int8_t* destination,const int8_t* raw) {
    for(int i=0;i<96*96;++i) destination[i]=(int8_t)((int)(uint8_t)raw[i]-128);
}
