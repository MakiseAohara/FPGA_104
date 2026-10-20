# v7_camera_ai —— 完整可重建工程

这是"摄像头 + SapphireSoC + TinyML 加速器"三合一的一体化 Efinity 工程，
配合 `docs/交接-实时TinyML推理-2026-10-20.md` 使用。

## 这里面有什么

```
v7_camera_ai/
├── ti60f225_oob.xml          工程主文件（含 4 个 efx:design_file 之外的 include 路径）
├── ti60f225_oob.sdc          时序约束
├── ti60f225_oob.peri.xml     外设/引脚
├── rtl/                      全部设计源文件（含厂商 IP 与自研模块）
│   ├── ti60f225_oob_top.v    ← 顶层（本次改动最集中的文件）
│   ├── SapphireSoc.v         RISC-V SoC（1.4 MB，厂商生成）
│   ├── mmt_ai_mem_bridge3.v  3 主口 AXI 仲裁桥（自研）
│   └── mmt/osd/              OSD 相关（mmt_osd_demo.v 已改）
├── source/                   加速器与公共库
│   ├── tinyml/               TinyML 加速器（含加密核）
│   ├── common/               支撑库（FIFO/reset/APB3/RAM 包装）
│   └── axi/                  AXI 工具
├── ip/                       Efinity IP 文件
├── bitstream/p2d_ci.bit      ★ 已验证正常的位流（直接用这个）
└── 若干 .hex/.mem/.bin       初始化数据（字体、测试图案、SoC RAM）
```

## 快速开始

### 1. 建工程目录

把 `v7_camera_ai/` 整体拷到本地某个目录，**路径越短越好**（见下方注意事项）。

### 2. 综合

```powershell
$efi='D:\Efinity\2026.1'
$d='<你的路径>\v7_camera_ai'
& "$efi\bin\efx_map.exe" --project-xml "$d\ti60f225_oob.xml" --project ti60f225_oob `
  --root ti60f225_oob_top --device Ti60F225 --family Titanium `
  --veri_option verilog_mode=sv_09,vhdl_mode=vhdl_2008 `
  --work-dir "$d\work_syn" --output-dir "$d\out" `
  --I $d --I "$d\rtl\ddr3_controller" --I "$d\source\tinyml" --I "$d\source\common"
```

### 3. 布局布线 + 位流

按 `docs/交接-实时TinyML推理-2026-10-20.md` §7 的顺序：
`efx_pnr`（初排）→ `efx_run.py -f interface` → `efx_pnr --sync_file` → `efx_pgm`。

### 4. 直接上板

如果只想复现现象，**不用重新编译** —— 直接烧 `bitstream/p2d_ci.bit`：

```
SHA256 = 04946BC2AE0EA1A4C9BF2F40A95BFCC580709FBC2C1D3E3
```

（完整值见 `bitstream/SHA256.txt`）

## 注意事项

1. **Windows 260 字符路径上限**：如果放在深层目录，编译时会报一堆
   "No such file or directory" 而文件其实存在。用短路径（如 `D:\FPGA\proj`）。
2. **`efx_map` 必须用 `--project-xml`**，2026.1 不认 `--prj`。
   2025.1 又读不了 2026.1 的 XML，只能用 `--v` 喂源文件列表。
3. **不要用 `p4_osd.bit`**（不在本包内）—— 那个版本有显示条纹回归，
   原因见交接文档 §14。

## 没包含的东西

| 排除项 | 原因 |
|---|---|
| `work_syn/` `work_pnr/` | 构建中间产物，可重新生成 |
| `out/` 下除 `p2d_ci.bit` | 含 40 MB 的 `map.v`、路由轨迹、日志等 |
| `outflow/` | 同上 |
