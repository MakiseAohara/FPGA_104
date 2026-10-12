/*==========================================================================
 *  main.c  —  赛题三「多模态 AI 智能终端」RISC-V 软核固件（骨架）
 *--------------------------------------------------------------------------
 *  跑在 Sapphire RISC-V 软核上（工程里的 ip/sapphire_soc，efx_soc v2.2.9）。
 *
 *  软核负责什么（与硬件的分工，别搞混）：
 *    · 读走硬件的结果：SHT30 温湿度、MLX90640 原始帧、帧差法的面积/质心、融合得分
 *    · 算硬件算不动的：MLX90640 逐点温度（要 800+ 个 EEPROM 校准参数 + 浮点）
 *    · 多传感器时间对齐（以视频帧时间戳为主基准）
 *    · 把结果格式化成人能看的文字，写进 OSD 缓冲
 *    · 决定最终事件判定与上报
 *    · 串口打印调试信息
 *  硬件负责什么：
 *    · I2C 时序、摄像头链路、帧差法、加权求和、显示叠加、报警输出
 *      （硬件做这些是因为要"边采集边处理"，不能每帧都靠软件搬）
 *
 *  ⚠️ 状态：这是**骨架**，不是能直接烧的成品。原因：
 *    1) 本机还没有 RISC-V 工具链（系统里找不到 riscv gcc），编译不了
 *    2) MLX90640 的逐点温度算法要移植 Melexis 官方 C 库
 *       （本地已有：工作区\02_传感器与算法原型\mlx90640-library\），这里留了接口
 *    3) AI 推理（TinyML）的调用还没接（要等 TinyML Generator 生成加速器）
 *
 *  这些都不影响它作为"软件架构定义"的价值：硬件接口、数据流、分工都定死了。
 *==========================================================================*/

#include <stdint.h>
#include "mmt_regs.h"
#include "uart.h"

/*========================================================================
 * 一、最小串口打印（不依赖标准库的 printf，省 flash 也省栈）
 *     uart_putc / uart_puts 由 uart.c 提供（寄存器偏移待上板核实）
 *========================================================================*/


/* 打一个定点的数（value_x10 / 10 . value_x10 % 10） */
static void uart_put_x10(int32_t v)
{
    char buf[16];
    int i = 0, neg = 0;
    if (v < 0) { neg = 1; v = -v; }
    /* 整数部分 */
    int32_t ip = v / 10, fp = v % 10;
    if (ip == 0) buf[i++] = '0';
    while (ip > 0) { buf[i++] = (char)('0' + ip % 10); ip /= 10; }
    if (neg) buf[i++] = '-';
    /* 反转 */
    for (int a = 0, b = i - 1; a < b; a++, b--) { char t = buf[a]; buf[a] = buf[b]; buf[b] = t; }
    buf[i] = 0;
    uart_puts(buf);
    uart_putc('.');
    uart_putc((char)('0' + fp));
}

/* 不定长无符号十进制（计数器要打，值可能到 7 位以上）——每位一次除法，最多 10 位 */
static void uart_put_u32(uint32_t v)
{
    char buf[11];
    int i = 0;
    if (v == 0u) { uart_putc('0'); return; }
    while (v > 0u && i < 10) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i > 0) uart_putc(buf[--i]);
}

/* 固定 8 位十六进制 */
static void uart_put_hex32(uint32_t v)
{
    static const char hx[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int s = 28; s >= 0; s -= 4) uart_putc(hx[(v >> s) & 0xFu]);
}

static void uart_put_hex8(uint8_t v)
{
    static const char hx[] = "0123456789ABCDEF";
    uart_puts("0x");
    uart_putc(hx[(v >> 4) & 0xFu]);
    uart_putc(hx[v & 0xFu]);
}

/*========================================================================
 * 二、OSD 文字缓冲写入
 *     先写地址、再写数据（写数据那一拍在硬件里产生写脉冲）
 *========================================================================*/
static void osd_putc(uint8_t idx, char c)
{
    MMT_REG32(MMT_OSD_TXT_ADDR) = idx;
    MMT_REG32(MMT_OSD_TXT_DATA) = (uint32_t)(uint8_t)c;
}

static void osd_clear_line(uint8_t line)
{
    for (uint8_t c = 0; c < OSD_TXT_COLS; c++)
        osd_putc((uint8_t)(line * OSD_TXT_COLS + c), ' ');
}

/* 把字符串写进某一行（不补空格，超出截断） */
static void osd_line_str(uint8_t line, const char *s)
{
    uint8_t c = 0;
    osd_clear_line(line);
    while (*s && c < OSD_TXT_COLS) osd_putc((uint8_t)(line * OSD_TXT_COLS + c++), *s++);
}

/* 从指定列开始往某行追加字符串（用于拼接"标签 + 动态数值"），返回新的列号 */
static uint8_t osd_line_str_cont(uint8_t line, uint8_t col, const char *s)
{
    while (*s && col < OSD_TXT_COLS)
        osd_putc((uint8_t)(line * OSD_TXT_COLS + col++), *s++);
    return col;
}

/* 往某行追加一个定点数（×10），用于拼接动态值 */
static uint8_t osd_line_x10(uint8_t line, uint8_t col, int32_t v, uint8_t decimals)
{
    char buf[16]; int i = 0, neg = 0;
    if (v < 0) { neg = 1; v = -v; }
    if (decimals) {
        int32_t ip = v / 10, fp = v % 10;
        if (ip == 0) buf[i++] = '0';
        while (ip > 0) { buf[i++] = (char)('0' + ip % 10); ip /= 10; }
        if (neg) buf[i++] = '-';
        for (int a = 0, b = i - 1; a < b; a++, b--) { char t = buf[a]; buf[a] = buf[b]; buf[b] = t; }
        buf[i++] = '.'; buf[i++] = (char)('0' + fp);
    } else {
        if (v == 0) buf[i++] = '0';
        while (v > 0) { buf[i++] = (char)('0' + v % 10); v /= 10; }
        if (neg) buf[i++] = '-';
        for (int a = 0, b = i - 1; a < b; a++, b--) { char t = buf[a]; buf[a] = buf[b]; buf[b] = t; }
    }
    buf[i] = 0;
    for (int k = 0; k < i && (col + k) < OSD_TXT_COLS; k++)
        osd_putc((uint8_t)(line * OSD_TXT_COLS + col + k), buf[k]);
    return (uint8_t)(col + i);
}

/*========================================================================
 * 三、热力图：把 32×24 个温度映射成 0..255 的色阶写进 OSD 缓冲
 *     映射范围可配：低于 T_LO 全黑，高于 T_HI 全白
 *========================================================================*/
#define TH_T_LO_X10   200      /* 20.0°C */
#define TH_T_HI_X10   400      /* 40.0°C */

static void osd_write_thermal(const int16_t *temps_x10, uint16_t n)
{
    for (uint16_t i = 0; i < n && i < OSD_TH_SIZE; i++) {
        int32_t t = temps_x10[i];
        int32_t v;
        if (t <= TH_T_LO_X10)      v = 0;
        else if (t >= TH_T_HI_X10) v = 255;
        else                       v = (t - TH_T_LO_X10) * 255 / (TH_T_HI_X10 - TH_T_LO_X10);
        MMT_REG32(MMT_OSD_TH_ADDR) = i;
        MMT_REG32(MMT_OSD_TH_DATA) = (uint32_t)v;
    }
}

/*========================================================================
 * 四、MLX90640 逐点温度计算 —— 需移植 Melexis 官方库
 *========================================================================*/
/* 原始帧缓存：832 个字（768 像素 + 64 辅助），与硬件 BRAM 一致 */
static int16_t ir_frame[832];

/* 把硬件 BRAM 里的原始帧读进软件数组 */
static void ir_read_frame(void)
{
    for (uint16_t i = 0; i < 832; i++) {
        MMT_REG32(MMT_IR_FRAME_ADDR) = i;
        /* 读回是有延迟的（硬件里地址→数据要一拍），多读一次确保拿到 */
        (void)MMT_REG32(MMT_IR_FRAME_RD);
        ir_frame[i] = (int16_t)(MMT_REG32(MMT_IR_FRAME_RD) & 0xFFFF);
    }
}

/* 逐点目标温度（×10 摄氏度）。
 * ⚠️ TODO：这里要换成 Melexis 官方 MLX90640_CalculateTo() 的实现。
 *    官方库在 工作区\02_传感器与算法原型\mlx90640-library\，
 *    需要先把 EEPROM（0x2400 起 832 字）读一次存下来，再调用它的 API。
 *    现在先用"原始值线性折算"占位，**只能验证数据通路，不能当温度用**。 */
static void ir_compute_temps(int16_t *out_x10, uint16_t n)
{
    for (uint16_t i = 0; i < n && i < 768; i++) {
        /* 占位折算：原始值每 LSB 约 0.01°C（真实算法要 EEPROM 校准，不是这个） */
        out_x10[i] = (int16_t)(ir_frame[i] / 100);
    }
}

/*========================================================================
 * 五、多传感器时间对齐（赛题任务1 要求）
 *     以视频帧时间戳为主基准，其余传感器按"最近时间匹配"取值；
 *     超出容忍窗口时**保持上一次有效值**（而不是置空）——
 *     1Hz 的环境量在 ±200ms 窗口下约 40% 帧取不到，置空会导致显示跳变。
 *========================================================================*/
#define ALIGN_TOL_MS   200
#define ENV_HIST_N     8          /* 环境量历史深度（1Hz 采样、8 深度足够覆盖对齐窗口）*/

typedef struct {
    uint32_t stamp_ms;
    int32_t  value;
    uint8_t  valid;
} ts_sample_t;

static int32_t align_nearest(const ts_sample_t *buf, uint8_t n, uint32_t t, uint8_t *ok)
{
    int32_t best = 0; uint32_t bestd = 0xFFFFFFFFu; uint8_t found = 0;
    for (uint8_t i = 0; i < n; i++) {
        if (!buf[i].valid) continue;
        uint32_t d = (buf[i].stamp_ms > t) ? (buf[i].stamp_ms - t) : (t - buf[i].stamp_ms);
        if (d < bestd) { bestd = d; best = buf[i].value; found = 1; }
    }
    *ok = (found && bestd <= ALIGN_TOL_MS) ? 1 : 0;
    return best;
}

/*========================================================================
 * 六、主流程
 *========================================================================*/
int main(void)
{
    /* ---- 1. 硬件自检 ---- */
    if (MMT_REG32(MMT_ID) != MMT_ID_VALUE) {
        uart_puts("[MMT] FATAL: register bridge not responding\r\n");
        for (;;) { }
    }
    uart_puts("[MMT] multi-modal AI terminal, RISC-V firmware skeleton\r\n");

    /* ---- 2. 初始化配置（写硬件寄存器）----
     * ★ 这几个值同时被下面的串口"报警判据行"回显 —— 因为 0x38/0x3C 在 RTL 里是
     *   **只写**寄存器（读回来恒 0），固件只能自己记住写进去的是什么。
     *   改这里的数，打印会跟着变，不会出现"打印值和实际配置不一致"。 */
    const uint32_t cfg_diff_thr = 25u;    /* 帧差阈值（与 Python 原型一致）*/
    const uint32_t cfg_min_area = 60u;    /* 最小面积 */
    const uint32_t cfg_thr      = 154u;   /* 融合得分阈值 0.60×256（Q8）*/
    const uint32_t cfg_auth_end = 6u;     /* 授权结束小时 */
    const uint32_t cfg_auth_beg = 22u;    /* 授权开始小时 */
    const uint32_t cfg_hour     = 0u;     /* 当前小时：板子没有 RTC，先写 0
                                           * ⇒ in_auth_window 恒为真（0 < 6），
                                           *   所以"报警有没有触发"只能看 hardware 的 score */

    MMT_REG32(MMT_CFG_DIFF)    = (cfg_diff_thr << 8);
    MMT_REG32(MMT_CFG_MINAREA) = cfg_min_area;
    MMT_REG32(MMT_CFG_FUSION)  = (cfg_thr << 8) | cfg_auth_end;
    MMT_REG32(MMT_CFG_AUTH)    = cfg_auth_beg | (cfg_hour << 8);
    MMT_REG32(MMT_CTRL)        = 0x1;     /* 帧差使能，不冻结、不清、不静音 */

    osd_line_str(0, "MMT terminal booting...");
    osd_line_str(1, "waiting for sensors");
    osd_line_str(2, " ");

    /* ---- 3. 主循环 ---- */
    uint16_t last_ir_frame = 0;
    int32_t  body_max_t    = 0;      /* 画面内最高体温 ×10 */
    int32_t  ambient_t     = 0;      /* 环境温度 ×10 */
    int32_t  rh            = 0;      /* 湿度 ×100 */
    int16_t  temps[768];
    uint8_t  last_frame_tgl = 0xFF;  /* 帧翻转标志初值取一个不可能的值，保证第一帧一定被读 */

    /* 主时间基准：视频帧号（赛题要求"以视频帧时间戳为主时间基准"）。
     * 每个帧翻转沿算一帧，按 30fps 折成毫秒。 */
    uint32_t frame_no  = 0;
    uint32_t frame_ms  = 0;
    #define FRAME_MS   33

    /* 环境量历史（用于把 1Hz 的 SHT30 对齐到 30fps 的视频帧基准）*/
    ts_sample_t env_hist[ENV_HIST_N];
    uint8_t     env_hist_w = 0;
    int32_t     last_env_aligned = 0;   /* 上一次对齐到视频帧的环境温度（×10）*/
    for (uint8_t i = 0; i < ENV_HIST_N; i++) { env_hist[i].valid = 0; env_hist[i].stamp_ms = 0; env_hist[i].value = 0; }

    for (;;) {
        /* --- 3.1 SHT30 温湿度（1Hz，硬件自动采）--- */
        uint32_t st = MMT_REG32(MMT_SHT30_ST);
        if (st & 0x1) {                                   /* data_valid，读清 */
            uint32_t a = MMT_REG32(MMT_SHT30_A);
            ambient_t = (int32_t)(int16_t)(a >> 16);      /* 已 ×100 的温度 */
            rh        = (int32_t)(a & 0xFFFF);
            /* 硬件给的是 ×100，融合模块要 ×10，换算一下 */
            MMT_REG32(MMT_AMBIENT) = ((uint32_t)(ambient_t / 10) & 0xFFFF) | (1u << 16);
            MMT_REG32(MMT_RH_FWD)  = (uint32_t)rh;

            /* 打上视频帧时间戳存进历史（供对齐用）*/
            env_hist[env_hist_w].stamp_ms = frame_ms;
            env_hist[env_hist_w].value    = ambient_t / 10;   /* 存 ×10，与融合一致 */
            env_hist[env_hist_w].valid    = 1;
            env_hist_w = (uint8_t)((env_hist_w + 1) % ENV_HIST_N);
        }

        /* --- 3.2 MLX90640 新帧 → 逐点温度 --- */
        uint32_t ir_st = MMT_REG32(MMT_IR_ST);
        if (ir_st & 0x1) {                                /* frame_valid，读清 */
            uint16_t cnt = (uint16_t)(ir_st >> 16);
            if (cnt != last_ir_frame) {
                last_ir_frame = cnt;
                ir_read_frame();
                ir_compute_temps(temps, 768);

                /* 找画面内最高温（**只统计画面中央区域**，避免边框热源干扰） */
                int32_t mx = -1000;
                for (int y = 4; y < 20; y++)
                    for (int x = 4; x < 28; x++) {
                        int32_t t = temps[y * 32 + x];
                        if (t > mx) mx = t;
                    }
                body_max_t = mx;
                MMT_REG32(MMT_BODY_TEMP) = ((uint32_t)(mx & 0xFFFF)) | (1u << 16);

                osd_write_thermal(temps, 768);            /* 刷新热力图小窗 */
            }
        }

        /* --- 3.3 帧差法结果（★ 用帧翻转标志门控，避开跨时钟域竞争）---
         * 硬件每完成一帧会翻转 motion_st 的 bit2；只有这个标志变了，
         * 才说明 sum_area/sum_x/sum_y 是新一帧的稳定值，这时才去读。
         * 不这么做的风险：多比特状态跨域按位同步，可能读到中间值。 */
        uint32_t mst = MMT_REG32(MMT_MOTION_ST);
        uint8_t  frame_tgl = (uint8_t)((mst >> 2) & 0x1);
        uint32_t area = 0;
        int32_t  cx = 0, cy = 0;
        uint8_t  motion = 0;

        if (frame_tgl != last_frame_tgl) {
            last_frame_tgl = frame_tgl;
            frame_no++;
            frame_ms = frame_no * FRAME_MS;               /* 视频帧时间基准 */
            area   = MMT_REG32(MMT_MOTION_AREA);
            motion = (uint8_t)(mst & 0x1);
            if (area > 0) {                       /* 硬件只给 Σx·mask，除法在软件做 */
                cx = (int32_t)(MMT_REG32(MMT_MOTION_SUMX) / area);
                cy = (int32_t)(MMT_REG32(MMT_MOTION_SUMY) / area);
            }

            /* 多传感器时间对齐：把最近的环境量按"最近时间匹配"对齐到本视频帧，
             * 超出容忍窗口时保持上一次有效值（原型验证过：1Hz 在 ±200ms 窗口下
             * 约 40% 帧取不到，置空会导致显示跳变）。 */
            uint8_t ok = 0;
            int32_t env_aligned = align_nearest(env_hist, ENV_HIST_N, frame_ms, &ok);
            if (ok) last_env_aligned = env_aligned;
        }

        /* --- 3.4 视觉概率 ---
         * TODO：接 TinyML 推理。现在用"帧差面积归一化"占位，
         *       目的是先把整条链路跑通，不是真的 AI。*/
        uint8_t vprob = (area > 2000) ? 200 : (uint8_t)(area / 10);
        MMT_REG32(MMT_VISION) = (uint32_t)vprob | (1u << 8);

        /* --- 3.5 读回融合结果（硬件算的 60/25/15 加权）---
         * ⚠️ 0x28 的**实际**布局与注释不一致（RTL 拼接 46 位被截断，
         *    见 docs\上板判据-写通路握手计数.md §3）：
         *      实际 [31] = conf_vision[0]（**只有 1 位**，不是 8 位！）
         *           [30:23] = conf_temp
         *           [22:15] = conf_env
         *           [14:9]  = 0
         *           [8:0]   = score
         *    下面 conf_t/conf_e 是**按注释位置**取的（保留给 OSD 用），
         *    fs_temp/fs_env 是**按真实位置**取的（串口诊断用）。
         *    完整的 8 位视觉字节只能从新寄存器 0x78（MMT_VISION_WORD）读。 */
        uint32_t fs     = MMT_REG32(MMT_FUSION_SCORE);
        uint8_t  conf_v = (uint8_t)(fs >> 24);            /* 注释位置：实际只有 bit0 有效 */
        uint8_t  conf_t = (uint8_t)(fs >> 16);            /* 注释位置（截断后不是真温度）*/
        uint8_t  conf_e = (uint8_t)(fs >> 8);             /* 注释位置（截断后不是真环境）*/
        uint16_t score  = (uint16_t)(fs & 0x1FF);
        uint8_t  fs_vis_bit = (uint8_t)((fs >> 31) & 0x1u);   /* 0x28 里能拿到的**全部**视觉信息 */
        uint8_t  fs_temp    = (uint8_t)((fs >> 23) & 0xFFu);  /* 真实位置 [30:23] */
        uint8_t  fs_env     = (uint8_t)((fs >> 15) & 0xFFu);  /* 真实位置 [22:15] */
        uint32_t as     = MMT_REG32(MMT_ALARM_ST);        /* ★ 只读这一次：bit0 是"读清"锁存位 */
        uint8_t  alarm  = (uint8_t)(as & 0x1);
        uint8_t  in_auth = (uint8_t)((as >> 1) & 0x1);
        uint8_t  evt    = (uint8_t)((as >> 2) & 0x7u);     /* 事件类型：锁存，报过一次警就保持 1 */

        /* --- 3.6 刷新 OSD 文字（三行，把该显示的都显示出来）--- */
        uint8_t c;                       /* 当前写入列号 */

        /* 第 0 行：环境量（对齐后的值 + 原始湿度）*/
        osd_line_str(0, "T=");
        c = osd_line_x10(0, 2, last_env_aligned, 1);
        c = osd_line_str_cont(0, c, "C RH=");
        c = osd_line_x10(0, c, rh / 10, 1);
        c = osd_line_str_cont(0, c, "% ENV_ALIGNED");
        (void)c;

        /* 第 1 行：红外 + 运动 + 质心 */
        osd_line_str(1, "IR=");
        c = osd_line_x10(1, 3, body_max_t, 1);
        c = osd_line_str_cont(1, c, "C MOT=");
        osd_putc((uint8_t)(1 * OSD_TXT_COLS + c++), (char)('0' + (motion ? 1 : 0)));
        c = osd_line_str_cont(1, c, " AREA=");
        c = osd_line_x10(1, c, (int32_t)area, 0);
        c = osd_line_str_cont(1, c, " C=(");
        c = osd_line_x10(1, c, cx, 0);
        osd_putc((uint8_t)(1 * OSD_TXT_COLS + c++), ',');
        c = osd_line_x10(1, c, cy, 0);
        osd_putc((uint8_t)(1 * OSD_TXT_COLS + c++), ')');
        (void)c;

        /* 第 2 行：事件类型 + 综合得分 + 三路置信度分解（赛题要求显示事件类型和置信度）*/
        if (alarm) {
            osd_line_str(2, "EVT=INTRUDE S=");
            c = osd_line_x10(2, 15, score, 2);
        } else if (in_auth) {
            osd_line_str(2, "EVT=none   S=");
            c = osd_line_x10(2, 15, score, 2);
        } else {
            osd_line_str(2, "EVT=none(auth hours) S=");
            c = osd_line_x10(2, 25, score, 2);
        }
        c = osd_line_str_cont(2, c, " V/T/E=");
        c = osd_line_x10(2, c, conf_v, 0);
        osd_putc((uint8_t)(2 * OSD_TXT_COLS + c++), '/');
        c = osd_line_x10(2, c, conf_t, 0);
        osd_putc((uint8_t)(2 * OSD_TXT_COLS + c++), '/');
        c = osd_line_x10(2, c, conf_e, 0);
        (void)c;

        /* --- 3.7 串口打印 ---
         * 三行：
         *   第 1 行 = 原来的环境/红外/得分（保持不变，别破坏已有脚本的解析）
         *   第 2 行 = ★ 报警判据行：alarm / in_auth_window / evt_type 摊开 + 完整 ALARM_ST
         *             + 固件实际写进硬件的阈值与授权时段（0x38/0x3C 只写、读不回来）
         *   第 3 行 = ★ 写通路握手计数 + 完整融合字 + 视觉字节
         *   两行的判据表都见 docs\上板判据-写通路握手计数.md
         */
        uart_puts("T=");   uart_put_x10(ambient_t / 10);
        uart_puts("C RH="); uart_put_x10(rh / 10);
        uart_puts("% IR="); uart_put_x10(body_max_t / 10);
        uart_puts("C score="); uart_put_x10((int32_t)score * 1000 / 256);   /* Q8 → 千分位 */
        uart_puts(alarm ? "  ALARM!\r\n" : "\r\n");

        /* ---- 报警判据行 ----
         * 为什么必须打：alarm = (score >= 阈值) && in_auth_window，而固件把 hour 写成 0
         * ⇒ in_auth_window 恒真，于是"有没有报警"完全取决于 hardware 的 score。
         * 把三个字段摊开 + 回显阈值/时段，才能定性到底是
         *   ① 打印字段没反映真实 score，还是 ② 硬件在无图像时给了高分。
         * ⚠️ 这里**不能**再读 0x2C：bit0 是读清锁存位，第二次读会变成 0（假"无报警"）。
         *    所以只用上面那一次读到的 as。 */
        uart_puts("ALM=");   uart_putc((char)('0' + (alarm  ? 1 : 0)));
        uart_puts(" AUTH="); uart_putc((char)('0' + (in_auth ? 1 : 0)));
        uart_puts(" EVT=");  uart_putc((char)('0' + evt));
        uart_puts(" ST=");   uart_put_hex32(as);
        uart_puts(" thr=");  uart_put_u32(cfg_thr);
        uart_puts(" hr=");   uart_put_u32(cfg_hour);
        uart_puts(" auth");  uart_put_u32(cfg_auth_beg);
        uart_puts("-");      uart_put_u32(cfg_auth_end);
        uart_puts("\r\n");

        {
            /* 计数器只增不减；打印"本次与上次之差"最能说明问题（绝对值可能是很久以前攒的）*/
            static uint32_t last_aw = 0, last_w = 0;
            uint32_t aw = MMT_REG32(MMT_FB_AW_CNT);
            uint32_t w  = MMT_REG32(MMT_FB_W_CNT);
            uint32_t st = MMT_REG32(MMT_FB_WR_STAT);
            uint32_t vw = MMT_REG32(MMT_VISION_WORD);
            uint32_t fc = MMT_REG32(MMT_FRAME_TGL_CNT);
            static uint32_t last_fc = 0;

            uart_puts("[WR] AW="); uart_put_u32(aw);
            uart_puts("(d=");      uart_put_u32(aw - last_aw); uart_puts(")");
            uart_puts(" W=");      uart_put_u32(w);
            uart_puts("(d=");      uart_put_u32(w - last_w);  uart_puts(")");
            uart_puts(" st=");     uart_put_hex8((uint8_t)(st & 0x3Fu));  /* bit0..3 电平, bit4/5 曾握手 */
            last_aw = aw; last_w = w;

            uart_puts(" FRM="); uart_put_u32(fc);
            uart_puts("(d=");   uart_put_u32(fc - last_fc); uart_puts(")");
            last_fc = fc;

            /* [FS] 按**真实位置**打（vis_bit 是 0x28 里唯一有效的视觉位；t/e 用 [30:23]/[22:15]）*/
            uart_puts(" [FS] raw="); uart_put_hex32(fs);
            uart_puts(" vis_bit=");  uart_put_hex8(fs_vis_bit);
            uart_puts(" t=");        uart_put_hex8(fs_temp);
            uart_puts(" e=");        uart_put_hex8(fs_env);
            uart_puts(" sc9=");      uart_put_hex32((uint32_t)score);
            uart_puts(" [VW] vis="); uart_put_hex8((uint8_t)(vw >> 24));  /* ★ 完整 8 位视觉字节 */
            uart_puts("\r\n");
        }

        /* --- 3.8 简单节流：主循环跟着 MLX90640 的 2Hz 走 --- */
        for (volatile int i = 0; i < 2000000; i++) { }
    }
}
