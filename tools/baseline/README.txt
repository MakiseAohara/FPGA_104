# baseline 说明（不放网表本体，98 MB 太大不适合进 Git）

冻结 baseline 的 SHA256:
  mmt.map.ice0.frozen.postsyn.v = 8DF265985C206B7768B96E1CE17D459634965F8BECBA86F25305EE54743FE6B4

重新生成方法（本地）：
  1) 在 mmt.xml 里设 infer-clk-enable = 0
  2) tools\synth_cmdline.ps1 只综合出网表
  3) 与上面的 SHA256 比对；一致才可作门禁用 baseline

注意：本文件不进 Git。tools\check_expected.py 若找不到 baseline 网表会报错，
需要在本地重建（见上），或用 --baseline 参数指向别的网表。