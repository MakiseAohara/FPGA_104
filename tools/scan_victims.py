# ============================================================================
#  scan_victims.py —— 全局受害者扫描（指挥官指令 #10 之 3）
#
#  统计所有满足「.D(1'b0) 且 .CE 不是常量 且 SR_VALUE=0」的 EFX_FF 实例，
#  按模块归类。这些就是被 Efinity infer-clk-enable 缺陷击中的触发器。
#
#  用法: python scan_victims.py <netlist.postsyn.v> [标签]
# ============================================================================
import sys, re, collections

path = sys.argv[1]
tag  = sys.argv[2] if len(sys.argv) > 2 else path

inst_re = re.compile(r'^\s*EFX_FF\s+\\(\S+?)\s+\(')
d_re    = re.compile(r'\.D\(([^)]*)\)')
ce_re   = re.compile(r'\.CE\(([^)]*)\)')
srval_re= re.compile(r'\.SR_VALUE\s*=\s*([^;]+);')

victims = []          # (instance, D, CE)
total_ff = 0
by_mod = collections.Counter()

cur = None
curtxt = []

def flush():
    global cur, curtxt
    if cur is None:
        return
    txt = ' '.join(curtxt)
    d  = d_re.search(txt)
    ce = ce_re.search(txt)
    if d and ce:
        D  = d.group(1).strip()
        CE = ce.group(1).strip()
        # 只看 D 恰好是 1'b0 的
        if D == "1'b0":
            # CE 不是常量
            if CE not in ("1'b0", "1'b1", "1'b1 ", "1'b0 "):
                sv = srval_re.search(txt)
                sr = sv.group(1).strip() if sv else None
                if sr in ("1'b0", None):
                    victims.append((cur, D, CE, sr))
    cur = None
    curtxt = []

with open(path, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        m = inst_re.match(line)
        if m:
            flush()
            cur = m.group(1)
            total_ff += 1
            curtxt = [line]
            continue
        if cur is not None:
            curtxt.append(line)
            # defparam 出现新实例前都属于当前实例
flush()

# 归类：按层次前 3 段
for (inst, D, CE, sr) in victims:
    parts = inst.split('/')
    mod = '/'.join(parts[:3]) if len(parts) >= 3 else '/'.join(parts[:-1]) or '(top)'
    by_mod[mod] += 1

print(f"=== 文件: {path}")
print(f"=== 标签: {tag}")
print(f"EFX_FF 实例总数           : {total_ff}")
print(f"命中「.D(1'b0) + CE非常量 + SR_VALUE=0」: {len(victims)}")
print()
print("--- 按模块归类（前 40）---")
for mod, n in by_mod.most_common(40):
    print(f"  {n:6d}  {mod}")
print()
print("--- 前 60 条明细 ---")
for (inst, D, CE, sr) in victims[:60]:
    print(f"  {inst}   D={D}  CE={CE}  SR_VALUE={sr}")

# 写一份完整清单
outf = path + ".victims.txt"
with open(outf, 'w', encoding='utf-8') as g:
    g.write(f"# victims of infer-clk-enable bug  ({tag})\n")
    g.write(f"# criteria: .D(1'b0) && .CE not const && SR_VALUE=0\n")
    g.write(f"# total EFX_FF = {total_ff}, victims = {len(victims)}\n\n")
    g.write("## by module\n")
    for mod, n in by_mod.most_common():
        g.write(f"{n:6d}  {mod}\n")
    g.write("\n## detail\n")
    for (inst, D, CE, sr) in victims:
        g.write(f"{inst}\tD={D}\tCE={CE}\tSR_VALUE={sr}\n")
print(f"\n完整清单已写: {outf}")
