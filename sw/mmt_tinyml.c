/*=========================================================================
 *  mmt_tinyml.c —— AI 推理接入实现（task-27）
 *  配套头文件 mmt_tinyml.h（那里有全部证据与安全约定，先读它）
 *=========================================================================*/
#include "mmt_tinyml.h"
#include "mmt_regs.h"      /* 只为 MMT_REG32 之类的既有工具；本文件不新增寄存器 */
#include "uart.h"

/*------------------------------------------------------------------
 * 0. 开关（默认全部"安全档"）
 *----------------------------------------------------------------*/
#ifndef MMT_TINYML_PROBE_EN
#define MMT_TINYML_PROBE_EN 0    /* 1 = 上板读加速器配置（会发自定义指令，可能阻塞）*/
#endif
#ifndef MMT_TINYML_ISSUE_EN
#define MMT_TINYML_ISSUE_EN 0    /* 1 = 允许发"参数写+触发"（语义未确认，默认禁止）*/
#endif

/*------------------------------------------------------------------
 * 1. 张量布局表
 *----------------------------------------------------------------*/
mmt_tensor_t mmt_tensors[MMT_TENSOR_COUNT] = {
    { "weights", 0, MMT_MODEL_BYTES, MMT_TENSOR_ALIGN },
    { "input",   0, MMT_INPUT_BYTES, MMT_TENSOR_ALIGN },
    { "output",  0, MMT_OUTPUT_BYTES, MMT_TENSOR_ALIGN },
    /* arena 先给 1MB 预算；实测模型 arena 需求见文档 §5（厂商 demo 用 tensor_arena）*/
    { "arena",   0, 1024UL*1024UL,   MMT_TENSOR_ALIGN },
};

static uint32_t align_up(uint32_t v, uint32_t a)
{
    return (v + (a - 1UL)) & ~(a - 1UL);
}

int mmt_tinyml_layout_init(void)
{
    uint32_t cur = MMT_TENSOR_BASE;
    for (int i = 0; i < MMT_TENSOR_COUNT; i++) {
        cur = align_up(cur, mmt_tensors[i].align);
        mmt_tensors[i].base = cur;
        cur += mmt_tensors[i].size;
        cur = align_up(cur, MMT_TENSOR_ALIGN);
    }
    return 0;
}

/*------------------------------------------------------------------
 * 2. ★ 地址自检（fail-closed）
 *    每一位对应一类错误，便于串口一眼看出是哪一类。
 *----------------------------------------------------------------*/
#define E_BASE_LOW    (1u << 0)   /* base < R7 起点 */
#define E_END_HIGH    (1u << 1)   /* base+size > R7 上界 */
#define E_ALIGN       (1u << 2)   /* 对齐不足 */
#define E_ZERO_SIZE   (1u << 3)   /* 尺寸为 0 */
#define E_OVERLAP     (1u << 4)   /* 两个张量重叠 */
#define E_VIDEO       (1u << 5)   /* 压到 R5 视频帧缓存 */
#define E_MODEL_SIZE  (1u << 6)   /* 权重尺寸与预期模型大小不符 */
#define E_WRAP        (1u << 7)   /* base+size 溢出 32 位 */

uint32_t mmt_tinyml_check(void)
{
    uint32_t err = 0;

    for (int i = 0; i < MMT_TENSOR_COUNT; i++) {
        uint32_t b = mmt_tensors[i].base;
        uint32_t s = mmt_tensors[i].size;

        if (s == 0) err |= E_ZERO_SIZE;
        if ((b & (MMT_TENSOR_ALIGN_MIN - 1UL)) != 0) err |= E_ALIGN;
        if ((b % mmt_tensors[i].align) != 0)         err |= E_ALIGN;
        if (b < MMT_TENSOR_BASE)                     err |= E_BASE_LOW;

        if (b > 0xFFFFFFFFUL - s) { err |= E_WRAP; continue; }
        if ((b + s) > MMT_TENSOR_END)                err |= E_END_HIGH;

        /* 与视频帧缓存区间不得相交（R5 上界 0x02BDDE00 < R7 起点，正常不会中）*/
        if (b < MMT_VIDEO_END && (b + s) > MMT_VIDEO_BASE) err |= E_VIDEO;
    }

    /* 两两不重叠 */
    for (int i = 0; i < MMT_TENSOR_COUNT; i++) {
        for (int j = i + 1; j < MMT_TENSOR_COUNT; j++) {
            uint32_t a0 = mmt_tensors[i].base, a1 = a0 + mmt_tensors[i].size;
            uint32_t b0 = mmt_tensors[j].base, b1 = b0 + mmt_tensors[j].size;
            if (a0 < b1 && b0 < a1) err |= E_OVERLAP;
        }
    }

    /* 权重尺寸必须与我们的模型文件一致（防止"以为装进了 DDR 其实没装"）*/
    if (mmt_tensors[MMT_TENSOR_IDX_WEIGHTS].size != MMT_MODEL_BYTES) err |= E_MODEL_SIZE;

    return err;
}

const char *mmt_tinyml_check_str(uint32_t err)
{
    if (err == 0) return "OK";
    /* 静态字符串：避免在嵌入式里用 snprintf（我们的 libc 很薄）*/
    if (err & E_END_HIGH)  return "ERR:out-of-R7";
    if (err & E_BASE_LOW)  return "ERR:below-R7";
    if (err & E_ALIGN)     return "ERR:align";
    if (err & E_OVERLAP)   return "ERR:overlap";
    if (err & E_VIDEO)     return "ERR:hits-video";
    if (err & E_WRAP)      return "ERR:wrap";
    if (err & E_ZERO_SIZE) return "ERR:zero-size";
    if (err & E_MODEL_SIZE)return "ERR:model-size";
    return "ERR:other";
}

/*------------------------------------------------------------------
 * 3. D-cache 一致性
 *----------------------------------------------------------------*/
void mmt_tinyml_flush_dcache(void)
{
    /* 【实测（task-7）】本 SoC 的 DDR 通路 write-through（无 dirty 位），
     * 刷 D-cache 用 `.word(0x500F)`（SoC 自定义的 cache 维护指令）。*/
    asm volatile(".word 0x0000500F" ::: "memory");
    /* 再发一条标准 fence 兜底（保证访存顺序对加速器可见）*/
    asm volatile("fence rw, rw" ::: "memory");
}

/*------------------------------------------------------------------
 * 4. 只读探测：读加速器配置
 *    ⚠️ 会发自定义指令；若加速器未接线，CPU 可能卡死。
 *       因此由 MMT_TINYML_PROBE_EN 控制（默认 0）。
 *----------------------------------------------------------------*/
void mmt_tinyml_probe(uint32_t *uuid_out, uint32_t *count_out)
{
    uint32_t uuid = 0, cnt = 0;
#if MMT_TINYML_PROBE_EN
    uuid = (uint32_t)MMT_CI_CFG_READ(0);   /* = 厂商 tinyml_accel_get_uuid() */
    cnt  = (uint32_t)MMT_CI_CFG_READ(1);   /* = 厂商 tinyml_accel_get_accel_count() */
#else
    (void)uuid; (void)cnt;
#endif
    if (uuid_out)  *uuid_out  = uuid;
    if (count_out) *count_out = cnt;
}

/*------------------------------------------------------------------
 * 5. 自检打印（一行 `[AI] ...`，不破坏既有遥测）
 *----------------------------------------------------------------*/
static void put_hex32(uint32_t v)
{
    static const char hx[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) uart_putc(hx[(v >> i) & 0xF]);
}

static void put_u32(uint32_t v)
{
    char b[11]; int n = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v > 0 && n < 10) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n > 0) uart_putc(b[--n]);
}

void mmt_tinyml_selftest(void)
{
    uint32_t err;
    uint32_t uuid = 0, cnt = 0;

    mmt_tinyml_layout_init();
    err = mmt_tinyml_check();

    uart_puts("[AI] layout=");
    uart_puts(err == 0 ? "OK" : mmt_tinyml_check_str(err));
    uart_puts(" err=");
    put_hex32(err);

    /* 张量布局（一眼看出"放哪、多大、对不对齐"）*/
    for (int i = 0; i < MMT_TENSOR_COUNT; i++) {
        uart_puts(" ");
        uart_puts(mmt_tensors[i].name);
        uart_puts("@");
        put_hex32(mmt_tensors[i].base);
        uart_puts("+");
        put_u32(mmt_tensors[i].size);
    }

    /* 加速器在不在（默认关闭；打开后若卡住 ⇒ 说明自定义指令没接到加速器）*/
    mmt_tinyml_probe(&uuid, &cnt);
#if MMT_TINYML_PROBE_EN
    uart_puts(" uuid=");  put_hex32(uuid);
    uart_puts(" accel="); put_u32(cnt);
#else
    uart_puts(" probe=off");
#endif
    uart_puts("\r\n");
}
