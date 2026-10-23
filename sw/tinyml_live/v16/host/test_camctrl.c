/*==============================================================================
 * test_camctrl.c — 电脑端验证相机寄存器安全访问层（v16）
 *
 * 测试项：
 *  1) 写白名单：非法地址被拒绝（不产生写）
 *  2) 正常写：读旧值 → 写 → 读回校验通过
 *  3) 读回不一致：自动回滚到旧值，并返回 CAM_E_VERIFY
 *  4) 回滚也失败：返回 CAM_E_ROLLBACK
 *  5) VTS 降帧：进入（×mult）与退出（恢复初始）序列、写高字节再写低字节
 *  6) VTS 初始值越界（不在 [0x400,0xa00]）→ 功能禁用且不写
 *  7) 进入过程中写失败 → 恢复初始值并永久禁用
 *  8) 倍数限幅 2..4
 *
 * 编译：gcc -O2 -std=c99 -I.. test_camctrl.c -o test_camctrl
 *============================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cam_ctrl_core.h"

static int errors = 0, checks = 0;
static void check(int cond, const char *name, const char *detail)
{
    ++checks;
    if (cond) printf("PASS %-56s %s\n", name, detail ? detail : "");
    else { ++errors; printf("FAIL %-56s %s\n", name, detail ? detail : ""); }
}

/* ---------------- mock 寄存器 ---------------- */
#define MOCK_N 65536
static unsigned char regs[MOCK_N];
static int wr_count, rd_count;
static int last_wr_reg[64], last_wr_val[64], wr_seq;
static int fail_wr_reg;      /* 写入该地址时静默丢弃（写后读回不一致） */
static int corrupt_wr_reg;   /* 写入该地址时写入被打乱的值（制造读回不一致） */
static int corrupt_once_done;

static void mock_reset(void)
{
    memset(regs, 0, sizeof(regs));
    wr_count = rd_count = 0;
    wr_seq = 0;
    fail_wr_reg = -1;
    corrupt_wr_reg = -1;
    corrupt_once_done = 0;
}

static int mock_rd(void *ctx, unsigned short r, unsigned char *out)
{
    (void)ctx;
    rd_count++;
    *out = regs[r];
    return 0;
}

static int mock_wr(void *ctx, unsigned short r, unsigned char v)
{
    (void)ctx;
    wr_count++;
    if (wr_seq < 64) { last_wr_reg[wr_seq] = (int)r; last_wr_val[wr_seq] = (int)v; }
    wr_seq++;
    if ((int)r == corrupt_wr_reg && !corrupt_once_done) {
        corrupt_once_done = 1;
        regs[r] = (unsigned char)(v ^ 0x01);   /* 第一次写入变脏 */
        return 0;
    }
    if ((int)r == fail_wr_reg) return 0;       /* 后续写入丢弃（回滚失败） */
    regs[r] = v;
    return 0;
}

static cam_io_t io = { mock_rd, mock_wr, 0 };

/* 取最近一次写序列中某寄存器的值（找不到返回 -1） */
static int find_wr(int reg)
{
    int i;
    for (i = wr_seq - 1; i >= 0; --i)
        if (last_wr_reg[i] == reg) return last_wr_val[i];
    return -1;
}

int main(void)
{
    printf("== test_camctrl (v16) ==\n");

    /* ---------------- 1) 白名单 ---------------- */
    mock_reset();
    regs[0x1234] = 0x11;
    {
        const int r = cam_checked_write(&io, 0x1234, 0x22, 0);
        char d[160];
        snprintf(d, sizeof d, "ret=%d wr_count=%d reg=0x%02x", r, wr_count, regs[0x1234]);
        check(r == CAM_E_NOT_ALLOWED && wr_count == 0 && regs[0x1234] == 0x11,
              "non-whitelisted address rejected, no write", d);
    }

    /* ---------------- 2) 正常写 ---------------- */
    mock_reset();
    regs[0x3E01] = 0xAA;
    {
        unsigned char old = 0;
        const int r = cam_checked_write(&io, 0x3E01, 0xBB, &old);
        char d[200];
        snprintf(d, sizeof d, "ret=%d old=0x%02x now=0x%02x wr=%d", r, old, regs[0x3E01], wr_count);
        check(r == CAM_OK && old == 0xAA && regs[0x3E01] == 0xBB,
              "whitelisted write + readback verify", d);
    }

    /* ---------------- 3) 读回不一致 → 回滚 ---------------- */
    mock_reset();
    regs[0x3E08] = 0x33;
    fail_wr_reg = 0x3E08;         /* 写该寄存器时“写丢” */
    {
        unsigned char old = 0;
        const int r = cam_checked_write(&io, 0x3E08, 0x44, &old);
        char d[220];
        snprintf(d, sizeof d, "ret=%d old=0x%02x reg=0x%02x wr=%d (expect VERIFY+rollback)",
                 r, old, regs[0x3E08], wr_count);
        check(r == CAM_E_VERIFY && regs[0x3E08] == 0x33,
              "verify mismatch -> rolled back to old value", d);
    }

    /* ---------------- 4) 回滚也失败 ---------------- */
    mock_reset();
    regs[0x3E09] = 0x77;
    corrupt_wr_reg = 0x3E09;   /* 第一次写入变脏 → 读回不一致 */
    fail_wr_reg = 0x3E09;      /* 回滚写入也丢弃 → 回滚失败 */
    {
        const int r = cam_checked_write(&io, 0x3E09, 0x88, 0);
        char d[200];
        snprintf(d, sizeof d, "ret=%d reg=0x%02x wr=%d", r, regs[0x3E09], wr_count);
        check(r == CAM_E_ROLLBACK, "rollback failure reported (CAM_E_ROLLBACK)", d);
    }

    /* ---------------- 5) VTS 进入/退出 ---------------- */
    mock_reset();
    regs[CAM_REG_VTS_H] = 0x05;
    regs[CAM_REG_VTS_L] = 0xDC;   /* 1500 = 0x5dc */
    {
        cam_lp_t lp;
        const int r = cam_lp_init(&io, &lp);
        char d[200];
        snprintf(d, sizeof d, "init_ret=%d vts_init=0x%04x wr=%d", r, lp.vts_init, wr_count);
        check(r == CAM_OK && lp.vts_init == 0x05DC && lp.inited == 1 && lp.disabled == 0,
              "VTS init reads 0x05dc and enables LP", d);
    }
    {
        cam_lp_t lp;
        int r1, r2;
        cam_lp_init(&io, &lp);
        wr_seq = 0; wr_count = 0;
        r1 = cam_lp_enter(&io, &lp, 3);
        {
            char d[240];
            const int hi = find_wr(CAM_REG_VTS_H), lo = find_wr(CAM_REG_VTS_L);
            snprintf(d, sizeof d, "enter_ret=%d new_vts=0x%04x hi=0x%02x lo=0x%02x wr=%d",
                     r1, (unsigned)(hi << 8 | (lo < 0 ? 0 : lo)), hi, lo, wr_count);
            check(r1 == CAM_OK && hi == 0x11 && lo == 0x94 && lp.mult == 3,
                  "LP enter writes VTS x3 (0x05dc->0x1194) high-then-low", d);
        }
        r2 = cam_lp_exit(&io, &lp);
        {
            char d[200];
            snprintf(d, sizeof d, "exit_ret=%d vts_h=0x%02x vts_l=0x%02x mult=%d",
                     r2, regs[CAM_REG_VTS_H], regs[CAM_REG_VTS_L], lp.mult);
            check(r2 == CAM_OK && regs[CAM_REG_VTS_H] == 0x05 && regs[CAM_REG_VTS_L] == 0xDC &&
                  lp.mult == 1,
                  "LP exit restores initial VTS", d);
        }
    }

    /* ---------------- 6) VTS 越界 → 禁用 ---------------- */
    mock_reset();
    regs[CAM_REG_VTS_H] = 0x03;   /* 0x0300 < 0x0400 */
    regs[CAM_REG_VTS_L] = 0x00;
    {
        cam_lp_t lp;
        const int r = cam_lp_init(&io, &lp);
        const int r2 = cam_lp_enter(&io, &lp, 3);
        char d[200];
        snprintf(d, sizeof d, "init_ret=%d disabled=%d enter_ret=%d wr=%d",
                 r, lp.disabled, r2, wr_count);
        check(r == CAM_E_DISABLED && lp.disabled == 1 && r2 == CAM_E_DISABLED && wr_count == 0,
              "VTS out of [0x0400,0xa00] -> disabled, no writes", d);
    }

    /* ---------------- 7) 进入写失败 → 恢复并永久禁用 ---------------- */
    mock_reset();
    regs[CAM_REG_VTS_H] = 0x05;
    regs[CAM_REG_VTS_L] = 0xDC;
    fail_wr_reg = CAM_REG_VTS_L;   /* 低字节写丢 → 读回不一致 */
    {
        cam_lp_t lp;
        int r;
        cam_lp_init(&io, &lp);
        r = cam_lp_enter(&io, &lp, 3);
        {
            char d[240];
            snprintf(d, sizeof d, "enter_ret=%d disabled=%d restored=0x%02x%02x",
                     r, lp.disabled, regs[CAM_REG_VTS_H], regs[CAM_REG_VTS_L]);
            check(r == CAM_E_DISABLED && lp.disabled == 1 &&
                  regs[CAM_REG_VTS_H] == 0x05 && regs[CAM_REG_VTS_L] == 0xDC,
                  "LP enter write failure -> restore + disable", d);
        }
    }

    /* ---------------- 8) 倍数限幅 2..4 ---------------- */
    mock_reset();
    regs[CAM_REG_VTS_H] = 0x05;
    regs[CAM_REG_VTS_L] = 0xDC;
    {
        cam_lp_t lp;
        int hi_lo, hi_hi;
        cam_lp_init(&io, &lp);
        (void)cam_lp_enter(&io, &lp, 9);      /* 应被限到 4 */
        hi_lo = regs[CAM_REG_VTS_H];
        hi_hi = regs[CAM_REG_VTS_L];
        {
            char d[220];
            const unsigned vts = ((unsigned)hi_lo << 8) | hi_hi;
            snprintf(d, sizeof d, "request x9 -> vts=0x%04x mult=%d (expect 0x1770,4)", vts, lp.mult);
            check(lp.mult == 4 && vts == 0x1770, "multiplier clamped to 4", d);
        }
    }
    mock_reset();
    regs[CAM_REG_VTS_H] = 0x05;
    regs[CAM_REG_VTS_L] = 0xDC;
    {
        cam_lp_t lp;
        cam_lp_init(&io, &lp);
        (void)cam_lp_enter(&io, &lp, 1);      /* 应被限到 2 */
        {
            char d[220];
            const unsigned vts = ((unsigned)regs[CAM_REG_VTS_H] << 8) | regs[CAM_REG_VTS_L];
            snprintf(d, sizeof d, "request x1 -> vts=0x%04x mult=%d (expect 0x0bb8,2)", vts, lp.mult);
            check(lp.mult == 2 && vts == 0x0BB8, "multiplier clamped to 2", d);
        }
    }

    printf("\n== test_camctrl: %d checks, %d errors ==\n", checks, errors);
    printf("%s\n", errors ? "RESULT FAIL" : "RESULT PASS");
    return errors ? 1 : 0;
}
