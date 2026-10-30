"""apply_rtl_diff.py — 把 evidence 里的 rtl.diff 应用到 MERGE14 源码树上。
用法: py -3 apply_rtl_diff.py <root> <diff1> [diff2 ...]
只处理 unified diff 的 +行/-行/上下文；新增文件（--- /dev/null）整段写入。
"""
import re, sys
from pathlib import Path

def norm_path(p):
    p = p.strip().strip('"')
    p = re.sub(r'^[ab]/', '', p)
    p = p.replace('\\', '/')
    i = p.find('/rtl/')
    if i >= 0:
        return p[i+1:]
    i = p.find('/')
    return p[i+1:] if i >= 0 else p

def apply(root: Path, diff: Path):
    lines = diff.read_text(encoding='utf-8', errors='replace').splitlines()
    i = 0; applied = 0; failed = []
    while i < len(lines):
        if not lines[i].startswith('--- '):
            i += 1; continue
        old = norm_path(lines[i][4:]); i += 1
        if i >= len(lines) or not lines[i].startswith('+++ '):
            continue
        new = norm_path(lines[i][4:]); i += 1
        target = root / new
        hunks = []
        while i < len(lines) and lines[i].startswith('@@'):
            m = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', lines[i])
            os_, oc = int(m.group(1)), int(m.group(2) or 1)
            ns, nc = int(m.group(3)), int(m.group(4) or 1)
            i += 1
            body = []
            while i < len(lines) and (lines[i][:1] in (' ', '+', '-', '\\') or lines[i] == ''):
                if lines[i].startswith('\\'):
                    i += 1; continue
                body.append(lines[i]); i += 1
            hunks.append((os_, oc, ns, nc, body))
        if not hunks:
            continue
        srclines = target.read_text(encoding='utf-8', errors='replace').splitlines() if target.exists() else []
        out = list(srclines); shift = 0; ok = True
        for (os_, oc, ns, nc, body) in hunks:
            start = os_ - 1 - 1 + shift          # 0-based，diff 的行号从 1 开始
            olds = [l[1:] for l in body if l[:1] in (' ', '-')]
            # 在 ±8 行内找匹配
            found = -1
            for delta in range(0, 9):
                for cand in (start - delta, start + delta):
                    if 0 <= cand and out[cand:cand+len(olds)] == olds:
                        found = cand; break
                if found >= 0: break
            if found < 0:
                ok = False; failed.append(f'{new}@@ -{os_}')
                break
            news = [l[1:] for l in body if l[:1] in (' ', '+')]
            out[found:found+len(olds)] = news
            shift += len(news) - len(olds)
        if ok:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('\n'.join(out) + '\n', encoding='utf-8')
            applied += 1
    return applied, failed

root = Path(sys.argv[1])
total = 0; allfail = []
for d in sys.argv[2:]:
    a, f = apply(root, Path(d))
    print(f'{Path(d).name}: applied {a}, failed {len(f)}')
    for x in f[:6]: print('   FAIL', x)
    total += a; allfail += f
print('TOTAL applied', total, 'failed', len(allfail))
