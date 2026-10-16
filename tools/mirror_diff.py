# ============================================================================
#  mirror_diff.py —— 镜像形态扫描
#
#  比较 ice3 / ice0 两份 postsyn 网表里同名 EFX_FF 的 D：
#    A_const_B_real : A 的 D 是 1'b0/1'b1，B 的 D 不是
#    B_const_A_real : 反之
#
#  用法: python mirror_diff.py [A.v] [B.v] [out.csv]
# ============================================================================
import sys, re, csv, collections

A_PATH = r'D:\FPGA\mmt\out\mmt.map.ice3.postsyn.v'
B_PATH = r'D:\FPGA\mmt\out\mmt.map.ice0.postsyn.v'
OUT    = r'D:\FPGA\mmt\out\evidence\mirror_diff.csv'
if len(sys.argv) > 1: A_PATH = sys.argv[1]
if len(sys.argv) > 2: B_PATH = sys.argv[2]
if len(sys.argv) > 3: OUT    = sys.argv[3]

inst_re  = re.compile(r'^\s*EFX_FF\s+\\?(\S+)\s+\(')
d_re     = re.compile(r'\.D\(([^)]*)\)')
ce_re    = re.compile(r'\.CE\(([^)]*)\)')
srv_re   = re.compile(r'SR_VALUE\s*=\s*([^,;\s*]+)')
CONST    = ("1'b0", "1'b1")


def load(path):
    """返回 (dict name->(D,CE,SRV,line), 总数, 重名数)"""
    ffs, dup, total = {}, 0, 0
    cur = None
    txt = []
    start = 0

    def flush():
        nonlocal cur, txt
        if cur is None:
            return
        t = ' '.join(txt)
        d, ce, sv = d_re.search(t), ce_re.search(t), srv_re.search(t)
        rec = (d.group(1).strip() if d else '?',
               ce.group(1).strip() if ce else '?',
               sv.group(1) if sv else '?', start)
        nonlocal_dup(cur, rec)
        cur, txt = None, []

    def nonlocal_dup(name, rec):
        nonlocal dup
        if name in ffs:
            dup += 1
        else:
            ffs[name] = rec

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for ln, line in enumerate(f, 1):
            if cur is None:
                m = inst_re.match(line)
                if not m:
                    continue
                cur, start, txt = m.group(1), ln, []
                total += 1
            txt.append(line)
            if '.Q(' in line:          # 实例结束标志
                flush()
    flush()
    return ffs, total, dup


def last_key(name):
    # 名字最后一段 + 位号：取最后一个 '/' 之后的部分
    return name.rsplit('/', 1)[-1]


def mod3(name):
    return '/'.join(name.split('/')[:3])


A, totA, dupA = load(A_PATH)
B, totB, dupB = load(B_PATH)

pairs = [(n, n) for n in A if n in B]
method_full = len(pairs)

# 兜底：未配上的按"最后一段"配对，仅限两边都唯一
ua = collections.defaultdict(list)
ub = collections.defaultdict(list)
for n in A:
    if n not in B: ua[last_key(n)].append(n)
for n in B:
    if n not in A: ub[last_key(n)].append(n)
fallback = 0
for k, la in ua.items():
    lb = ub.get(k)
    if lb and len(la) == 1 and len(lb) == 1:
        pairs.append((la[0], lb[0]))
        fallback += 1

paired_A = {a for a, _ in pairs}
paired_B = {b for _, b in pairs}

rows = []
cnt = collections.Counter()
for a, b in pairs:
    da, ca, sa, la = A[a]
    db, cb, sb, lb = B[b]
    ka, kb = da in CONST, db in CONST
    if ka and kb: cnt['both_const'] += 1; continue
    if not ka and not kb: cnt['both_real'] += 1; continue
    side = 'A_const_B_real' if ka else 'B_const_A_real'
    cnt[side] += 1
    kind = 'name_full' if a == b else 'name_lastseg'
    rows.append([a, side, da, ca, sa, la, db, cb, sb, lb, kind])

rows.sort(key=lambda r: (r[1], r[0]))
with open(OUT, 'w', newline='', encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['name', 'side', 'A_D', 'A_CE', 'A_SR_VALUE', 'A_line',
                'B_D', 'B_CE', 'B_SR_VALUE', 'B_line', 'kind'])
    w.writerows(rows)

print(f'A = {A_PATH}')
print(f'B = {B_PATH}')
print(f'A EFX_FF 总数={totA} (重名跳过 {dupA})  配上={len(paired_A)}  未配上={len(A)-len(paired_A)}')
print(f'B EFX_FF 总数={totB} (重名跳过 {dupB})  配上={len(paired_B)}  未配上={len(B)-len(paired_B)}')
print(f'配对方式: 完整名={method_full}  最后一段兜底={fallback}  '
      f'配对率(A)={len(paired_A)/max(1,len(A)):.2%}  (B)={len(paired_B)/max(1,len(B)):.2%}')
print(f"两边都常量={cnt['both_const']}  两边都非常量={cnt['both_real']}")
print(f"A_const_B_real={cnt['A_const_B_real']}  B_const_A_real={cnt['B_const_A_real']}")
print(f'CSV: {OUT} ({len(rows)} 行)')

for side in ('A_const_B_real', 'B_const_A_real'):
    c = collections.Counter(mod3(r[0]) for r in rows if r[1] == side)
    print(f'\n== {side} 按模块(前3段) Top 30 ==')
    for m, n in c.most_common(30):
        print(f'{n:6d}  {m}')

print('\n== 前 40 条明细 ==')
for r in rows[:40]:
    print(f'{r[1]} {r[0]} | A: D={r[2]} CE={r[3]} SRV={r[4]} L{r[5]} | '
          f'B: D={r[6]} CE={r[7]} SRV={r[8]} L{r[9]}')
