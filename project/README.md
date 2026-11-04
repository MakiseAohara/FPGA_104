# 工程文件入口

评委重建当前版本，请从 [current/README.md](current/README.md) 开始。当前工程与固件的对应关系以 [版本与接手说明](../docs/HANDOFF_2026-11-04.md) 为准。

| 目录 | 用途 |
|---|---|
| [current/efinity/](current/efinity/) | 当前网口位流所用的完整硬件源码、Efinity 工程、接口设置、约束与初始化资源；打开 `ti60f225_oob.xml`。 |
| [current/riscv/](current/riscv/) | 当前应用构建所用的软件工程依赖，含 BSP、启动代码、链接脚本、模型、TFLM 和厂商静态库。 |
| [v7_camera_ai/](v7_camera_ai/) | MERGE8–14 等早期位流、源码 ZIP 与调试档案，用于版本追溯。 |

当前应用主程序与跟踪算法入口在 [evidence/v30_mot/](../evidence/v30_mot/)，共享网页在 [tools/page.html](../tools/page.html)。`current/riscv` 提供其依赖，不应把 SDK 自带示例主程序当作当前应用。

当前交付位流来自 seed 1 重试，工程 XML 的默认 seed 为 0；重建环境与时序限制见 [构建与运行](../docs/review/REPRODUCE.md)。厂商及开源代码保留各自版权和许可，本目录没有统一重授权。
