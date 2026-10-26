/*==============================================================================
 * cam_ctrl_core.h — 相机寄存器安全访问层（v16，纯 C，可在电脑上单独测试）
 *
 * 规则（任务书功能 1 / 3）：
 *   1) 写白名单：只允许 0x320e/0x320f(VTS)、0x3e00..0x3e03(曝光/模式)、
 *      0x3e08/0x3e09(增益)；其它地址一律拒绝；
 *   2) 每次写入前先读旧值，写后读回确认；不一致则回滚旧值并报错；
 *   3) VTS 降帧：仅当启动读出的 VTS 落在 [0x0400, 0x0a00] 才启用；
 *      倍数限制 2..4；写失败/读回不一致 → 恢复初始值并永久关闭；
 *   4) 所有 I/O 通过 cam_io_t 回调，固件用 APB 实现，电脑端测试用 mock。
 *============================================================================*/
#ifndef CAM_CTRL_CORE_H
#define CAM_CTRL_CORE_H

#define CAM_REG_VTS_H     0x320E
#define CAM_REG_VTS_L     0x320F
#define CAM_REG_EXP_H     0x3E00
#define CAM_REG_EXP_M     0x3E01
#define CAM_REG_EXP_L     0x3E02
#define CAM_REG_MODE      0x3E03
#define CAM_REG_GAIN_C    0x3E08   /* coarse gain */
#define CAM_REG_GAIN_F    0x3E09   /* fine gain   */

#define CAM_VTS_MIN_OK    0x0400
#define CAM_VTS_MAX_OK    0x0A00
#define CAM_VTS_HW_MAX    0x7FF0    /* SC431HAI 手册：最大帧长 0x7ff0 */
#define CAM_LP_MULT_MIN   2
#define CAM_LP_MULT_MAX   4

/* 错误码 */
#define CAM_OK             0
#define CAM_E_NOT_ALLOWED -1
#define CAM_E_RD_FAIL     -2
#define CAM_E_WR_FAIL     -3
#define CAM_E_VERIFY      -4   /* 读回不一致（已尝试回滚） */
#define CAM_E_ROLLBACK    -5   /* 读回不一致且回滚也失败 */
#define CAM_E_DISABLED    -6   /* 该功能已被保护逻辑永久关闭 */
#define CAM_E_RANGE       -7   /* 参数/范围非法 */

typedef struct {
    int (*rd)(void *ctx, unsigned short reg, unsigned char *out);   /* 0=ok */
    int (*wr)(void *ctx, unsigned short reg, unsigned char val);    /* 0=ok */
    void *ctx;
} cam_io_t;

/* 写白名单 */
static int cam_whitelisted(unsigned short reg)
{
    switch (reg) {
    case CAM_REG_VTS_H: case CAM_REG_VTS_L:
    case CAM_REG_EXP_H: case CAM_REG_EXP_M: case CAM_REG_EXP_L:
    case CAM_REG_MODE:
    case CAM_REG_GAIN_C: case CAM_REG_GAIN_F:
        return 1;
    default:
        return 0;
    }
}

/* 单字节安全写：白名单 → 读旧值 → 写 → 读回校验 → 失败回滚
 * 返回 CAM_OK / CAM_E_*；old_out 返回写入前旧值（可为 0）
 */
static int cam_checked_write(cam_io_t *io, unsigned short reg,
                             unsigned char val, unsigned char *old_out)
{
    unsigned char old = 0, rb = 0;
    if (!io || !io->rd || !io->wr) return CAM_E_RD_FAIL;
    if (!cam_whitelisted(reg)) return CAM_E_NOT_ALLOWED;
    if (io->rd(io->ctx, reg, &old) != 0) return CAM_E_RD_FAIL;
    if (old_out) *old_out = old;
    if (io->wr(io->ctx, reg, val) != 0) return CAM_E_WR_FAIL;
    if (io->rd(io->ctx, reg, &rb) != 0) return CAM_E_RD_FAIL;
    if (rb != val) {
        /* 回滚旧值，再确认一次 */
        if (io->wr(io->ctx, reg, old) != 0) return CAM_E_ROLLBACK;
        if (io->rd(io->ctx, reg, &rb) != 0 || rb != old) return CAM_E_ROLLBACK;
        return CAM_E_VERIFY;
    }
    return CAM_OK;
}

/* 读 16 位 VTS：{0x320e[6:0], 0x320f} */
static int cam_vts_read(cam_io_t *io, unsigned int *vts)
{
    unsigned char h = 0, l = 0;
    if (!io || !io->rd) return CAM_E_RD_FAIL;
    if (io->rd(io->ctx, CAM_REG_VTS_H, &h) != 0) return CAM_E_RD_FAIL;
    if (io->rd(io->ctx, CAM_REG_VTS_L, &l) != 0) return CAM_E_RD_FAIL;
    *vts = ((unsigned int)(h & 0x7F) << 8) | (unsigned int)l;
    return CAM_OK;
}

/* 写 16 位 VTS（高字节只取 0x7f）：两次单字节安全写 */
static int cam_vts_write(cam_io_t *io, unsigned int vts)
{
    int r;
    if (vts > CAM_VTS_HW_MAX) return CAM_E_RANGE;
    r = cam_checked_write(io, CAM_REG_VTS_H, (unsigned char)((vts >> 8) & 0x7F), 0);
    if (r != CAM_OK) return r;
    r = cam_checked_write(io, CAM_REG_VTS_L, (unsigned char)(vts & 0xFF), 0);
    return r;
}

typedef struct {
    int inited;             /* 启动时已读到合法 VTS 并启用 */
    int disabled;           /* 保护逻辑永久关闭 */
    unsigned int vts_init;  /* 启动时的 VTS（恢复目标） */
    int mult;               /* 当前生效倍数（1=未降帧） */
} cam_lp_t;

static int cam_lp_valid_vts(unsigned int vts)
{
    return (vts >= CAM_VTS_MIN_OK && vts <= CAM_VTS_MAX_OK) ? 1 : 0;
}

/* 启动初始化：读 VTS 并判定是否允许降帧。
 * 返回 CAM_OK=允许；CAM_E_DISABLED=不允许（已置 disabled，原因见 vts_init 判定）
 */
static int cam_lp_init(cam_io_t *io, cam_lp_t *lp)
{
    unsigned int vts = 0;
    lp->inited = 0;
    lp->disabled = 0;
    lp->vts_init = 0;
    lp->mult = 1;
    if (cam_vts_read(io, &vts) != CAM_OK) { lp->disabled = 1; return CAM_E_DISABLED; }
    lp->vts_init = vts;
    if (!cam_lp_valid_vts(vts)) { lp->disabled = 1; return CAM_E_DISABLED; }
    lp->inited = 1;
    return CAM_OK;
}

/* 进入低功耗：VTS × mult（限制 2..4）；写失败/校验失败 → 恢复初始值并永久关闭 */
static int cam_lp_enter(cam_io_t *io, cam_lp_t *lp, int mult)
{
    unsigned int target = 0, rb = 0;
    int r;
    if (!lp->inited || lp->disabled) return CAM_E_DISABLED;
    if (mult < CAM_LP_MULT_MIN) mult = CAM_LP_MULT_MIN;
    if (mult > CAM_LP_MULT_MAX) mult = CAM_LP_MULT_MAX;
    target = lp->vts_init * (unsigned int)mult;
    if (target > CAM_VTS_HW_MAX) target = CAM_VTS_HW_MAX;
    r = cam_vts_write(io, target);
    if (r == CAM_OK && cam_vts_read(io, &rb) == CAM_OK && rb == target) {
        lp->mult = mult;
        return CAM_OK;
    }
    /* 失败：尽量恢复 + 永久关闭 */
    (void)cam_vts_write(io, lp->vts_init);
    lp->disabled = 1;
    lp->mult = 1;
    return CAM_E_DISABLED;
}

/* 退出低功耗：恢复启动时 VTS；失败永久关闭 */
static int cam_lp_exit(cam_io_t *io, cam_lp_t *lp)
{
    unsigned int rb = 0;
    int r;
    if (!lp->inited || lp->disabled) return CAM_E_DISABLED;
    if (lp->mult == 1) return CAM_OK;   /* 未降帧则无需恢复 */
    r = cam_vts_write(io, lp->vts_init);
    if (r == CAM_OK && cam_vts_read(io, &rb) == CAM_OK && rb == lp->vts_init) {
        lp->mult = 1;
        return CAM_OK;
    }
    lp->disabled = 1;
    lp->mult = 1;
    return CAM_E_DISABLED;
}

#endif /* CAM_CTRL_CORE_H */
