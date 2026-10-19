#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vio_probe.py —— 探测 FTDI 设备 + 建立 JTAG session + 读当前 VIO 值
用法（在 cmd 里，环境变量已设好）：
    python D:\\FPGA\\mmt\\tools\\vio_probe.py <debug.json路径>

它做四件事：
 1. 列出所有 FTDI 设备（拿 sernum）
 2. config_jtag(sernum, port=1, tap=TAPS[0])
 3. 打印已配置的 JTAG session URL
 4. 读 vio0 的 probe_out 当前值并打印

不写任何东西（只读），失败会打印完整异常，便于定位。
"""
import sys, os, traceback

def main():
    # ---- 参数 ----
    if len(sys.argv) < 2:
        print("用法: python vio_probe.py <debug.json路径>")
        print("例:   python vio_probe.py \"D:\\FPGA\\易灵思\\工作区\\07_官方demo工程\\v7_WBH1\\debug.json\"")
        sys.exit(2)
    prof = sys.argv[1]
    if not os.path.isfile(prof):
        print("!! debug.json 不存在: %s" % prof)
        sys.exit(2)
    print("debug.json = %s" % prof)

    # ---- 导入 ----
    try:
        from efx_dbg.jtag import JtagManager
    except Exception:
        print("!! 导入 efx_dbg.jtag 失败：")
        traceback.print_exc()
        sys.exit(3)
    print("导入 JtagManager 成功")

    # ---- 1) 列设备 ----
    print("\n=== [1] list_usb_devices ===")
    devs = None
    try:
        devs = JtagManager.list_usb_devices()
        if not devs:
            print("  (空) !! 没找到任何 FTDI 设备")
            print("  → 检查：板子上电？USB 插好？没有别的程序占用 JTAG？")
            sys.exit(4)
        for i, d in enumerate(devs):
            print("  [%d] %r" % (i, d))
    except Exception:
        print("  !! 失败：")
        traceback.print_exc()

    # ---- 2) config_jtag ----
    print("\n=== [2] config_jtag ===")
    # 5-tuple: (vid, pid, sernum, iface, desc)  —— sernum 是第 3 个
    sernum = None
    try:
        d0 = devs[0]
        if isinstance(d0, (tuple, list)) and len(d0) >= 3:
            sernum = d0[2]
        else:
            sernum = str(d0)
    except Exception:
        pass
    if sernum is None:
        print("  !! 无法从设备列表解析 sernum，请把上面 [1] 的输出贴给我")
        sys.exit(5)
    print("  使用 sernum = %r" % (sernum,))

    tap = None
    try:
        tap = JtagManager.TAPS[0]
        print("  TAPS 可选 = %r，用 %r" % (list(JtagManager.TAPS), tap))
    except Exception:
        print("  (取不到 JtagManager.TAPS，用默认 tap)")

    url = None
    try:
        if tap is not None:
            JtagManager().config_jtag(sernum=sernum, port=1, freq=3e6, tap=tap)
        else:
            JtagManager().config_jtag(sernum=sernum, port=1, freq=3e6)
        print("  config_jtag 成功")
    except Exception:
        print("  !! config_jtag 失败：")
        traceback.print_exc()

    # ---- 3) 已配置的 session ----
    print("\n=== [3] list_configured_jtag ===")
    try:
        configured = JtagManager.list_configured_jtag()
        for c in configured:
            print("  %r" % (c,))
        # 取第一个 url
        if configured:
            url = configured[0] if isinstance(configured[0], str) else configured[0][0]
    except Exception:
        print("  !! 失败：")
        traceback.print_exc()

    if url:
        print("\n  >>> session URL = %r  （请把它贴给我）" % (url,))
    else:
        print("\n  !! 拿不到 url，请把上面的输出整段贴给我")
        sys.exit(6)

    # ---- 4) 读 vio0 ----
    print("\n=== [4] 读 vio0 ===")
    jm = JtagManager()
    core = 'vio0'
    try:
        pout = jm.get_vio_property(url, core, 'probe_out')
        print("  probe_out 属性 = %r" % (pout,))
        if pout:
            for i, p in enumerate(pout):
                if p is not None:
                    try:
                        seq = p.sequence()
                    except Exception:
                        seq = p
                    print("    probe_out[%d] = %r" % (i, seq))
    except Exception:
        print("  !! 读 probe_out 失败（不影响后续写入）：")
        traceback.print_exc()

    try:
        pin = jm.read_vio(url, core)
        print("  read_vio 返回 = %r" % (pin,))
    except Exception:
        print("  !! read_vio 失败：")
        traceback.print_exc()

    print("\n=== 完成：把上面全部输出贴给我 ===")

if __name__ == '__main__':
    main()
