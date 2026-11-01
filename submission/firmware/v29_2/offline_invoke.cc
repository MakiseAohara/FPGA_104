#include <cstdio>
#include <cstdint>
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "model/model_settings.h"
#include "generator/v29_person_96_int8_model_data.h"
#include "input_contract.h"
alignas(16) static uint8_t arena[3*1024*1024];
int main(int argc,char** argv) {
    if(argc!=3)return 2;
    tflite::MicroErrorReporter reporter;
    tflite::MicroMutableOpResolver<4> resolver;
    resolver.AddMean();resolver.AddConv2D();resolver.AddFullyConnected();
    resolver.AddSoftmax();
    auto model=tflite::GetModel(v29_person_96_int8_model_data);
    tflite::MicroInterpreter interpreter(model,resolver,arena,sizeof(arena),&reporter);
    if(interpreter.AllocateTensors()!=kTfLiteOk)return 3;
    FILE* input=fopen(argv[1],"rb");FILE* output=fopen(argv[2],"w");
    if(!input||!output)return 4;
    int8_t raw[96*96];int frame=0;
    fprintf(output,"row,person,not_person\n");
    while(fread(raw,1,sizeof(raw),input)==sizeof(raw)) {
        prepare_model_input(interpreter.input(0)->data.int8,raw);
        if(interpreter.Invoke()!=kTfLiteOk)return 5;
        fprintf(output,"%d,%d,%d\n",frame++,interpreter.output(0)->data.int8[kPersonIndex],interpreter.output(0)->data.int8[kNotAPersonIndex]);
    }
    fclose(input);fclose(output);return 0;
}
