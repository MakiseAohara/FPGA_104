# export_page.py — 把 web_monitor.py 里的 PAGE 导出成唯一真相源 tools/page.html
import pathlib, sys, importlib.util
root = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('wm', root / 'web_monitor.py')
src = (root / 'web_monitor.py').read_text(encoding='utf-8')
i = src.index('PAGE = """'); j = src.index('"""', i + 10)
page = src[i + len('PAGE = """'):j]
out = root / 'page.html'
out.write_text(page, encoding='utf-8', newline='\n')
print('wrote', out, len(page.encode('utf-8')), 'bytes')
