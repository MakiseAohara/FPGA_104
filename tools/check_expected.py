#!/usr/bin/env python3
# ============================================================================
#  check_expected.py —— "应有清单"门禁（指挥官 #13 第五项 / #14 第五条 / #15 第二条）
#
#  为什么要它：
#    受害者扫描只抓"见过的坏形态"(.D(1'b0)+CE活+SR_VALUE=0)，抓不到【整块逻辑被删除】——
#    触发器没了就从清单里消失，于是报"0 受害者"（S2 的幸存者偏差）。
#    本脚本反过来问："该在的还在吗？" 缺一条即失败。
#
#  性能：对网表【只做一遍流式扫描】，建立
#      ff[name] = (D, CE, SR_VALUE)
#      const_assigns = {(sig, val)}
#    之后所有检查都查内存字典。100 MB 级网表约 1 分钟内扫完。
#
#  四道检查：
#    ① 应有清单（expected_ffs.txt）：每条必须存在，且 D 不是常量
#    ② 关键信号不得被 assign 成 1'b0 / 1'b1
#    ③ 与 baseline 比 FF 数，列出消失的名字
#    ④ 受害者白名单（victim_whitelist.txt）
#
#  用法: python check_expected.py <netlist> [--baseline <b>] [--expected <f>] [--whitelist <f>]
#  退出码: 0 全过 / 1 有不过项 / 2 参数或文件错误
# ============================================================================
import sys, os, re, io

FF_INST   = re.compile(r'^\s*EFX_FF\s+\\(\S+?)\s+\(')
D_RE      = re.compile(r'\.D\(([^)]*)\)')
CE_RE     = re.compile(r'\.CE\(([^)]*)\)')
SRVAL_RE  = re.compile(r'\.SR_VALUE\s*=\s*([^;]+);')
ASSIGN_RE = re.compile(r'^\s*assign\s+([^=;]+?)\s*=\s*(1\'b[01])\s*[;,/*]')
is_const  = lambda d: d.strip() in ("1'b0", "1'b1")

def load_list(p):
    if not p or not os.path.exists(p):
        return None
    out = []
    with open(p, encoding='utf-8', errors='replace') as f:
        for l in f:
            l = l.split('#')[0].strip()
            if l:
                out.append(l)
    return out

def scan_netlist(path):
    """一遍流式扫描：返回 (ff dict, const_assigns list, ff_total)"""
    ff = {}
    const_assigns = []
    total = 0
    cur = None
    buf = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for ln, line in enumerate(f, 1):
            am = ASSIGN_RE.match(line)
            if am:
                const_assigns.append((am.group(1).strip(), am.group(2), ln))
            m = FF_INST.match(line)
            if m:
                if cur is not None:
                    txt = ' '.join(buf)
                    dm = D_RE.search(txt); cm = CE_RE.search(txt); sm = SRVAL_RE.search(txt)
                    ff[cur] = (dm.group(1).strip() if dm else None,
                               cm.group(1).strip() if cm else None,
                               sm.group(1).strip() if sm else None)
                    total += 1
                cur = m.group(1); buf = [line]
                continue
            if cur is not None:
                buf.append(line)
    if cur is not None:
        txt = ' '.join(buf)
        dm = D_RE.search(txt); cm = CE_RE.search(txt); sm = SRVAL_RE.search(txt)
        ff[cur] = (dm.group(1).strip() if dm else None,
                   cm.group(1).strip() if cm else None,
                   sm.group(1).strip() if sm else None)
        total += 1
    return ff, const_assigns, total

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    net = sys.argv[1]
    def opt(flag, default):
        return sys.argv[sys.argv.index(flag)+1] if flag in sys.argv else default
    baseline  = opt('--baseline',  r'D:\FPGA\mmt\out\mmt.map.ice0.postsyn.v')
    expected  = opt('--expected',  r'D:\FPGA\mmt\tools\expected_ffs.txt')
    whitelist = opt('--whitelist', r'D:\FPGA\mmt\tools\victim_whitelist.txt')

    if not os.path.exists(net):
        print(f"FAIL 网表不存在: {net}"); return 2

    print("=== 应有清单门禁 ===")
    print(f"  网表: {net}")
    ff, const_assigns, total = scan_netlist(net)
    print(f"  网表 EFX_FF 总数 = {total}   （一遍扫描完成）")
    print(f"  assign 常量语句 = {len(const_assigns)}")
    fails = []

    # ---- ① 应有清单 ----
    print("\n--- ① 应有清单 ---")
    want = load_list(expected)
    if want is None:
        fails.append(f"找不到应有清单 {expected}")
    else:
        print(f"  清单条目 = {len(want)}")
        miss  = [w for w in want if w not in ff]
        const = [(w, ff[w][0]) for w in want if w in ff and is_const(ff[w][0] or '')]
        if miss:
            fails.append(f"应有 FF 被删除（{len(miss)} 条）：")
            fails += [f"      {m}" for m in miss]
        if const:
            fails.append(f"应有 FF 的 D 被常量化（{len(const)} 条）：")
            fails += [f"      {w}  D={d}" for w, d in const]
        if not miss and not const:
            print("  PASS 应有 FF 全部存在且 D 非常量")

    # ---- ② 关键信号常量化 ----
    print("\n--- ② 关键信号常量化检查 ---")
    key = ['fb_awvalid','fb_wvalid','fb_wlast','awvalid','wvalid','wlast',
           'checker0/frame_start','checker0/frame_stable']
    hits = [(s,v,ln) for (s,v,ln) in const_assigns if any(s == k or s.endswith('/'+k) or s.endswith(k) for k in key)]
    if hits:
        fails.append(f"关键信号被 assign 成常量（{len(hits)} 条）：")
        fails += [f"      L{ln}  assign {s} = {v}" for s,v,ln in hits[:20]]
    else:
        print("  PASS 关键信号未被常量化")

    # ---- ③ 与 baseline 数量对比 ----
    print("\n--- ③ 与 baseline 数量对比 ---")
    if os.path.exists(baseline):
        bff, _, _ = scan_netlist(baseline)
        lost = sorted(set(bff.keys()) - set(ff.keys()))
        print(f"  baseline FF = {len(bff)}   本次 = {len(ff)}   少了 {len(lost)}")
        if lost:
            fails.append(f"有 {len(lost)} 个 baseline 里存在的 FF 在本次网表里消失（前 25 条）：")
            fails += [f"      {x}" for x in lost[:25]]
            lf = os.path.splitext(net)[0] + '.lost_ffs.txt'
            with open(lf, 'w', encoding='utf-8') as g:
                g.write('\n'.join(lost))
            print(f"        完整清单已写: {lf}")
        else:
            print("  PASS 无 FF 丢失")
    else:
        print(f"  (baseline 不存在，跳过) {baseline}")

    # ---- ④ 受害者白名单 ----
    print("\n--- ④ 受害者白名单 ---")
    victims = []
    for name, (D, CE, SR) in ff.items():
        if D is not None and D == "1'b0" and CE and not is_const(CE) and SR in ("1'b0", None):
            victims.append(name)
    wl = load_list(whitelist) or []
    wl = [w.split('|')[0].strip() for w in wl]
    bad = [v for v in victims if v not in wl]
    print(f"  受害者 = {len(victims)}   白名单 = {len(wl)}   不在白名单 = {len(bad)}")
    if bad:
        fails.append(f"有 {len(bad)} 条受害者不在白名单内：")
        fails += [f"      {b}" for b in bad[:25]]

    # ---- 结论 ----
    print("\n=== 门禁结论 ===")
    if not fails:
        print("  ✅ 全部通过"); return 0
    print(f"  ❌ 未通过，共 {len(fails)} 条问题：")
    for x in fails:
        print("    " + x)
    return 1

if __name__ == '__main__':
    sys.exit(main())
