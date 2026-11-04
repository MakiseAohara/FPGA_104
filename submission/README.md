# 分阶段提交材料与模型

本目录保存分阶段固件、RTL、原始采集数据、模型与评估工具。子目录中的“定版”“最终”“未上板”等描述，均需按文档当时的版本和日期理解。当前评委入口是 [现场验收步骤](../docs/review/ACCEPTANCE.md) 与 [赛题要求对照](../docs/review/FEATURES.md)。

| 目录 | 阅读方式 |
|---|---|
| [firmware/](firmware/) | v29.2、早期 v30 等固件源码与记录；当前加载文件见根目录 [firmware/](../firmware/)。部分公共头文件仍被当前构建复用。 |
| [rtl/](rtl/) | MERGE16/17 源码差异与资源、时序报告；当前硬件工程见 [project/current/](../project/current/)。 |
| [data/](data/) | 历史原始采集数据及对应条件，不能跨版本合并宣称现场效果。 |
| [model/v29_model/](model/v29_model/) | 当前复用的人体检测模型、训练/量化脚本、Generator 产物及历史离线评估。 |
| [tools/](tools/) | 历史采集、预测评估和可视化工具。 |
| [NUMBERS_SOURCE.md](NUMBERS_SOURCE.md) | 历史提交文档中的数字来源。 |

模型的既有离线准确率来自有限验证集，不等同于当前多目标跟踪或现场人数统计准确率。当前算法、画面与网页验证材料请按 [证据索引](../docs/review/EVIDENCE.md) 阅读。
