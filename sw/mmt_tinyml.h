/*=========================================================================
 *  mmt_tinyml.h —— AI 推理接入（task-27）
 *-------------------------------------------------------------------------
 *  干什么：把 SoC 的**自定义指令**通道（→ TinyML 加速器的 cmd/rsp 口）
 *          和 **R7 张量区**的地址管理，做成固件能安全使用的最小驱动。
 *
 *  为什么这么写（证据）：
 *   · 加速器命令口 = SoC 自定义指令，SoC 侧 5 根信号
 *     `ci_cmd_valid / ci_function_id[9:0] / ci_inputs_0[31:0] / ci_inputs_1[31:0]`
 *     与 `ci_cmd_ready / ci_rsp_valid / ci_outputs_0[31:0]`
 *     （`rtl\mmt\soc\mmt_soc_subsystem.v:330-337` 接 `cpu0_customInstruction_*`；
 *       `rtl\mmt\mmt_top.v:1638-1641` 接顶层，`:935-944` 接加速器
 *       `u_tinyml_accel` 的 `.cmd_xxx` 与 `.rsp_xxx` 端口）。
 *   · 指令编码用厂商**验证过的写法**（`riscv.h:350-359` 的 `opcode_R`）：
 *       `.word (opcode | regnum_rd<<7 | regnum_rs1<<15 | regnum_rs2<<20 | func3<<12 | func7<<25)`
 *     ⇒ **func3 是 bits[14:12]、func7 是 bits[31:25]、rs1/rs2 是寄存器里的值**；
 *       `func3`+`func7` 正好 10 位，对应加速器的 `function_id[9:0]`。
 *   · `function_id` 的拼接顺序（{func7,func3} 还是 {func3,func7}）**无法从加密 IP 确认**
 *     （见文档 §4 的"无法确认"清单）；本驱动只把 func3/func7 原样按 R 型字段发射，
 *     所以**只要与厂商同一条指令，就不受这个顺序影响**。
 *   · 只读"读加速器配置"的指令号来自厂商库 `tinyml_lib.a` 的反汇编【实测】：
 *       `tinyml_accel_get_uuid()`   → func3=1, func7=0, rs1=0, rs2=0  ⇒ rd=UUID
 *       `tinyml_accel_get_accel_count()` → func3=1, func7=0, rs1=1, rs2=0
 *     ⇒ **func3=1/func7=0 是"读配置"，rs1=配置索引**。
 *
 *  ⚠️ 安全边界（本文件最重要的约定）
 *   1. **地址自检 fail-closed**：任何张量地址越出 R7（`0x03000000..0x03FFFFFF`）
 *      或对齐不足 ⇒ `mmt_tinyml_check()` 返回非 0，**驱动拒绝发任何命令**。
 *      （加速器/互联/DDR3 **没有可见的越界保护**，越界会静默别名到低地址 —— 见
 *        `docs\TinyML访存地址审计.md` 与本次帧步长 bug 的教训。）
 *   2. **发命令是"阻塞"的**：自定义指令要等加速器的 `cmd_ready/rsp_valid`，
 *      若加速器没接线（`mmt_soc_subsystem.v:323-328` 的注释说"端接成永远就绪、
 *      无响应"），CPU 会**卡死在这条指令上**。所以真正发命令的路径由
 *      `MMT_TINYML_ISSUE_EN` 开关控制，**默认 0（关闭）**，必须先确认接线再打开。
 *
 *  写权限：本文件属 `sw\**`（task-27 允许）。
 *=========================================================================*/
#ifndef MMT_TINYML_H
#define MMT_TINYML_H

#include <stdint.h>

/*------------------------------------------------------------------
 * 1. 张量区（R7）：0x03000000 – 0x03FFFFFF
 *----------------------------------------------------------------*/
#define MMT_TENSOR_BASE     0x03000000UL
#define MMT_TENSOR_END      0x04000000UL   /* 不含；R7 上界 */
#define MMT_TENSOR_ALIGN    128UL          /* 硬要求 ≥8 字节；这里用 128 更稳 */
#define MMT_TENSOR_ALIGN_MIN 8UL           /* 厂商要求的下限（conv.h / cache.h 的指针）*/

/* R5 视频帧缓存上界（判断"张量有没有压到视频区"；见 docs\帧步长修复-DDR分区对齐.md）*/
#define MMT_VIDEO_BASE      0x02000000UL
#define MMT_VIDEO_END       0x02BDDE00UL

/*------------------------------------------------------------------
 * 2. 自定义指令（SoC customInstruction → TinyML 加速器）
 *----------------------------------------------------------------*/
#define MMT_CI_CUSTOM0      0x0B           /* RISC-V CUSTOM-0 opcode */

/* R 型自定义指令发射。
 * ⚠️ **不能照抄厂商 `opcode_R` 的 `.word(... regnum_%0 ...)` 写法**：[实测] 那是老
 *    riscv-none-embed 工具链的 GAS 方言，我们这支 xpack GCC 15.2 的 GAS 会报
 *    `invalid operands (*UND* and *ABS* sections) for '<<'`（见 docs §6.2）。
 *    改用 GAS 的 `.insn r` 形式，并把寄存器交给 %0/%1/%2 代换：
 *      [实测] `.insn r 0x0B, 1, 0, %0, %1, %2` 编出来 = 0x00b5150b
 *             → opcode=0x0B, func3=1, func7=0 ✔ 与厂商 tinyml_accel_get_uuid()
 *               的 0x00a5150b 同字段（只有 rd/rs1/rs2 因寄存器分配不同）。
 * 结果 = 加速器 rsp_outputs_0。*/
#define MMT_CI_R(func3, func7, rs1, rs2)                          \
    ({                                                            \
        register unsigned long __v;                               \
        asm volatile(".insn r 0x0B, " #func3 ", " #func7 ", %0, %1, %2" \
                     : "=r"(__v)                                  \
                     : "r"((unsigned long)(rs1)), "r"((unsigned long)(rs2))); \
        __v;                                                      \
    })

/* 读加速器配置（【实测】= 厂商 tinyml_accel_get_* 的编码）：
 *   idx 0 = UUID、1 = accel 数量、2..= 其它配置（AXI 位宽/cache 等，见 sys.h 的函数名）。*/
#define MMT_CI_CFG_READ(idx)   MMT_CI_R(1, 0, (idx), 0)

/* 参数写 + 触发（【推断】= 厂商库反汇编里出现的 f3=0..7 / f7=2、3 两种 bank）。
 * ⚠️ **参数语义未确认**，所以本文件只在 MMT_TINYML_ISSUE_EN=1 时才可能用到；
 *    默认路径不会发出这一类指令。*/
#define MMT_CI_PARAM(bank_f7, idx_f3, v0, v1)  MMT_CI_R((idx_f3), (bank_f7), (v0), (v1))

/*------------------------------------------------------------------
 * 3. 张量描述与布局
 *----------------------------------------------------------------*/
typedef struct {
    const char *name;
    uint32_t    base;      /* 实际地址（layout_init 之后才有效）*/
    uint32_t    size;      /* 字节数 */
    uint32_t    align;     /* 需要满足的对齐 */
} mmt_tensor_t;

/* 必需张量（顺序即布局顺序，见 docs\推理接入方案与进展.md 的布局表）：
 *   [0] 权重/模型常量（mobilenetv1_person_detect_model_data）
 *   [1] 输入张量（96×96×1 int8）
 *   [2] 输出张量（2 int8：not-person / person）
 *   [3] 中间激活/arena（最大的一块，放最后，可按剩余空间伸缩）*/
#define MMT_TENSOR_COUNT 4
extern mmt_tensor_t mmt_tensors[MMT_TENSOR_COUNT];

#define MMT_TENSOR_IDX_WEIGHTS 0
#define MMT_TENSOR_IDX_INPUT   1
#define MMT_TENSOR_IDX_OUTPUT  2
#define MMT_TENSOR_IDX_ARENA   3

/* 模型权重字节数（我们的文件 sw\ddr\weights\...bin = 300,568 B）*/
#define MMT_MODEL_BYTES        300568UL
/* 输入/输出尺寸（厂商 model_settings.h:24-31：96×96×1、2 类）*/
#define MMT_INPUT_BYTES        (96UL*96UL*1UL)
#define MMT_OUTPUT_BYTES       2UL

/*------------------------------------------------------------------
 * 4. API
 *----------------------------------------------------------------*/

/* 把 mmt_tensors[] 的 base 按 R7 起点 + 对齐排好（纯软件，无副作用）。返回 0=OK */
int mmt_tinyml_layout_init(void);

/* ★ 地址自检（fail-closed）：逐项检查 base/size/对齐/落在 R7 内/彼此不重叠。
 * 返回 0 = 全部通过；非 0 = 错误位掩码（见 mmt_tinyml_check_str()）*/
uint32_t mmt_tinyml_check(void);

/* 自检结果的文字说明（返回静态字符串，便于串口直接打）*/
const char *mmt_tinyml_check_str(uint32_t err);

/* 只读探测：读加速器配置（**会发自定义指令**，可能阻塞；由 MMT_TINYML_PROBE_EN 控制）*/
void mmt_tinyml_probe(uint32_t *uuid_out, uint32_t *count_out);

/* 打印一行 `[AI] ...`：布局 + 自检 + （可选）加速器配置。不破坏既有遥测行 */
void mmt_tinyml_selftest(void);

/* D-cache 一致性：写张量后、通知加速器前必须调用。
 * 【实测（task-7）】本 SoC 的 DDR 通路是 write-through（无 dirty 位），
 * 刷法用 `.word(0x500F)`；同时发一条标准 `fence` 兜底。*/
void mmt_tinyml_flush_dcache(void);

#endif /* MMT_TINYML_H */
