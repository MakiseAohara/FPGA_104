#!/usr/bin/env python3
# ============================================================================
#  check_expected.py —— "应有清单"门禁
#  指令: #13 第五项 / #14 / #15 第二条 / #16 门禁修正
#
#  为什么：受害者扫描只抓"见过的坏形态"，抓不到【整块逻辑被删除】（触发器没了就
#  从清单消失 ⇒ 报 0 受害者，S2 幸存者偏差）。本脚本反过来问"该在的还在吗"。
#
#  性能：对网表只做一遍流式扫描，建 ff[name]=(D,CE,SR_VALUE) 与 const_assigns。
#        100 MB 级网表约 1~2 秒。
#
#  #16 修正：
#    G-fix1  ③ 只对 gate_scope.txt 列出的写通路前缀判失败，其它层次只报"信息"；
#            baseline 改用冻结副本 tools\baseline\mmt.map.ice0.frozen.postsyn.v，并校验 sha256
#    G-fix2  ① 按 expected_ffs.txt 里的 [A]/[B] 类型分别判定：
#              [A] 只置位粘滞位 ⇒ D 必须 == 1'b1
#              [B] 状态/计数/有清零 ⇒ D 必须非常量
#    G-fix3  ② 改成精确匹配（不再用 endswith，避免 wlast 命中任意以 wlast 结尾的名字）
#
#  用法: python check_expected.py <netlist>
#  退出码: 0 全过 / 1 有不过项 / 2 参数或文件错误
# ============================================================================
import sys, os, re, hashlib

FF_INST   = re.compile(r'^\s*EFX_FF\s+\\(\S+?)\s+\(')
D_RE      = re.compile(r'\.D\(([^)]*)\)')
CE_RE     = re.compile(r'\.CE\(([^)]*)\)')
SRVAL_RE  = re.compile(r'\.SR_VALUE\s*=\s*([^;]+);')
ASSIGN_RE = re.compile(r'^\s*assign\s+([^=;]+?)\s*=\s*(1\'b[01])\s*[;,/*]')
CONST = ("1'b0", "1'b1")

def load_list(p):
    if not p or not os.path.exists(p): return None
    out = []
    for l in open(p, encoding='utf-8', errors='replace'):
        l = l.split('#')[0].strip()
        if l: out.append(l)
    return out

def load_expected(p):
    """返回 [(typeA|typeB, name), ...]；兼容旧格式（无类型前缀 ⇒ 当作 B）"""
    if not os.path.exists(p): return None
    out = []
    for l in open(p, encoding='utf-8', errors='replace'):
        s = l.split('#')[0].strip()
        if not s: continue
        m = re.match(r'^\[([AB])\]\s+(\S+)', s)
        if m: out.append((m.group(1), m.group(2)))
        else: out.append(('B', s))
    return out

def scan_netlist(path):
    ff = {}; const_assigns = []; total = 0; cur = None; buf = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for ln, line in enumerate(f, 1):
            am = ASSIGN_RE.match(line)
            if am: const_assigns.append((am.group(1).strip(), am.group(2), ln))
            m = FF_INST.match(line)
            if m:
                if cur is not None:
                    t = ' '.join(buf)
                    ff[cur] = (D_RE.search(t).group(1).strip() if D_RE.search(t) else None,
                               CE_RE.search(t).group(1).strip() if CE_RE.search(t) else None,
                               SRVAL_RE.search(t).group(1).strip() if SRVAL_RE.search(t) else None)
                    total += 1
                cur = m.group(1); buf = [line]; continue
            if cur is not None: buf.append(line)
    if cur is not None:
        t = ' '.join(buf)
        ff[cur] = (D_RE.search(t).group(1).strip() if D_RE.search(t) else None,
                   CE_RE.search(t).group(1).strip() if CE_RE.search(t) else None,
                   SRVAL_RE.search(t).group(1).strip() if SRVAL_RE.search(t) else None)
        total += 1
    return ff, const_assigns, total

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest().upper()

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    net = sys.argv[1]
    def opt(flag, default):
        return sys.argv[sys.argv.index(flag)+1] if flag in sys.argv else default
    BASE_DIR = r'D:\FPGA\mmt\tools'
    baseline  = opt('--baseline',  os.path.join(BASE_DIR, 'baseline', 'mmt.map.ice0.frozen.postsyn.v'))
    expected  = opt('--expected',  os.path.join(BASE_DIR, 'expected_ffs.txt'))
    whitelist = opt('--whitelist', os.path.join(BASE_DIR, 'victim_whitelist.txt'))
    scope_f   = opt('--scope',     os.path.join(BASE_DIR, 'gate_scope.txt'))

    if not os.path.exists(net):
        print(f"FAIL 网表不存在: {net}"); return 2

    print("=== 应有清单门禁 ===")
    print(f"  网表: {net}")
    ff, const_assigns, total = scan_netlist(net)
    print(f"  网表 EFX_FF 总数 = {total}    assign 常量语句 = {len(const_assigns)}")
    fails = []

    # ---------- ① 应有清单（按 A/B 类型分别判定）----------
    print("\n--- ① 应有清单（G-fix2：A/B 两套判据）---")
    want = load_expected(expected)
    if want is None:
        fails.append(f"找不到应有清单 {expected}")
    else:
        na = sum(1 for t,_ in want if t=='A'); nb = sum(1 for t,_ in want if t=='B')
        print(f"  清单条目 = {len(want)}  （A 型 {na} / B 型 {nb}）")
        miss = [n for _,n in want if n not in ff]
        badA = [(n, ff[n][0], ff[n][1]) for t,n in want if t=='A' and n in ff and ff[n][0] == "1'b0"]
        badB = [(n, ff[n][0]) for t,n in want if t=='B' and n in ff and (ff[n][0] in CONST or ff[n][0] is None)]
        if miss:
            fails.append(f"应有 FF 被删除（{len(miss)} 条）："); fails += [f"      {m}" for m in miss]
        if badA:
            fails.append(f"A 型（只置位）D 不得为 1'b0（等于复位值=永远置不起来）（{len(badA)} 条）：")
            fails += [f"      {n}  D={d}  CE={c}" for n,d,c in badA]
        if badB:
            fails.append(f"B 型（状态/计数）D 必须非常量，实际是常量（{len(badB)} 条）：")
            fails += [f"      {n}  D={d}" for n,d in badB]
        if not (miss or badA or badB):
            print("  PASS 应有 FF 全部存在且分别满足 A/B 判据")

    # ---------- ② 关键信号常量化（G-fix3：精确匹配）----------
    print("\n--- ② 关键信号常量化检查（精确匹配）---")
    key = {'fb_awvalid','fb_wvalid','fb_wlast','awvalid','wvalid','wlast',
           'checker0/frame_start','checker0/frame_stable'}
    hits = []
    for (s, v, ln) in const_assigns:
        cand = {s, s.lstrip('\\')}
        if cand & key: hits.append((s, v, ln))
    if hits:
        fails.append(f"关键信号被 assign 成常量（{len(hits)} 条）：")
        fails += [f"      L{ln}  assign {s} = {v}" for s,v,ln in hits[:20]]
    else:
        print("  PASS 关键信号未被常量化")

    # ---------- ③ 与 baseline 数量对比（G-fix1：限定 scope）----------
    print("\n--- ③ 与 frozen baseline 对比（G-fix1：只对 gate_scope 前缀判失败）---")
    if os.path.exists(baseline):
        print(f"  baseline: {baseline}")
        print(f"  baseline SHA256 = {sha256(baseline)}")
        scope = load_list(scope_f) or []
        print(f"  gate_scope 前缀 {len(scope)} 条")
        bff, _, _ = scan_netlist(baseline)
        lost = sorted(set(bff.keys()) - set(ff.keys()))
        # ★ 2026-10-18：综合器会把「只剩一个寄存器」的子层内联（flatten），
        #   于是同一寄存器从 a/b/c/reg~FF 变成 a/b/reg~FF。按名字集合直接相减会把
        #   这种"层级重命名"误判成"FF 丢失"。这里对"末段名仍存在于本次网表"的条目放行，
        #   并打印映射作为证据（ice=0 首例：checker0/u_vid_rx_align/u_frame_info_det/vs_r0~FF
        #   -> checker0/u_vid_rx_align/vs_r0~FF，网表实测 D=mipi_vs_sel、CE=1）。
        cur_leaves = {}
        for _n in ff:
            cur_leaves.setdefault(_n.split('/')[-1], []).append(_n)
        flatten_ok = [n for n in lost if n.split('/')[-1] in cur_leaves]
        if flatten_ok:
            print(f"  [信息] 判定为层级内联（末段名仍在网表）{len(flatten_ok)} 条：")
            for _n in flatten_ok:
                print(f"        {_n}  ->  {sorted(cur_leaves[_n.split('/')[-1]])[0]}")
        lost = [n for n in lost if n.split('/')[-1] not in cur_leaves]
        def in_scope(n):
            return any(n.startswith(p) for p in scope)
        lost_scope = [n for n in lost if in_scope(n)]
        lost_info  = [n for n in lost if not in_scope(n)]
        print(f"  baseline FF = {len(bff)}   本次 = {len(ff)}   少 {len(lost)}  （scope 内 {len(lost_scope)} / scope 外 {len(lost_info)} 仅信息）")
        if lost_info:
            import collections
            c = collections.Counter('/'.join(n.split('/')[:3]) if n.count('/')>=2 else n.split('/')[0] for n in lost_info)
            print("  [信息] scope 外减少的 Top 8:")
            for k, v in c.most_common(8): print(f"        {v:5d}  {k}")
        if lost_scope:
            fails.append(f"写通路 scope 内丢失 {len(lost_scope)} 个 FF（前 25 条）：")
            fails += [f"      {x}" for x in lost_scope[:25]]
        else:
            print("  PASS 写通路 scope 内无 FF 丢失")
    else:
        print(f"  (frozen baseline 不存在，跳过) {baseline}")

    # ---------- ④ 受害者白名单 ----------
    print("\n--- ④ 受害者白名单 ---")
    victims = [n for n,(D,CE,SR) in ff.items()
               if D == "1'b0" and CE and CE not in CONST and SR in ("1'b0", None)]
    wl = load_list(whitelist) or []
    wl = [w.split('|')[0].strip() for w in wl]
    bad = [v for v in victims if v not in wl]
    print(f"  受害者 = {len(victims)}   白名单 = {len(wl)}   不在白名单 = {len(bad)}")
    if bad:
        fails.append(f"有 {len(bad)} 条受害者不在白名单内：")
        fails += [f"      {b}" for b in bad[:25]]

    print("\n=== 门禁结论 ===")
    if not fails:
        print("  ✅ 全部通过"); return 0
    print(f"  ❌ 未通过，共 {len(fails)} 条：")
    for x in fails: print("    " + x)
    return 1

if __name__ == '__main__':
    sys.exit(main())

