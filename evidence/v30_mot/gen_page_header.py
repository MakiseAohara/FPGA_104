import runpy
from pathlib import Path
runpy.run_path(str(Path(__file__).absolute().parents[2]/"tools/embed_page.py"),run_name="__main__")
