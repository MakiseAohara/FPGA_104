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
#include "mmt_tinyml.h"     /* ★ task-27：AI 推理接入（张量布局 + 地址自检 + 加速器探测）*/

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
 * 五b、低功耗场景管理（赛题任务3 ⑤）
 *     无人 → IDLE（降下游负载、不跑 NN、保留温度监测）；有人 → 立即回 ACTIVE。
 *
 *  ⚠️ 与"关闭帧差使能"方案的偏离（读 RTL 后确认的死锁，不是偷懒）：
 *     mmt_frame_diff.v 里 enable=0 时 frame_active 不再拉起 ⇒ frame_done / 帧翻转
 *     位停止翻转，sum_area / motion 冻结在最后一帧。而"有人回来"的唯一判据
 *     就是这路帧差 ⇒ 关掉它，IDLE 永远退不出来。所以 IDLE 态 **MMT_CTRL.bit0 保持 1**。
 *
 *  IDLE 态实际做的事（诚实清单）：
 *   1) 不发任何 TinyML 自定义指令：本固件主循环里本来就没有推理调用
 *      （mmt_tinyml_selftest 只在启动时跑一次且 probe=off）。后续若接推理，
 *      必须放在 `if (!lp_idle)` 内 —— 这里不是"关了硬件"，只是软件不调用。
 *   2) 不刷新热力图（768 次 OSD 寄存器写）；MLX 最高温、SHT30 照常更新。
 *   3) 主循环节流拉长 LP_IDLE_THROTTLE_MUL 倍，降软核轮询/串口/OSD 的负载。
 *  ⚠️ **没有**降低摄像头本身的输出帧率：那要改 cam_i2c_ctrl 的固定 ROM 表，
 *     超出本次范围。摄像头、MIPI、帧缓存写入、帧差硬件在 IDLE 下功耗不变。
 *========================================================================*/
/* 进入 IDLE 所需的连续静止帧数。30 帧 ≈ 1 秒 @30fps 的"确实没人"，
 * 再短易被一次短暂静止误触发，再长则省电收益来得太晚。
 * ⚠️ 数的是软核观察到的帧（见状态机注释），主循环慢时实际时间会更长。 */
#define LP_IDLE_FRAMES        30u
/* 静止面积阈值（帧差掩码像素数）。cfg_min_area=60 是硬件 motion 门槛；
 * 这里取 500 是"明显高于噪声/光照抖动、又远小于一个人体面积"的折中，
 * 需要上板按实际噪声底（空场景 AREA 的最大值）再标定。 */
#define LP_AREA_TH            500u
/* IDLE 态主循环节流倍数。取 2：唤醒延迟只多一个节流周期，仍能及时看到运动。 */
#define LP_IDLE_THROTTLE_MUL  2u

/*========================================================================
 * 五e、★ 两个"不依赖主机输入"的保险（2026-10-15 新增）
 *------------------------------------------------------------------------
 * 背景：上板 checklist 的 M0（测试图案证明 写DDR→读DDR→显示）原本**没有实现通路** ——
 *   `main.c` 从不写 0xC8，也没有任何主机写寄存器的办法（Claude 独立核查确认）。
 *   而 UART RX 是否真的接到 FT4232 的 TX，我们**无法确认**（GPIOL_02，见 mmt.peri.xml）。
 *   所以这里加两条兜底，保证即使串口只能收不能发，或完全不通，也能拿到证据：
 *
 *   1) 开机先开测试图案，跑够 BOOT_PATTERN_ITERS 个主循环周期后自动切回摄像头。
 *      ⇒ 不插摄像头也能在 HDMI 上看到 8 色彩条 + 移动方块（M0 的画面证据），
 *        同时 `[WR] AW/W`、`[AMAX] az=OK` 应该有数可看。
 *      用主循环周期计数而不是时间：板子无 RTC，且循环节拍是软件空转，无法给出精确毫秒。
 *      400 拍 × 每拍约 20~30 ms ≈ 8~12 秒（估计值，上板按实际观感调）。
 *
 *   2) 若始终没有收到任何串口字节，则每 AUTO_SWITCH_FRAMES 个视频帧自动翻转 白天/夜间。
 *      ⇒ 串口 RX 不通时，"切夜间才报警"这一段仍能演示（等待自动翻转即可）。
 *      一旦收到任何字节就永久交出控制权（见 uart_poll_cmd 的 got_cmd）。
 *========================================================================*/
#define BOOT_PATTERN_ITERS    400u
#define AUTO_SWITCH_FRAMES    900u   /* 30fps 时约 30 秒翻转一次 */

/*========================================================================
 * 五c、★ 串口命令：给"非授权时段"一个可变的输入源（2026-10-15 新增）
 *------------------------------------------------------------------------
 * 为什么需要：题目任务2 的入侵检测要判"非授权时段"，但板子**没有 RTC**，
 *   固件原来把 hour 写死 0 ⇒ `in_auth_window` 恒为真（0 < 6），
 *   于是"白天不报警、夜里才报警"根本演示不出来。
 *
 * 为什么选串口而不是按键：UART RX 通路**本来就是通的** ——
 *   `sw\uart.c:98-115` 已有 `uart_rx_ready()/uart_getc()`；
 *   `rtl\mmt\mmt_top.v:189,1543` 与 `rtl\mmt\soc\mmt_soc_subsystem.v:400`
 *   都已把 `i_uart_rxd` 接进 SoC。所以这是**纯固件**改动，
 *   不动 RTL / peri.xml / 引脚约束，零时序风险。
 *   （板上的 KEY1/KEY2 在 GPIOR_21/22，但当前设计未使用，
 *     要用得改 peri.xml + 顶层端口 + 同步器，代价高得多。）
 *
 * 命令（单字符；回车/换行/空格忽略）：
 *   'd'/'D'  白天：hour = 12 → 不在授权时段 → in_auth_window=0 → **不报警**
 *   'n'/'N'  夜间：hour = 23 → 在授权时段   → in_auth_window=1 → **可报警**
 *   '0'..'9' 直接设小时（便于手动试 6 / 22 这样的边界值）
 *   't'      ★ 开测试图案（8 色彩条 + 方块）—— **这是 M0 的关键**：
 *            当前固件原本没有任何办法从主机写 0xC8，导致上板 checklist 的
 *            M0「不插摄像头证明 写DDR→读DDR→显示」根本做不了。补上这条命令后
 *            就能在摄像头不出图时独立验证整条视频通路。
 *   'o'      关测试图案（切回摄像头）
 *   'p'      循环：关 → 彩条 → 纯红 → 纯绿 → 纯蓝 → 关（顺便验证 R/B 有没有交叉）
 *   '+'/'−'  ★ 融合得分阈值 ±8（Q8）。挥手幅度不够时现场压低阈值用；
 *            默认 154，Claude 算过 vprob 需 ≥193（area ≥ ≈1930）才够，
 *            现场可用这条命令把门槛降到能稳定触发。
 *   '?'      打印当前 hour / 阈值 / 测试图案状态
 *========================================================================*/
/* 前置声明：DDR 读回自测（定义在 五g 节，串口命令 'r' 触发）*/
static void ddr_readtest(void);

static void uart_poll_cmd(uint32_t *hour, uint32_t *thr,
                          uint32_t auth_beg, uint32_t auth_end, uint8_t *got_cmd)
{
    static uint8_t pat_step = 0;      /* 0=关 1=彩条 2=红 3=绿 4=蓝 */

    while (uart_rx_ready()) {
        char ch = uart_getc();
        uint8_t changed = 0;
        *got_cmd = 1u;      /* 只要有字节进来，就交出控制权（关掉自动演示兜底）*/

        if (ch == 'd' || ch == 'D')        { *hour = 12u; changed = 1; }
        else if (ch == 'n' || ch == 'N')   { *hour = 23u; changed = 1; }
        else if (ch >= '0' && ch <= '9')   { *hour = (uint32_t)(ch - '0'); changed = 1; }

        /* ---- 测试图案（M0 用；摄像头不出图时的独立视频通路证据）---- */
        else if (ch == 't' || ch == 'T') {
            MMT_TEST_PATTERN_SET(1u, 0u);       /* mode 0 = 8 色彩条 + 移动方块 */
            pat_step = 1u;
            uart_puts("[CMD] test pattern ON  (mode=0 彩条+方块)\r\n");
            continue;
        }
        else if (ch == 'o' || ch == 'O') {
            MMT_TEST_PATTERN_SET(0u, 0u);       /* 切回摄像头 */
            pat_step = 0u;
            uart_puts("[CMD] test pattern OFF (切回摄像头)\r\n");
            continue;
        }
        else if (ch == 'p' || ch == 'P') {
            pat_step = (uint8_t)((pat_step + 1u) % 5u);
            if (pat_step == 0u) {
                MMT_TEST_PATTERN_SET(0u, 0u);
                uart_puts("[CMD] pattern OFF -> 摄像头\r\n");
            } else {
                MMT_TEST_PATTERN_SET(1u, (uint32_t)(pat_step - 1u));
                uart_puts("[CMD] pattern ON mode=");
                uart_put_u32((uint32_t)(pat_step - 1u));
                uart_puts((pat_step == 1u) ? " (0=彩条+方块)\r\n"
                       : (pat_step == 2u) ? " (1=纯红, 该显示红)\r\n"
                       : (pat_step == 3u) ? " (2=纯绿)\r\n"
                                          : " (3=纯蓝)\r\n");
            }
            continue;
        }

        /* ---- DDR 读回自测（可能挂死，见 五g 节说明；串口会先打 [DDRR] 面包屑）---- */
        else if (ch == 'r' || ch == 'R') {
            uart_puts("[CMD] DDR read test start (may hang if AXI read never returns)\r\n");
            ddr_readtest();
            uart_puts("[CMD] DDR read test returned\r\n");
            continue;
        }

        /* ---- 融合阈值现场调节 ---- */
        else if (ch == '+' || ch == '=') {
            if (*thr + 8u <= 255u) *thr += 8u;
            MMT_REG32(MMT_CFG_FUSION) = ((*thr) << 8) | auth_end;
            uart_puts("[CMD] score_thr="); uart_put_u32(*thr); uart_puts("\r\n");
            continue;
        }
        else if (ch == '-' || ch == '_') {
            if (*thr >= 8u) *thr -= 8u; else *thr = 0u;
            MMT_REG32(MMT_CFG_FUSION) = ((*thr) << 8) | auth_end;
            uart_puts("[CMD] score_thr="); uart_put_u32(*thr); uart_puts("\r\n");
            continue;
        }

        else if (ch == '?') {
            uart_puts("[CMD] hour="); uart_put_u32(*hour);
            uart_puts(" thr=");       uart_put_u32(*thr);
            uart_puts(" pat=");       uart_put_u32((uint32_t)pat_step);
            uart_puts(" auth=");      uart_put_u32(auth_beg);
            uart_puts("-");           uart_put_u32(auth_end);
            uart_puts("\r\n[CMD] d=day n=night 0-9=hour t=pat-on o=pat-off p=cycle +/-=thr r=ddr-read-test\r\n");
            continue;
        }
        else if (ch == '\r' || ch == '\n' || ch == ' ' || ch == '\t') { continue; }
        else {
            uart_puts("[CMD] ?  d=day n=night 0-9=hour t=pattern-on o=off p=cycle +/-=thr\r\n");
            continue;
        }

        if (changed) {
            /* 0x3C 是只写寄存器，所以每次改完都重写一遍，并把新值回显 */
            MMT_REG32(MMT_CFG_AUTH) = auth_beg | ((*hour) << 8);
            uart_puts("[CMD] hour="); uart_put_u32(*hour);
            uart_puts(" -> window "); uart_put_u32(auth_beg);
            uart_puts("-");           uart_put_u32(auth_end);
            /* 与 RTL 的窗口判定同构（支持跨零点）：[beg,24) ∪ [0,end) */
            uart_puts(((*hour) >= auth_beg || (*hour) < auth_end)
                      ? "  IN-WINDOW (可报警)\r\n" : "  OUT-OF-WINDOW (不报警)\r\n");
        }
    }
}

/*========================================================================
 * 五d、传感器数据预处理：异常值剔除 + 滑动平均（赛题任务1）
 *------------------------------------------------------------------------
 * 数据流（每路传感器一个 pre_filter_t，全定点）：
 *     原始样本 ──► 异常值剔除 ──通过──► N 点滑动平均窗 ──► 滤后值
 *                    │
 *                    └─ |新值 - 上次有效值| > 阈值 ⇒ 丢弃：不入窗、不更新 last、
 *                       rej 计数 +1，本次返回当前窗均值（输出保持不变）
 *
 * 阈值**必须按各路单位传入**（不要写死）：
 *     SHT30 环境温度 ×100 → PRE_THR_AMB = 500 （5.00 ℃）
 *     MLX90640 最高温 ×10 → PRE_THR_BODY = 150（15.0 ℃）
 *
 * 首个样本无条件接受（has_last=0），否则永远建立不了基线；
 * 因此上电后不会出现"假初始温度"导致的 OSD 跳变。
 *
 * ⚠️ 防死锁：纯"与上次有效值比"有个固有缺陷 —— 真实温度阶跃超过阈值时
 *    （例如换了个很烫的目标），新值会被连续丢弃、基线永远追不上。
 *    所以连续丢弃 PRE_RESYNC 次后，认定是真实变化：清空窗口并以该样本重建基线。
 *========================================================================*/
#define PRE_N          4          /* 滑动平均窗口长度（2 的幂只是巧合，除法按实际点数）*/
#define PRE_RESYNC     8u         /* 连续被剔除这么多次 ⇒ 重新锁定基线 */
#define PRE_THR_AMB    500        /* 环境温度阈值：×100 单位，5.00 ℃ */
#define PRE_THR_BODY   150        /* 体温阈值：×10 单位，15.0 ℃ */

typedef struct {
    int32_t  buf[PRE_N];          /* 滑动窗（环形）*/
    int32_t  sum;                 /* 窗内和，增量维护，免得每次重算 */
    int32_t  last;                /* 上次有效值 */
    int32_t  raw;                 /* 最近一次送入的原始值（遥测用）*/
    int32_t  out;                 /* 最近一次滤后值 */
    uint32_t rej;                 /* 累计剔除次数 */
    uint8_t  n;                   /* 窗内现有点数（<PRE_N 时按实际点数平均）*/
    uint8_t  w;                   /* 下一个写入位置 */
    uint8_t  has_last;            /* 0=尚无基线，首个样本无条件接受 */
    uint8_t  bad_run;             /* 连续被剔除次数 */
} pre_filter_t;

static void pre_init(pre_filter_t *p)
{
    for (uint8_t i = 0; i < PRE_N; i++) p->buf[i] = 0;
    p->sum = 0; p->last = 0; p->raw = 0; p->out = 0; p->rej = 0;
    p->n = 0; p->w = 0; p->has_last = 0; p->bad_run = 0;
}

/* 送入一个样本，返回滤后值。thr 与样本同单位。 */
static int32_t pre_push(pre_filter_t *p, int32_t v, int32_t thr)
{
    p->raw = v;
    if (p->has_last) {
        int32_t d = v - p->last;
        if (d < 0) d = -d;
        if (d > thr) {
            p->bad_run++;
            if (p->bad_run < PRE_RESYNC) {
                p->rej++;
                return p->out;            /* 丢弃：窗口与 last 都不动 */
            }
            /* 连续异常达上限 ⇒ 视为真实阶跃，清窗重建基线（本样本接受）*/
            p->n = 0; p->w = 0; p->sum = 0;
        }
    }
    p->bad_run = 0;
    if (p->n == PRE_N) p->sum -= p->buf[p->w];   /* 窗满：挤掉最旧的 */
    else               p->n++;
    p->buf[p->w] = v;
    p->sum += v;
    p->w = (uint8_t)((p->w + 1u) % PRE_N);
    p->last = v;
    p->has_last = 1;
    p->out = p->sum / (int32_t)p->n;
    return p->out;
}

/*========================================================================
 * 五f、★ 开机 DDR 读写自测（定位「frame_buffer 写通路 0 个 DDR 写」，2026-10-15）
 *------------------------------------------------------------------------
 * 目的：区分
 *   A：SoC → AXI 互联 → DDR3 这条主口本身就是死的
 *   B：主口是好的，只有 frame_buffer 那条写通路死了
 * 做法：用 volatile 指针在 R7 张量区起点 0x03000000 写 8 个互不相同的魔数，
 *   D-cache 失效后再读回比对（SoC 的 D-cache 是 write-through，读之前必须先失效，
 *   否则读到的是 cache 里刚写的值，会得到假 PASS —— 见 mmt_tinyml_flush_dcache）。
 *   选 0x03000000 是为了避开视频帧区 0x02000000–0x02BDDE00，不会踩 frame_buffer。
 *   ⚠️ DDR 域基址 0 属推断（--ddrASize 0xe0000000），所以不测 0 地址。
 *
 * ★ 防挂死的取舍（最重要，必读）：
 *   软核上**没有任何可用的超时手段**：没有已知的硬件定时器/看门狗，也没有开中断；
 *   一条 load 如果 AXI 一直不返回 rvalid，CPU 流水线就停在这条指令上，软件根本
 *   没机会"数次数后放弃"。所以「带超时的读」在本固件里**做不到**，不假装能做。
 *   因此按任务书的退让方案：
 *     · 默认 DDR_TEST_READ=0 ⇒ **只写不读**。写走 write-through 的写缓冲，
 *       通常不会因对端无响应而阻塞（但**不是绝对保证**：写缓冲满后也可能停）。
 *       这一档只能说明"写指令发得出去"，**不能证明数据真的落进了 DDR**。
 *     · 把 DDR_TEST_READ 改成 1 才会读回。此时若 DDR 无响应固件会停在读上，
 *       但每次读之前都先打印 `rd@地址`，所以挂死位置可从串口最后一行读出；
 *       复位后改回 0 即可恢复。读回挂死本身就是"路径 A（主口死）"的强证据。
 *   两档都在**每个阶段之前**先打印进度，保证无论卡在哪都有面包屑。
 *========================================================================*/
#define DDR_TEST_BASE   0x03000000u    /* = MMT_TENSOR_BASE，R7 区起点 */
#define DDR_TEST_N      8u
#define DDR_TEST_READ   0              /* 0=只写不读(安全)  1=写后读回(DDR 无响应则挂死) */

/* 第 i 个测试字：前 4 个固定魔数，后 4 个 = 地址 ^ 常数（保证各字互异、且带地址信息）*/
static uint32_t ddr_test_pat(uint32_t i)
{
    static const uint32_t fixed[4] = { 0xDEADBEEFu, 0xC0DEF00Du, 0x55AA55AAu, 0xAA55AA55u };
    if (i < 4u) return fixed[i];
    return (DDR_TEST_BASE + i * 4u) ^ 0xA5C3E1F0u;
}

static void ddr_selftest(void)
{
    volatile uint32_t *p = (volatile uint32_t *)DDR_TEST_BASE;
    uint32_t i;

    /* 面包屑 1：写之前先报范围。若固件停在这一行之后，说明**写**就挂了 */
    uart_puts("[DDR] wr "); uart_put_hex32(DDR_TEST_BASE);
    uart_puts(".."); uart_put_hex32(DDR_TEST_BASE + (DDR_TEST_N - 1u) * 4u);
    uart_puts(" ...\r\n");

    for (i = 0; i < DDR_TEST_N; i++) p[i] = ddr_test_pat(i);

    /* 让写真正发出去 + 使 D-cache 失效（读必须回 DDR，不能命中 cache）*/
    mmt_tinyml_flush_dcache();

#if DDR_TEST_READ
    uint32_t rd[DDR_TEST_N];
    uint32_t badmask = 0u;         /* 每字 4 位，bit(4*i+b)=第 i 个字的第 b 字节不符 */

    for (i = 0; i < DDR_TEST_N; i++) {
        /* 面包屑 2：每次读之前先打地址。固件停在哪个 rd@ 后面，DDR 读就挂在哪 */
        uart_puts("[DDR] rd@"); uart_put_hex32(DDR_TEST_BASE + i * 4u); uart_puts("\r\n");
        rd[i] = p[i];
        uint32_t x = rd[i] ^ ddr_test_pat(i);
        for (uint32_t b = 0; b < 4u; b++)
            if ((x >> (8u * b)) & 0xFFu) badmask |= 1u << (4u * i + b);
    }

    uart_puts("[DDR] addr="); uart_put_hex32(DDR_TEST_BASE);
    uart_puts(" wr=");
    for (i = 0; i < DDR_TEST_N; i++) { if (i) uart_putc(','); uart_put_hex32(ddr_test_pat(i)); }
    uart_puts(" rd=");
    for (i = 0; i < DDR_TEST_N; i++) { if (i) uart_putc(','); uart_put_hex32(rd[i]); }
    uart_puts(" bytes=");  uart_puts(badmask ? "FAIL" : "PASS");
    uart_puts(" badmask="); uart_put_hex32(badmask);
    uart_puts(" hang_at=none(read completed)\r\n");
#else
    uart_puts("[DDR] addr="); uart_put_hex32(DDR_TEST_BASE);
    uart_puts(" wr=");
    for (i = 0; i < DDR_TEST_N; i++) { if (i) uart_putc(','); uart_put_hex32(ddr_test_pat(i)); }
    uart_puts(" rd=SKIP(DDR_TEST_READ=0) bytes=UNTESTED");
    uart_puts(" hang_at=none(write returned; data NOT verified)\r\n");
#endif
}

/*========================================================================
 * 五g、★ DDR 读回自测 —— 由串口命令 'r' 触发，不自动跑
 *------------------------------------------------------------------------
 * 为什么单独做成命令、而不是开机自动跑：
 *   固件没有任何超时/看门狗机制。如果 AXI 读不返回数据，这条 load 会把 CPU
 *   永久卡死（Claude 独立核查后确认软核上没有可用的定时器）。
 *   做成命令 ⇒ 触发之前主循环的遥测（[WR]/[CAM]/[VID]/[LP]）已经跑起来，
 *   即使随后挂死，我们已经拿到全部需要的证据；而且**"串口停在哪个 rd@ 之后"
 *   本身就是结论** —— 说明 SoC 主口到 DDR3 这条路不通。
 * 判读：
 *   bytes=PASS                     ⇒ SoC→互联→DDR3 主口是通的 ⇒ 问题在 frame_buffer 写侧
 *   bytes=FAIL（看 badmask）        ⇒ 主口通但数据不对
 *   串口停在某个 [DDRR] rd@0x… 之后 ⇒ 主口读无响应（挂死），复位重烧即可恢复
 *========================================================================*/
static void ddr_readtest(void)
{
    volatile uint32_t *p = (volatile uint32_t *)DDR_TEST_BASE;
    uint32_t i, badmask = 0u;
    uint32_t rdv[DDR_TEST_N];

    uart_puts("[DDRR] write "); uart_put_hex32(DDR_TEST_BASE);
    uart_puts(" .. "); uart_put_hex32(DDR_TEST_BASE + (DDR_TEST_N - 1u) * 4u);
    uart_puts(" ...\r\n");

    for (i = 0; i < DDR_TEST_N; i++) p[i] = ddr_test_pat(i);
    mmt_tinyml_flush_dcache();

    for (i = 0; i < DDR_TEST_N; i++) {
        /* 面包屑：固件停在哪个 rd@ 后面，读就挂在哪 */
        uart_puts("[DDRR] rd@"); uart_put_hex32(DDR_TEST_BASE + i * 4u); uart_puts("\r\n");
        rdv[i] = p[i];
        uint32_t x = rdv[i] ^ ddr_test_pat(i);
        for (uint32_t b = 0; b < 4u; b++)
            if ((x >> (8u * b)) & 0xFFu) badmask |= 1u << (4u * i + b);
    }

    uart_puts("[DDRR] bytes="); uart_puts(badmask ? "FAIL" : "PASS");
    uart_puts(" badmask="); uart_put_hex32(badmask);
    uart_puts(" wr=");
    for (i = 0; i < DDR_TEST_N; i++) { if (i) uart_putc(','); uart_put_hex32(ddr_test_pat(i)); }
    uart_puts(" rd=");
    for (i = 0; i < DDR_TEST_N; i++) { if (i) uart_putc(','); uart_put_hex32(rdv[i]); }
    uart_puts("\r\n");
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
    /* ★ 2026-10-15 改：由 const 变为可变量，串口 '+'/'-' 可现场调节（见 uart_poll_cmd）。
     *   原因：Claude 的演示数学算出 vprob 需 ≥193（area ≈1930）才够 154 这个门槛，
     *   现场挥手幅度不够时会一直不报警。默认仍为 154，上电行为与改动前一致。 */
    uint32_t cfg_thr      = 154u;   /* 融合得分阈值 0.60×256（Q8）*/
    const uint32_t cfg_auth_end = 6u;     /* 授权结束小时 */
    const uint32_t cfg_auth_beg = 22u;    /* 授权开始小时 */
    /* ★ 2026-10-15 改：hour 由 const 变为可变量，由串口命令修改（见 uart_poll_cmd）。
     *   板子没有 RTC，原来写死 0 ⇒ in_auth_window 恒为真（0 < 6），
     *   无法演示"白天不报警、夜里才报警"。现在可用串口在运行时切换。
     *   默认仍为 0，保持上电行为与改动前一致（固件回归不受影响）。 */
    uint32_t cfg_hour     = 0u;           /* 当前小时（0-23），串口可改 */

    MMT_REG32(MMT_CFG_DIFF)    = (cfg_diff_thr << 8);
    MMT_REG32(MMT_CFG_MINAREA) = cfg_min_area;
    MMT_REG32(MMT_CFG_FUSION)  = (cfg_thr << 8) | cfg_auth_end;
    MMT_REG32(MMT_CFG_AUTH)    = cfg_auth_beg | (cfg_hour << 8);
    MMT_REG32(MMT_CTRL)        = 0x1;     /* 帧差使能，不冻结、不清、不静音 */

    /* ---- 2c. ★ 开机测试图案（M0 的画面证据，见 五e 说明）----
     * 先开彩条+方块，跑够 BOOT_PATTERN_ITERS 个主循环周期后自动切回摄像头。
     * 固定自动关闭（不受串口命令影响），保证可预测：想再看就再按 't'。 */
    uint32_t boot_iters = 0u;
    uint32_t auto_f     = 0u;     /* 无串口输入时的昼夜翻转计数 */
    uint8_t  auto_demo  = 1u;     /* 收到任何串口字节后置 0，交出控制权 */
    MMT_TEST_PATTERN_SET(1u, 0u);
    uart_puts("[BOOT] test pattern ON (8 color bars + moving box); auto-switch to camera soon\r\n");

    /* ---- 2b. ★ AI 推理接入自检（task-27）----
     *  做两件事，都**不发**"参数写/触发"命令（安全档）：
     *   ① 张量布局：权重/输入/输出/arena 全落 R7，128B 对齐；
     *   ② 地址自检 fail-closed：任一项越界/重叠/对齐不足 ⇒ 打印 err 掩码，
     *      后续任何发命令的路径都会被拒绝（见 mmt_tinyml.h 的安全约定）。
     *  `probe=off` 表示没发自定义指令（默认）；把 mmt_tinyml.c 里的
     *  MMT_TINYML_PROBE_EN 改成 1 才会去读加速器 UUID/数量
     *  （⚠️ 必须先确认加速器已接线，否则那条指令会阻塞）。*/
    mmt_tinyml_selftest();

    /* ---- 2d. ★ DDR 读写自测（见 五f；默认只写不读，防挂死）---- */
    ddr_selftest();

    osd_line_str(0, "MMT terminal booting...");
    osd_line_str(1, "waiting for sensors");
    osd_line_str(2, " ");

    /* ---- 3. 主循环 ---- */
    uint16_t last_ir_frame = 0;
    int32_t  body_max_t    = 0;      /* 画面内最高体温 ×10（原始，未滤波）*/
    int32_t  ambient_t     = 0;      /* 环境温度 ×100（原始，未滤波）*/

    /* 任务1 预处理：滤后值 + 两路滤波器状态（见 五d）。
     * 滤后值初值 0 与改动前 body_max_t/ambient_t 的初值一致；首样本到来即被覆盖。 */
    int32_t  body_f        = 0;      /* 滤后体温 ×10 */
    int32_t  amb_f         = 0;      /* 滤后环境温度 ×100 */
    pre_filter_t pp_amb, pp_body;
    pre_init(&pp_amb);
    pre_init(&pp_body);
    int32_t  rh            = 0;      /* 湿度 ×100 */
    int16_t  temps[768];
    uint8_t  last_frame_tgl = 0xFF;  /* 帧翻转标志初值取一个不可能的值，保证第一帧一定被读 */

    /* 低功耗状态（任务3 ⑤）*/
    uint8_t  lp_idle   = 0;          /* 0=ACTIVE 1=IDLE */
    uint32_t lp_idle_f = 0;          /* 连续静止帧数（运动一出现立刻清 0）*/
    uint32_t lp_ctrl   = 0x1u;       /* MMT_CTRL 影子值（该寄存器读不回，见 [LP] 行注释）*/
    uint8_t  have_temps = 0;         /* temps[] 是否已被 MLX 帧填充过 */

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
        /* --- 3.0 ★ 串口命令 + 两个"不依赖主机输入"的兜底（见 五e 说明）--- */
        {
            uint8_t got_cmd = 0u;
            uart_poll_cmd(&cfg_hour, &cfg_thr, cfg_auth_beg, cfg_auth_end, &got_cmd);
            if (got_cmd) auto_demo = 0u;

            /* 兜底 1：开机测试图案到期自动切回摄像头 */
            if (boot_iters < BOOT_PATTERN_ITERS) {
                boot_iters++;
                if (boot_iters == BOOT_PATTERN_ITERS) {
                    MMT_TEST_PATTERN_SET(0u, 0u);
                    uart_puts("[BOOT] test pattern OFF -> camera\r\n");
                }
            }

            /* 兜底 2：串口 RX 不通时，自动翻转昼夜，保证"切夜间才报警"能演示 */
            if (auto_demo) {
                auto_f++;
                if (auto_f >= AUTO_SWITCH_FRAMES) {
                    auto_f = 0u;
                    cfg_hour = (cfg_hour == 12u) ? 23u : 12u;
                    MMT_REG32(MMT_CFG_AUTH) = cfg_auth_beg | (cfg_hour << 8);
                    uart_puts("[AUTO] hour="); uart_put_u32(cfg_hour);
                    uart_puts((cfg_hour >= cfg_auth_beg || cfg_hour < cfg_auth_end)
                              ? " NIGHT(可报警)\r\n" : " DAY(不报警)\r\n");
                }
            }
        }

        /* --- 3.1 SHT30 温湿度（1Hz，硬件自动采）--- */
        uint32_t st = MMT_REG32(MMT_SHT30_ST);
        if (st & 0x1) {                                   /* data_valid，读清 */
            uint32_t a = MMT_REG32(MMT_SHT30_A);
            ambient_t = (int32_t)(int16_t)(a >> 16);      /* 已 ×100 的温度 */
            rh        = (int32_t)(a & 0xFFFF);
            /* ★ 任务1 预处理：异常值剔除（5.00℃）+ 4 点滑动平均，单位 ×100。
             *   下面写硬件寄存器与存对齐历史用的是**滤后值**（改动前是原始值），
             *   因此融合得分的环境项会随之变化 —— 属预期行为。 */
            amb_f = pre_push(&pp_amb, ambient_t, PRE_THR_AMB);
            /* 硬件给的是 ×100，融合模块要 ×10，换算一下 */
            MMT_REG32(MMT_AMBIENT) = ((uint32_t)(amb_f / 10) & 0xFFFF) | (1u << 16);
            MMT_REG32(MMT_RH_FWD)  = (uint32_t)rh;

            /* 打上视频帧时间戳存进历史（供对齐用）*/
            env_hist[env_hist_w].stamp_ms = frame_ms;
            env_hist[env_hist_w].value    = amb_f / 10;       /* 存 ×10（滤后），与融合一致 */
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
                /* ★ 任务1 预处理：异常值剔除（15.0℃）+ 4 点滑动平均，单位 ×10。
                 *   写硬件与 OSD 第 1 行 IR= 用滤后值（改动前是原始 mx），
                 *   融合得分的体温项会随之变化 —— 属预期行为。 */
                body_f = pre_push(&pp_body, mx, PRE_THR_BODY);
                MMT_REG32(MMT_BODY_TEMP) = ((uint32_t)(body_f & 0xFFFF)) | (1u << 16);

                have_temps = 1;
                /* IDLE 态只更新上面的最高温（保温度监测），跳过热力图刷新（768 次寄存器写，省 I/O）*/
                if (!lp_idle) osd_write_thermal(temps, 768);   /* 刷新热力图小窗 */
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

            /* --- 低功耗状态机（任务3 ⑤）---
             * 只在"新一帧"到来时推进，所以 lp_idle_f 数的是**软核观察到的帧数**
             * （主循环节流慢于帧率时会漏帧，不是严格的相机连续帧）。
             * 判"静止" = !motion && area < LP_AREA_TH。
             *   ACTIVE：连续 LP_IDLE_FRAMES 个静止帧 → IDLE
             *   IDLE  ：一旦 motion || area >= LP_AREA_TH → 立刻回 ACTIVE（滞回，不累计） */
            if (!motion && area < LP_AREA_TH) {
                if (lp_idle_f < 0xFFFFu) lp_idle_f++;
                if (!lp_idle && lp_idle_f >= LP_IDLE_FRAMES) {
                    lp_idle = 1;
                    lp_ctrl = 0x1u;     /* 帧差必须保持使能，见文件顶部 LP 说明 */
                    MMT_REG32(MMT_CTRL) = lp_ctrl;
                }
            } else {
                lp_idle_f = 0;
                if (lp_idle) {
                    lp_idle = 0;
                    lp_ctrl = 0x1u;
                    MMT_REG32(MMT_CTRL) = lp_ctrl;
                    /* 恢复：热力图在 IDLE 期间没刷新，立刻补刷一次（temps 有效才刷）*/
                    if (have_temps) osd_write_thermal(temps, 768);
                }
            }
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
        /* 低功耗标记：只在第 0 行末尾追加 " LP"（第 0 行约 30 列，远小于 48 列，
         * 不会挤掉已有字段；ACTIVE 态不追加，行内容与改动前完全一致）*/
        if (lp_idle) c = osd_line_str_cont(0, c, " LP");
        (void)c;

        /* 第 1 行：红外 + 运动 + 质心 */
        osd_line_str(1, "IR=");
        c = osd_line_x10(1, 3, body_f, 1);          /* 滤后体温（任务1 预处理）*/
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

        /* ---- ★ 预处理遥测行（任务1，紧跟 T= 行；T= 行本身仍打原始值，格式未动）----
         * A=环境温度（SHT30） B=体温（MLX 最高温）；各给 原始/滤后/累计剔除数。
         * thrA 单位 ×100，thrB 单位 ×10（即 5.00℃ / 15.0℃）。 */
        uart_puts("[PP] A raw="); uart_put_x10(pp_amb.raw / 10);
        uart_puts("C flt=");      uart_put_x10(amb_f / 10);
        uart_puts("C rej=");      uart_put_u32(pp_amb.rej);
        uart_puts(" B raw=");     uart_put_x10(pp_body.raw);
        uart_puts("C flt=");      uart_put_x10(body_f);
        uart_puts("C rej=");      uart_put_u32(pp_body.rej);
        uart_puts(" win=");       uart_put_u32(PRE_N);
        uart_puts(" thrA=");      uart_put_u32(PRE_THR_AMB);
        uart_puts("(x100) thrB="); uart_put_u32(PRE_THR_BODY);
        uart_puts("(x10)\r\n");

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

            /* ---- ★ 最大写地址判据（task-22）----
             * amax = 历史最大 fb_awaddr；必须与 asmp/ast 联合读：
             *   asmp = 采样次数（AW 握手次数，饱和）  ast bit0 = 至少采样过一次
             *   ast bit1 = 曾采到非 0 地址
             * 判据（阈值见 docs\上板判据-最大写地址.md）：
             *   [0x02000000, 0x02BDDE00) 且推进 ⇒ 帧步长修复生效
             *   ≥ 0x02FD2400 或落在 [0x02BDDE00,…) ⇒ 仍是 1920 版步长（会写进张量区）
             *   amax=0 且 asmp=0 ⇒ 没出图，**不是**没越界 */
            {
                static uint32_t last_amax = 0;
                uint32_t amax = MMT_REG32(MMT_FB_AWADDR_MAX);
                uint32_t ast  = MMT_REG32(MMT_FB_AW_STAT);
                uint8_t  seen = (uint8_t)((ast >> 16) & 0x1);
                uint8_t  nz   = (uint8_t)((ast >> 17) & 0x1);

                uart_puts(" amax="); uart_put_hex32(amax);
                uart_puts("(d=");    uart_put_hex32(amax - last_amax); uart_puts(")");
                uart_puts(" asmp="); uart_put_u32(ast & 0xFFFFu);
                uart_puts(" ast=");  uart_put_hex8((uint8_t)((seen) | (nz << 1)));
                /* 一眼可辨的结论（省得每次拿计算器比阈值）*/
                uart_puts(" az=");
                if (!seen)                            uart_puts("NOIMG");    /* 没出图 */
                else if (amax >= 0x02FD2400u)         uart_puts("OVER1920"); /* 步长仍是 1920 版 */
                else if (amax >= 0x02BDDE00u)         uart_puts("SUSPECT");  /* 越过约定区间 */
                else if (amax >= 0x02000000u)         uart_puts("OK");
                else                                  uart_puts("LOW");      /* 低于帧缓存基址 */
                last_amax = amax;
            }

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
            uart_puts(" st8=");      uart_put_hex8((uint8_t)(st & 0xFFu)); /* ★ st 完整 8 位（追加在行尾，不动原字段）*/
            uart_puts(" dbg=");      uart_put_hex32(MMT_REG32(MMT_DBG_FB_SB)); /* 0xE0/test_wdata（可信，以此为准）: [31:24]=A5路标 [23]=rst_n [22:20]=free_cnt[25:23] [19:16]=pos_sync计数 [15:13]=wr_fifo_rdusedw[10:8](4=满1024,0=空) [12]=wr_req [11:10]=state [9]=awvalid [8]=awready [7]=sb_st3 [6]=sb_rden [5]=sb_pos_sync [4:0]=sb_wrfull/wrstart/fstable/fstart/wren */
            uart_puts(" fsm=");      uart_put_hex32(MMT_REG32(MMT_DBG_FSM_SB)); /* ddr_wr_buffer dbg_sb（紧凑19位，[18]=rst_n [17:15]=free_cnt [14:11]=pos_sync计数 [10:8]=rdusedw[10:8] [7]=wr_req [6:5]=state [4]=awvalid [3]=awready [2]=sb_st3 [1]=sb_rden [0]=sb_pos_sync）。本通道（0xE4/test_rdata）实测不可信，仅作对照；以 dbg=（0xE0/test_wdata）为准。 */
            uart_puts("\r\n");
        }

        /* ---- ★ 摄像头上游探针行（task-19，第 4 行；task-24 追加若干字段）----
         * 判据（详见 docs\上板判据-摄像头上游探针.md §3）：
         *   SCL 在涨        ⇒ 摄像头 I2C 配置真的在跑（**d=0 是配置完的正常状态**）
         *   CK / PCLK 在涨  ⇒ MIPI 字节/像素时钟在（1 次 = 1024 个源时钟周期）
         *                     ⚠️ PCLK 是 PLL 输出，本来就永远在涨 ⇒ 看 **CK_d/PCLK_d 比值**
         *   DE/HS/VS 在涨   ⇒ ★ CSI RX 真的在吐像素
         *   pd 在涨         ⇒ 像素数据**非全 0**（DE 在跳 ≠ 数据有效）
         *   ack 在涨        ⇒ 从器件**真的应答了**（只看 SCL 分不出这个）
         *   pid 必须是 0x4D4D5450 ⇒ 这版位流里有探针（否则全是 0 也分不清）
         * 全 0 且 st 的 seen 位也为 0 ⇒ 该信号从头到尾没动过。
         * ★ 2026-10-13（task-24 复查后修正）：本块用到的探针宏地址已在
         *   sw\mmt_regs.h 里**全部改正** —— 原先 pid/pd/ack/nk/wmx/rh 这 6 个宏
         *   地址是错的（实际会读成 WC_MAX / ACK_CNT / RST_HS_STAT / 别名的 SCL_CNT
         *   与 CK_CNT）。本文件**不硬编码地址**，全部走宏 ⇒ 宏改对后这里每个值
         *   都来自正确的寄存器，字段名与值一致。修复前后对照见
         *   docs\上板判据-摄像头上游探针.md §7。 */
        {
            static uint32_t l_scl = 0, l_ck = 0, l_pk = 0, l_de = 0, l_hs = 0, l_vs = 0, l_wc = 0;
            static uint32_t l_pd = 0, l_ack = 0, l_nk = 0;
            uint32_t s_scl = MMT_REG32(MMT_CAM_SCL_CNT);
            uint32_t s_ck  = MMT_REG32(MMT_CAM_CK_CNT);
            uint32_t s_pk  = MMT_REG32(MMT_CAM_PCLK_CNT);
            uint32_t s_de  = MMT_REG32(MMT_CSI_DE_CNT);
            uint32_t s_hs  = MMT_REG32(MMT_CSI_HS_CNT);
            uint32_t s_vs  = MMT_REG32(MMT_CSI_VS_CNT);
            uint32_t s_st  = MMT_REG32(MMT_CAM_PROBE_ST);
            uint32_t s_wc  = MMT_REG32(MMT_CSI_WC_CNT);
            uint32_t s_lk  = MMT_REG32(MMT_CSI_LINK_ST);
            uint32_t s_pid = MMT_REG32(MMT_PROBE_ID);
            uint32_t s_pd  = MMT_REG32(MMT_CSI_PD_CNT);
            uint32_t s_ack = MMT_REG32(MMT_I2C_ACK_CNT);
            uint32_t s_nk  = MMT_REG32(MMT_I2C_NACK_CNT);
            uint32_t s_wmx = MMT_REG32(MMT_CSI_WC_MAX);
            uint32_t s_rh  = MMT_REG32(MMT_RST_HS_STAT);

            uart_puts("[CAM] SCL="); uart_put_u32(s_scl);
            uart_puts("(d=");        uart_put_u32(s_scl - l_scl); uart_puts(")");
            uart_puts(" CK=");       uart_put_u32(s_ck);
            uart_puts("(d=");        uart_put_u32(s_ck - l_ck);   uart_puts(")");
            uart_puts(" PCLK=");     uart_put_u32(s_pk);
            uart_puts("(d=");        uart_put_u32(s_pk - l_pk);   uart_puts(")");
            uart_puts(" DE=");       uart_put_u32(s_de);
            uart_puts("(d=");        uart_put_u32(s_de - l_de);   uart_puts(")");
            uart_puts(" HS=");       uart_put_u32(s_hs);
            uart_puts("(d=");        uart_put_u32(s_hs - l_hs);   uart_puts(")");
            uart_puts(" VS=");       uart_put_u32(s_vs);
            uart_puts("(d=");        uart_put_u32(s_vs - l_vs);   uart_puts(")");
            uart_puts(" pd=");       uart_put_u32(s_pd);
            uart_puts("(d=");        uart_put_u32(s_pd - l_pd);   uart_puts(")");
            uart_puts(" ack=");      uart_put_u32(s_ack);
            uart_puts("(d=");        uart_put_u32(s_ack - l_ack); uart_puts(")");
            uart_puts(" nk=");       uart_put_u32(s_nk);
            uart_puts("(d=");        uart_put_u32(s_nk - l_nk);   uart_puts(")");
            uart_puts(" st=");       uart_put_hex32(s_st);
            uart_puts(" wc=");       uart_put_u32(s_wc);
            uart_puts("(d=");        uart_put_u32(s_wc - l_wc);   uart_puts(")");
            uart_puts(" wmx=");      uart_put_u32(s_wmx);
            uart_puts(" link=");     uart_put_hex32(s_lk);
            uart_puts(" pid=");      uart_put_hex32(s_pid);
            uart_puts(" rh=");       uart_put_hex32(s_rh);
            uart_puts("\r\n");

            l_scl = s_scl; l_ck = s_ck; l_pk = s_pk;
            l_de = s_de;   l_hs = s_hs; l_vs = s_vs; l_wc = s_wc;
            l_pd = s_pd;   l_ack = s_ack; l_nk = s_nk;
        }

        /* ---- ★ mux 之后的视频信号（与 frame_buffer 的 i_de/i_vs 是同几根线）----
         * lines=一帧 hs 个数(1080p≈1080)  pixels=一行 de 拍数(4px/拍,≈480)  frames=vs 个数
         * 判据：frames 不涨 ⇒ 断点在 frame_buffer 入口**之前**（mux/测试图案/摄像头）；
         *       frames 涨、lines/pixels 正常，而 [WR] AW 仍为 0 ⇒ 断点在 frame_buffer **内部**或其 AXI 口。
         * testpat = 0xC8 读回低 3 位（bit0=en, [2:1]=mode），确认 't' 命令/开机图案真生效。 */
        {
            static uint32_t l_vf = 0;
            uint32_t v_ln = MMT_REG32(MMT_LINES_PER_FRAME) & 0xFFFFu;
            uint32_t v_px = MMT_REG32(MMT_PIXELS_PER_LINE) & 0xFFFFu;
            uint32_t v_fr = MMT_REG32(MMT_VID_FRAME_CNT)   & 0xFFFFu;
            uint32_t v_tp = MMT_REG32(MMT_TEST_PATTERN)    & 0x7u;
            uart_puts("[VID] lines="); uart_put_u32(v_ln);
            uart_puts(" pixels=");     uart_put_u32(v_px);
            uart_puts(" frames=");     uart_put_u32(v_fr);
            uart_puts("(d=");          uart_put_u32((v_fr - l_vf) & 0xFFFFu); uart_puts(")");
            uart_puts(" testpat=");    uart_put_u32(v_tp);
            uart_puts("\r\n");
            l_vf = v_fr;
        }

        /* ---- ★ 低功耗状态行（任务3 ⑤，放在 [CAM] 行之后，不动已有各行）----
         * ctrl= 打的是**固件影子值**（lp_ctrl），不是读回值：
         *   RTL 的读多路器（mmt_soc_regs.v）里没有 0x48，读 MMT_CTRL 恒为 0，
         *   所以读回没有信息量；影子值 = 固件最后一次写进去的值。 */
        uart_puts("[LP] mode=");  uart_puts(lp_idle ? "IDLE" : "ACTIVE");
        uart_puts(" idle_f=");    uart_put_u32(lp_idle_f);
        uart_puts(" thr=");       uart_put_u32(LP_AREA_TH);
        uart_puts(" enter=");     uart_put_u32(LP_IDLE_FRAMES);
        uart_puts(" ctrl=");      uart_put_hex8((uint8_t)(lp_ctrl & 0xFFu));
        uart_puts("\r\n");

        /* --- 3.8 简单节流：主循环跟着 MLX90640 的 2Hz 走 ---
         * IDLE 态把节流拉长 LP_IDLE_THROTTLE_MUL 倍：降低软核轮询/串口/OSD 的负载。 */
        {
            uint32_t n = 2000000u * (lp_idle ? LP_IDLE_THROTTLE_MUL : 1u);
            for (volatile uint32_t i = 0; i < n; i++) { }
        }
    }
}
