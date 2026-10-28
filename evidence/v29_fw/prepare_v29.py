"""Create the v29 production candidate from fixed-camera v28 logic."""
from pathlib import Path
import difflib
import re
import shutil

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
base=(ROOT/'evidence/v29_bright/main_live29_bright.cc').read_text(encoding='utf-8')
s=re.sub(r'(#define INPUT_SUB128)\s+0',r'\g<1>     1',base,count=1)
s=re.sub(r'(#define AI_P_OFF)\s+\(-60\)',r'\g<1>         (-40)',s,count=1)
s=s.replace('#include "model/mobilenetv1_person_detect_model_data.h"','#include "generator/v29_person_96_int8_model_data.h"')
s=s.replace('tflite::GetModel(mobilenetv1_person_detect_model_data)','tflite::GetModel(v29_person_96_int8_model_data)')
start=s.index('#if INPUT_SUB128',s.index('static uint32_t sample_frame_box'))
end=s.index('#endif',start)+len('#endif')
s=s[:start]+s[end:]
old='for (int i = 0; i < IMG_N; ++i) input_snapshot[i] = model_input->data.int8[i];'
assert old in s
s=s.replace(old,old+'\n      prepare_model_input(model_input->data.int8, input_snapshot);',1)
s=s.replace('#include "cam_ctrl_core.h"','#include "cam_ctrl_core.h"\n#include "input_contract.h"',1)
s=s.replace('MicroMutableOpResolver<5>','MicroMutableOpResolver<4>').replace('   resolver.AddReshape();','')
s=s.replace('   resolver.AddAveragePool2D();','   resolver.AddMean();').replace('   resolver.AddDepthwiseConv2D();','   resolver.AddFullyConnected();')
s=s.replace('MMT_LIVE_BOOT v29_bright ','MMT_LIVE_BOOT v29 ').replace('MMT_CFG v29_bright ','MMT_CFG v29 ')
s=s.replace('#define BRIGHT_FIXED_GF 63','''#define NIGHT 1
#define DAY 2
#ifndef CAM_PRESET
#define CAM_PRESET NIGHT
#endif
#if CAM_PRESET == NIGHT
#define CAM_PRESET_NAME "NIGHT"
#define BRIGHT_FIXED_GF 63
#elif CAM_PRESET == DAY
#define CAM_PRESET_NAME "DAY"
#define BRIGHT_FIXED_GF 42
#else
#error Unsupported CAM_PRESET
#endif''')
s=s.replace('   bright_initialize();','''   bright_initialize();
   pp_stats_t boot_pst;
   sample_frame_box(input_snapshot,&boot_pst);
   bsp_printf("MMT_CAM_PRESET name=%s vts=1500 exp20=%d gc=%d gf=%d mean_sensor=%d\\n\\r",
              CAM_PRESET_NAME,BRIGHT_FIXED_EXP20,BRIGHT_FIXED_GC,BRIGHT_FIXED_GF,boot_pst.mean_sensor);''',1)
(HERE/'main_live29.cc').write_text(s,encoding='utf-8',newline='\n')
(HERE/'input_contract.h').write_text('''#pragma once
#include <stdint.h>
// MMT_IMG/MMT_THUMB retain raw u; inference alone is centered.
static void prepare_model_input(int8_t* destination,const int8_t* raw) {
    for(int i=0;i<96*96;++i) destination[i]=(int8_t)((int)(uint8_t)raw[i]-128);
}
''',encoding='utf-8')
for name in ('preprocess_core.h','ae_core.h','cam_ctrl_core.h'):
    shutil.copy2(ROOT/'evidence/v28_fw'/name,HERE/name)
shutil.copytree(ROOT.parent/'v29_today_snapshot/evidence/v29_model/generator',HERE/'generator',dirs_exist_ok=True)
(HERE/'source.patch').write_text(''.join(difflib.unified_diff(base.splitlines(True),s.splitlines(True),fromfile='v29_bright/main_live29_bright.cc',tofile='v29_fw/main_live29.cc')),encoding='utf-8')
print('Production source prepared: raw image export, centered inference, MEAN/FC, NIGHT/DAY')
