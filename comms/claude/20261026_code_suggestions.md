# 代码建议（Claude 2026-10-26 13:00）

以下只是建议，片段未经编译验证；贴合现有源码请 Codex 自行调整名字。除 A 外都不是今天的任务。
原则：不动决策函数；先只读诊断，后动作。

## A. 开机无条件读回并打印 MMT_CAM（只读，建议今天就加）

v23 已发现：main_live19_dump.cc 只在 AUTOEXP_ON || LP_CAMFPS_ON 时调用 cam_boot_read_all() 和完整 MMT_CAM，所以关口日志里没有 exp/gain 读回。改为开机无条件读一次（只读，不写）：

    /* 开机只读：不依赖 AUTOEXP_ON / LP_CAMFPS_ON */
    if (cam_boot_read_all() == 0) cam_boot_log();

注意：这会让二进制变化，CRC 随之变化，需要重新登记；决策函数 sha1 不变。若不想改固件，就不做，关口用现有 v19 dump。

## B. 亮度测量路径核对（只读诊断）

目的：确认 mean_sensor（bank 2 偶数字节）是否与屏幕显示同一路。每 8 帧打印一次：

    static void fb_check_print(uint32_t frame)
    {
       unsigned long long s[4][2] = {{0}};
       unsigned n = 0;
       for (int y = 40; y < 1000; y += 20) {
          for (int x = 40; x < 1800; x += 20) {   /* x 为偶数，x+1 为奇数 */
             for (int b = 0; b < 4; ++b) {
                const uint32_t base = FB_BASE + (uint32_t)b * FB_FRAME_LEN
                                    + (uint32_t)y * FB_ROW_BYTES;
                s[b][0] += *((const volatile unsigned char*)(base + (uint32_t)x));
                s[b][1] += *((const volatile unsigned char*)(base + (uint32_t)x + 1u));
             }
             ++n;
          }
       }
       bsp_printf("MMT_FBCHK f=%d b0e=%d b0o=%d b1e=%d b1o=%d b2e=%d b2o=%d b3e=%d b3o=%d\n\r",
                  (int)frame,
                  (int)(s[0][0]/n), (int)(s[0][1]/n), (int)(s[1][0]/n), (int)(s[1][1]/n),
                  (int)(s[2][0]/n), (int)(s[2][1]/n), (int)(s[3][0]/n), (int)(s[3][1]/n));
    }

采样范围请对照 pp_geometry 调整；只读，不写帧缓冲。

## C. 打印格式（扫描类固件用）

bsp_printf 不支持 %lu 和 %02x 宽度。统一用 %u/%x，字段拆开，不要把多字节拼成一个 %lx：

    bsp_printf("MMT_SWEEP pass=%d idx=%d mode=0x%x vts=%u e3e00=0x%x e3e01=0x%x e3e02=0x%x gc=0x%x gf=0x%x\n\r",
               pass, idx, mode, vts, e00, e01, e02, gc, gf);

## D. 以后若要重做自动曝光（现在不做）

D1. 曝光是 20 位：{3e00[3:0], 3e01, 3e02}，不能只写 3e01/3e02。

    static int ae_write_exp20(unsigned exp20)
    {
       if (cam_checked_write(&g_cam_io, CAM_REG_EXP_H, (unsigned char)((exp20 >> 16) & 0x0F), 0) != CAM_OK) return -1;
       if (cam_checked_write(&g_cam_io, CAM_REG_EXP_M, (unsigned char)((exp20 >> 8) & 0xFF), 0) != CAM_OK) return -1;
       if (cam_checked_write(&g_cam_io, CAM_REG_EXP_L, (unsigned char)(exp20 & 0xFF), 0) != CAM_OK) return -1;
       return 0;
    }

D2. 上限不是"初始值×4"：曝光上限应取实测有效范围（与帧长 VTS 有关）；增益只取标定表里测过的档位，不做线性 ×12%。

D3. 响应检查（防冲到全白，这是 v20 缺的）：调一步后等 N 帧，亮度没有朝预期方向变化至少 AE_MIN_DELTA，就判定该旋钮无效，回退到开机值并关闭 AE，打印日志。

    /* 调节后进入 WAIT_RESP */
    if (ae_wait_resp && ++ae_wait_frames >= AE_RESP_FRAMES) {
       if (abs(mean_now - mean_before) < AE_MIN_DELTA) {
          ae_restore_boot_values();      /* 写回开机 exp/gain */
          g_ae_enabled = 0;
          bsp_printf("MMT_AE_NORESP mean_before=%d mean_now=%d\n\r", mean_before, mean_now);
       }
       ae_wait_resp = 0;
    }

D4. 目标值：用下午实测的 mean_sensor（v16 下午中位数约 133）作为目标，而不是随手定的范围；目标要对应已核实的测量路径（见 B）。

D5. 冻结条件保持 !motion && !alarm_on && !person；AE 评估要放在不被低功耗跳过的位置，或者在低功耗期间明确停用并记日志。

## E. 关口脚本的有效性判定（Python 侧，不改固件）

    # 对每个 walk 窗口 [ENTER, LEAVE]，用 ticks.csv：
    valid = (motion_frames >= 3) and (ai_samples >= 5)
    # valid=False 的窗口标"无效窗口"，不计入关口结论；
    # 空场窗口：任何 alarm=1 的帧都记为误报，单列。

## F. 红外（硬件排查之后再决定）

当前 ir_hot 在日志里几乎恒为 1，且不参与 v19 判决。建议排查顺序：接线/接触 → 视场是否对着人 → 统计量从"最高温−环境温"改为"高于环境一定温度的像素个数"。改动前不要接进决策。
