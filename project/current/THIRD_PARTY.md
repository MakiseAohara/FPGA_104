# 第三方代码与来源

本次整理保留各文件的版权头、许可文本和 SDK 原目录结构。此说明不对整个仓库统一重新授权。

| 组件 | 本仓库位置 | 来源 / 原许可位置 |
|---|---|---|
| Efinix TinyML IP | `efinity/source/tinyml/` | 实际使用的厂商工程快照；`tinyml_top.v`、`tinyml_accelerator_channels.v` 引用 [Efinix 官方 TinyML LICENSE](https://github.com/Efinix-Inc/tinyml/blob/main/LICENSE.txt)，本地保存于 [TinyML_LICENSE.txt](third_party/TinyML_LICENSE.txt) |
| Sapphire SoC、DDR3、MIPI/HDMI 等 | `efinity/rtl/`、`efinity/source/` | 保留 Efinix 生成信息及原版权、免责声明；相关硬件源也存在于仓库原有 [历史源包](../v7_camera_ai/bitstream/src/) |
| Sapphire BSP | `riscv/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc/` | [原 LICENSE.MD](riscv/embedded_sw/SapphireSoc/bsp/efinix/EfxSapphireSoc/include/LICENSE.MD)，含厂商声明及 SaxonSoc MIT 文本 |
| TensorFlow Lite Micro 及第三方头文件 | `riscv/embedded_sw/SapphireSoc/software/standalone/tinyml_pdti8/src/tensorflow/` | 随实际软件工程保存；各文件保留原 Apache、MIT 等版权/许可声明 |
| TinyML 平台静态库 | `riscv/embedded_sw/SapphireSoc/software/standalone/common/tinyml_lib.a` | 实际构建所用厂商依赖，保留原二进制；不将其宣称为本项目原创源码 |

官方 TinyML 许可获取日期：2026-11-04；来源 URL、上游 blob ID 和本地 SHA256 记录于 [SOURCE_MANIFEST.json](SOURCE_MANIFEST.json)。该文件是许可文本补充，未用上游最新版 IP 替换本项目已验证的 IP。
