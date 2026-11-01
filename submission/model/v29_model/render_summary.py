# -*- coding: utf-8 -*-
"""把 model.summary() 文本渲染成 PNG（并存一份纯文本），作为"summary 截图"存证。"""
import sys, os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def main():
    txt_path, png_path = sys.argv[1], sys.argv[2]
    text = open(txt_path, encoding='utf-8').read()
    lines = text.splitlines()
    n = len(lines)
    fig_h = max(6, 0.22 * n)
    fig = plt.figure(figsize=(13, fig_h), dpi=120)
    fig.patch.set_facecolor('#f7f7f7')
    ax = fig.add_axes([0, 0, 1, 1]); ax.axis('off')
    ax.text(0.01, 0.99, text, family='monospace', fontsize=7.5, va='top', ha='left', color='#111')
    fig.savefig(png_path, facecolor=fig.get_facecolor())
    print('saved', png_path)

if __name__ == '__main__':
    main()
