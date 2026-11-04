# 当前完整工程

此目录保存 2026-11-04 功能基线的硬件工程及软件构建依赖。现版应用与网页沿用仓库原路径，以下入口配套使用。

| 内容 | 入口 | 说明 |
|---|---|---|
| Efinity 硬件工程 | [efinity/ti60f225_oob.xml](efinity/ti60f225_oob.xml) | Ti60F225，包含 RTL、TinyML IP、约束、接口设置、字体及 RAM 初始化资源 |
| RISC-V BSP / SDK | [riscv/embedded_sw/](riscv/embedded_sw/) | 含 TFLM、链接脚本、启动汇编、模型及链接必需的 `common/tinyml_lib.a` |
| 当前 RISC-V 应用 | [main_live30.cc](../../evidence/v30_mot/main_live30.cc) | 构建时替换 SDK 示例的 `main.cc`，当前 CRC32 为 B42CC161 |
| 跟踪 / 预测 | [mot_core.h](../../evidence/v30_mot/mot_core.h) | 最多 2 目标，IoU 关联、轨迹、速度与 400ms 位置外推 |
| 当前网页 | [page.html](../../tools/page.html) | PC 与 FPGA 内部 HTTP 同源 |
| 源码快照清单 | [SOURCE_MANIFEST.json](SOURCE_MANIFEST.json) | 1,275 个硬件/依赖文件的大小及 SHA256；不含综合、布局布线输出缓存 |
| 第三方来源 | [THIRD_PARTY.md](THIRD_PARTY.md) | 保留厂商与开源组件的原版权、许可和来源 |

构建步骤见[构建与运行](../../docs/review/REPRODUCE.md)，现成应用与位流见[firmware](../../firmware/README.md)。下载仓库后即可获得这些源文件，Efinity、RISC-V 编译器和相应厂商工具许可仍需自行安装。

硬件快照来自实际 `netfix04_rxq2` 工程；交付位流来自 seed 1 重试，XML 默认仍为 seed 0，完整命令见[构建记录](../../evidence/network_20261104/)。不要把默认重综合结果当作交付位流的逐位复现。当前 setup 余量 −1.103ns，尚未闭合。

软件依赖中的示例工程保留原目录结构；直接在 IDE 构建内置示例 `src/main.cc` 不会得到当前多目标/网页固件，应使用仓库的 `build_v30.py`。模型两份生成数据与 [submission 模型](../../submission/model/v29_model/generator/) 一致；更换模型或 TinyML IP 参数需要重新生成并验证，不能直接覆盖不同宏前缀的 `defines.v`。
