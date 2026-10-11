/*==========================================================================
 *  t_mlx.c -- run the REAL Melexis MLX90640 library on RISC-V
 *--------------------------------------------------------------------------
 *  目的：证明厂商的 MLX90640_API.c **编译成 RISC-V 后能真正跑对**，
 *        而不只是"能编译过"。板子还没到，所以用 rv32sim.py 跑。
 *
 *  做法（往返验证）：
 *      Python 按 EEPROM 布局编码出已知参数 -> eeData[832]
 *      -> MLX90640_ExtractParameters()（厂商原码，一字未改）
 *      -> 把提取出来的参数以十六进制打印
 *      再由 Python 侧比对是否等于当初编码进去的值。
 *
 *  ★ 打印一律用十六进制位模式，不打十进制浮点：
 *    - 不依赖 printf（本程序 -nostdlib，没有 printf）
 *    - 浮点比较可以做到**逐位相等**，比十进制更有说服力
 *
 *  I2C 层由本文件提供（厂商只给了 MLX90640_I2C_Driver.h 的接口声明，
 *  实现是平台相关的）。这里直接用内存数组应答，正好也演示了：
 *  在真板上把这一层换成"读 FPGA 寄存器窗口"即可，上层代码完全不用动。
 *==========================================================================*/
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "MLX90640_API.h"
#include "MLX90640_I2C_Driver.h"

typedef unsigned int  u32;
typedef unsigned char u8;

#define MMIO_PUTC  ((volatile u8  *)0xF0000000u)
#define MMIO_EXIT  ((volatile u32 *)0xF0000004u)

static void putc_(char c) { *MMIO_PUTC = (u8)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static void puthex(u32 v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) {
        u32 d = (v >> i) & 0xFu;
        putc_(d < 10u ? (char)('0' + d) : (char)('a' + (d - 10u)));
    }
}

/* 打印 "<tag> <value-hex>\n" 便于 Python 侧解析 */
static void kv(const char *tag, u32 v) { puts_(tag); putc_(' '); puthex(v); putc_('\n'); }
static void kvf(const char *tag, float f)
{
    u32 bits;
    memcpy(&bits, &f, 4);
    puts_(tag); putc_(' '); puthex(bits); putc_('\n');
}

/*==========================================================================
 *  I2C 层：用内存数组当器件
 *  真板上只要把这几个函数改成读写 FPGA 的寄存器窗口，上层代码一字不改。
 *==========================================================================*/
#define EE_NUM   832
#define FRAME_NUM 834

static uint16_t g_ee[EE_NUM];
static uint16_t g_frame[FRAME_NUM];
static uint16_t g_ctrl;
static uint16_t g_status = 0x0008;      /* data-ready */

/* 生成出来的合成 EEPROM（见 gen_mlx_ee.py） */
static const uint16_t ee_image[EE_NUM] = {
#include "_mlx_ee.inc"
};

void MLX90640_I2CInit(void) { }
void MLX90640_I2CFreqSet(int freq) { (void)freq; }
int  MLX90640_I2CGeneralReset(void) { return 0; }

int MLX90640_I2CRead(uint8_t slaveAddr, uint16_t startAddress,
                     uint16_t nMemAddressRead, uint16_t *data)
{
    uint16_t i;
    (void)slaveAddr;
    for (i = 0; i < nMemAddressRead; i++) {
        uint16_t a = startAddress + i;
        if (a >= 0x2400 && a < 0x2400 + EE_NUM)      data[i] = g_ee[a - 0x2400];
        else if (a >= 0x0400 && a < 0x0400 + FRAME_NUM - 64)
                                                     data[i] = g_frame[a - 0x0400];
        else if (a >= 0x0700 && a < 0x0700 + 64)     data[i] = g_frame[768 + (a - 0x0700)];
        else if (a == MLX90640_CTRL_REG)             data[i] = g_ctrl;
        else if (a == MLX90640_STATUS_REG)           data[i] = g_status;
        else                                         data[i] = 0;
    }
    return 0;
}

int MLX90640_I2CWrite(uint8_t slaveAddr, uint16_t writeAddress, uint16_t data)
{
    (void)slaveAddr;
    if (writeAddress == MLX90640_CTRL_REG)        g_ctrl = data;
    else if (writeAddress == MLX90640_STATUS_REG) g_status = data;
    return 0;
}

/*==========================================================================
 *  主程序
 *==========================================================================*/
static paramsMLX90640 params;      /* 约 4.7KB，放 .bss */
static float  to[768];

/* 合成一帧"看起来合理"的原始数据：
 *   frameData[0..767] 像素原始值、[768..831] 辅助区（PTAT 等在 [800]）
 *   随便给一点非哨兵值即可 —— 本测试验的是"代码跑得对不对"，
 *   不是"温度准不准"（后者要真器件）。
 *   ⚠️ 避开哨兵值 0x7FFF，否则 ValidateFrameData/ValidateAuxData 会报错。    */
static void make_frame(void)
{
    int i;
    /* 每行第一个像素若为 0x7FFF 且行号奇偶匹配会被判为坏帧，这里统一避开 */
    for (i = 0; i < 768; i++) g_frame[i] = (uint16_t)(0x3000 + ((i * 37) & 0x0FFF));
    for (i = 768; i < FRAME_NUM; i++) g_frame[i] = (uint16_t)(0x2000 + ((i * 11) & 0x0FFF));
    g_frame[800] = 0x2A00;          /* Ptat */
    g_frame[801] = 0x2733;          /* Vbe  */
    g_frame[832] = 0x1234;
    g_frame[833] = 0;               /* subpage */
}

void _start(void)
{
    int err;
    int i;

    puts_("MLX90640 vendor library on RV32\n");

    memcpy(g_ee, ee_image, sizeof(g_ee));
    make_frame();
    g_ctrl = 0x1901;                /* 随便一个合法的 CTRL_REG 值 */

    /* ---- ExtractParameters（厂商原码）---- */
    err = MLX90640_ExtractParameters(g_ee, &params);
    kv("EXTRACT_ERR", (u32)err);

    kv("PARAM_kVdd",      (u32)(int32_t)params.kVdd);
    kv("PARAM_vdd25",     (u32)(int32_t)params.vdd25);
    kv("PARAM_vPTAT25",   (u32)params.vPTAT25);
    kv("PARAM_gainEE",    (u32)(int32_t)params.gainEE);
    kv("PARAM_resEE",     (u32)params.resolutionEE);
    kv("PARAM_alphaScale",(u32)params.alphaScale);
    kv("PARAM_ktaScale",  (u32)params.ktaScale);
    kv("PARAM_kvScale",   (u32)params.kvScale);
    kv("PARAM_ct0",       (u32)(int32_t)params.ct[0]);
    kv("PARAM_ct1",       (u32)(int32_t)params.ct[1]);
    kv("PARAM_ct2",       (u32)(int32_t)params.ct[2]);
    kv("PARAM_ct3",       (u32)(int32_t)params.ct[3]);
    kv("PARAM_ct4",       (u32)(int32_t)params.ct[4]);
    kvf("PARAM_KvPTAT",   params.KvPTAT);
    kvf("PARAM_KtPTAT",   params.KtPTAT);
    kvf("PARAM_alphaPTAT",params.alphaPTAT);
    kvf("PARAM_tgc",      params.tgc);
    kvf("PARAM_KsTa",     params.KsTa);
    kvf("PARAM_ksTo0",    params.ksTo[0]);
    kvf("PARAM_ksTo1",    params.ksTo[1]);
    kvf("PARAM_ksTo2",    params.ksTo[2]);
    kvf("PARAM_ksTo3",    params.ksTo[3]);
    kvf("PARAM_ksTo4",    params.ksTo[4]);

    kv("PIX_alpha0", (u32)params.alpha[0]);
    kv("PIX_alpha1", (u32)params.alpha[1]);
    kv("PIX_offset0",(u32)(int32_t)params.offset[0]);
    kv("PIX_offset1",(u32)(int32_t)params.offset[1]);
    kv("PIX_kta0",   (u32)(int32_t)params.kta[0]);
    kv("PIX_kv0",    (u32)(int32_t)params.kv[0]);

    /* ---- 传感器级计算 ---- */
    {
        float vdd = MLX90640_GetVdd(g_frame, &params);
        float ta  = MLX90640_GetTa(g_frame, &params);
        kvf("CALC_Vdd", vdd);
        kvf("CALC_Ta",  ta);

        /* CalculateTo：768 个像素的逐点温度 —— 这是项 4 的核心 */
        MLX90640_CalculateTo(g_frame, &params, 0.95f, ta, to);

        kvf("TO_0",   to[0]);
        kvf("TO_1",   to[1]);
        kvf("TO_100", to[100]);
        kvf("TO_383", to[383]);
        kvf("TO_767", to[767]);
    }

    /* 统计 768 个结果里有多少是有限值（NaN 的指数全 1） */
    {
        int finite = 0;
        for (i = 0; i < 768; i++) {
            u32 b; memcpy(&b, &to[i], 4);
            if (((b >> 23) & 0xFF) != 0xFF) finite++;
        }
        kv("TO_FINITE_COUNT", (u32)finite);
    }

    puts_("DONE\n");
    *MMIO_EXIT = 0;
    for (;;) { }
}
