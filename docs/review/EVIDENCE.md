# 验收证据索引

[返回项目首页](../../README.md) · [赛题对照](FEATURES.md) · [完整进度记录](../HANDOFF_2026-11-04.md)

本页选取能直接核验当前结论的原始文件。`evidence/` 还保留早期失败与中间版本；**最终画面提速阶段以 `after_fw2`、应用 CRC32 `B42CC161` 为准**。下列 PASS、截图和指标均是已经归档的记录，本次目录整理没有新增现场实测。

本轮新增的源码交付校验、仓库依赖编译及无板回放检查，单列于[评审整理检查记录](../../evidence/review_20261104/README.md)，不计作新上板结果。

## 先核对交付版本

| 核验内容 | 入口 | 如何判断 |
|---|---|---|
| 最终应用 | [应用标识](../../firmware/firmware_identity.json)、[应用文件](../../firmware/tinyml_pdti8.bin) | 438506 字节；CRC32 `B42CC161`；SHA256 `EFE406B74287EAD4467C9111557871D89AD6013AD64EEA967171F898F8DD1CBB`。 |
| 配套位流 | [网络位流](../../firmware/netfix04_rxq2_seed1.bit)、[工程与重试记录](../../evidence/network_20261104/) | SHA256 `865458AB2AF51C366AAA2C22DCFA3312F4AB104E90680185BC90F58BDF0E69F5`；实际生成使用 seed 1。 |
| 加载与启动 | [最终下载日志](../../evidence/preview_fps_20261104/board_fw2-loader.log) | 含 `MMT_LOAD_PASS DDR_CRC`、`MMT_LIVE_HW_READY`、`max_trk=2`、取像地址 `0x017e9200`；同时可见 `LP_CAMFPS_ON=0`。 |

加载日志仍打印继承的 `v29.2`/`v28` 文本，不能只凭启动字符串区分当前应用，应核对二进制哈希和 CRC。串口日志可能包含重载之前的记录，查看新一段 `MMT_LOAD_PASS`/`MMT_LIVE_BOOT` 后的内容。

## 双端网页与画面

| 核验内容 | 最短入口 | 证据范围 |
|---|---|---|
| PC 与板内 HTTP 实际访问、相同网页、图像/状态配对 | [最终双端验证 JSON](../../evidence/preview_fps_20261104/packed_live_links.json) | 两端各四次有效无损快照；共享 HTML SHA256 `46c1b4324ade55e258f5d69cd2b9a62b341781b6fc02f77077424840053d7f2c`。该记录明确 `manual_picture_confirmation=false`。 |
| 真实新画面刷新率 | [最终测量 JSON](../../evidence/preview_fps_20261104/measurements/after_fw2/measurement.json)、[原始样本与截图](../../evidence/preview_fps_20261104/measurements/after_fw2/) | 按浏览器绘制的新 capture ID 计数，重复绘制缓存不算新帧；另记像素内容哈希、间隔与请求错误。 |
| 灰度和比例、无损协议 | [协议检查](../../evidence/preview_fps_20261104/preview_packet_test.json)、[浏览器检查](../../evidence/preview_fps_20261104/ui_packed_selftest.json) | 9216 个 Gray8 像素逐点核对，包括 0–255；检查 16:9、重复帧不增加 FPS、错误包拒绝及旧 PNG 接口回退。 |
| 固定左右拼接偏移 | [地址审计](../../evidence/preview_fps_20261104/FRAME_LAYOUT_AUDIT.md)、[行列标记回归](../../evidence/preview_fps_20261104/frame_layout_test.json) | 旧取像基址偏 512 字节；精确合成行列标记中旧 1080 行全错，修正后 1080 行全对。固定 bank 尚无完成帧读锁，不据此声称时变撕裂也已消除。 |

实际画面观测值如下，完整过程和局限见[提速说明](../PREVIEW_FPS_FIX_2026-11-04.md)。最终测板页时 PC 镜像仍在运行；PC 测量 20 秒、板页 10 秒，两段观测的场景/功耗状态会变化。

| 入口 | 修复前新画面 FPS | 最终新画面 FPS | 最终计数 |
|---|---:|---:|---|
| PC 网页 | 0.15 | 2.20 | 44 张 / 20.0052 秒 |
| FPGA 板内网页 | 0.30 | 2.00 | 20 张 / 10.0051 秒 |

最终两端测量期均无 JavaScript/请求错误。首次提速阶段存在较长间隔，原始 [after_fw1](../../evidence/preview_fps_20261104/measurements/after_fw1/) 记录保留，不能把单次请求耗时或页面定时器频率解释为持续新画面 FPS。

[查看最终 PC 画面](../../evidence/preview_fps_20261104/measurements/after_fw2/pc_preview.png) · [查看最终板端画面](../../evidence/preview_fps_20261104/measurements/after_fw2/board_preview.png)

## 算法与预测

| 证据类型 | 入口 | 结论和限制 |
|---|---|---|
| 独立缺陷回归 | [19 项新增检查](../../evidence/mot_web_20261104/alg_unit_results.log)、[20 项原有检查](../../evidence/mot_web_20261104/alg_existing_results.log) | 均 PASS。覆盖 IoU、全局分配、变采样时间、负速度、遮挡续轨、背景小数和标签回绕等；不等同于真实人群准确率。 |
| 有精确真值的合成场景 | [完整指标](../../evidence/mot_web_20261104/metrics.json)、[算法设计说明](../../evidence/mot_web_20261104/alg_design_notes.md) | 双人并行、交会、遮挡、停转等受控输入可核验 ID、速度及 400 ms 外推。下表仅为合成交会结果。 |
| 501 帧历史实拍 | [素材审计说明](../../evidence/mot_web_20261104/recordings_report.md)、[真实时戳回归](../../evidence/mot_web_20261104/recordings_report_recorded_time.json)、[可迁移素材索引](../../evidence/mot_web_20261104/recordings_index_portable.json) | 原始像素与来源已核对；没有人工人体框/身份标签，原始 IR 未保存。不能给出真人召回率、MOTA/IDF1 或真实 400 ms 预测误差。 |
| 网页人数、ID、轨迹、预测交互 | [MOT 浏览器检查](../../evidence/mot_web_20261104/ui_selftest.json)、[实际 C 后端回放截图](../../evidence/mot_web_20261104/actual_backend_crossing.png) | 前者验证显示行为，后者是合成场景经实际 C 算法输出；截图中的两目标不能当作真人双人现场验收。 |

合成交会场景的指标单位为 **96×96 跟踪网格像素**，预测窗口为 400 ms；基线与优化版的匹配样本集合不同，完整计数在原始 JSON 中。

| 合成交会指标 | 保留基线 | 优化版 |
|---|---:|---:|
| 匹配观测 / 真值观测 | 108 / 176 | 150 / 176 |
| 观测匹配率 | 61.36% | 85.23% |
| ID 切换数 | 1 | 0 |
| 预测样本数 | 106 | 146 |
| 400 ms 预测平均误差 | 3.2264 px | 0.4110 px |

实拍数据中帧间隔中位数为 **1.66–3.26 秒**，不存在可直接量测 400 ms 后真实位置的相邻图像。按原设备时间回放时，有观测且已确认轨迹的**输出覆盖率**出现下列下降，应作为后续调参与连续视频标注的依据，不能用合成改善掩盖。

| 历史实拍片段 | 帧数 | 基线输出覆盖率 | 优化版输出覆盖率 |
|---|---:|---:|---:|
| recorded_scene | 329 | 49.848% | 30.091% |
| recorded_walk | 79 | 48.101% | 27.848% |
| recorded_two_person | 93 | 80.645% | 66.667% |

## 协议、传感器与尚未关闭的问题

| 项目 | 入口 | 读法 |
|---|---|---|
| TCP 发送窗口 | [14 项报文检查](../../evidence/preview_fps_20261104/tcp_window_test.json) | 覆盖丢包、部分/重复/越界 ACK、零窗口、32 位序号回绕、SYN/FIN 重传。延迟 ACK 的毫秒对比来自受控模型，文件明确 `real_hardware_measurement=false`。 |
| 双连接隔离与公平服务 | [13 项多连接检查](../../evidence/preview_fps_20261104/tcp_multi_test.json) | 两个连接独立响应缓存、重传和收发窗口；这些是原生协议回归，实际双端访问另看本页双端验证。 |
| 红外热图和估算温度 | [红外核查记录](../../comms/codex/20261104_infrared_audit.md) | 未完成校准、子帧一致性、色阶与 OSD 字符坐标问题均保留；某次显示 45℃不证明目标真实温度为45℃。 |
| 摄像头降帧与低功耗 | [最终启动配置](../../evidence/preview_fps_20261104/board_fw2-loader.log)、[现用主程序](../../evidence/v30_mot/main_live30.cc) | 本版 `LP_CAMFPS_ON=0`，不套用历史“60→18 FPS”结论，也未给出本版功耗数据。 |
| 综合与时序来源 | [seed 1 布局布线日志](../../evidence/network_20261104/builds/netfix04_rxq2/5b-pnr-seed1.log)、[seed 1 重试脚本](../../evidence/network_20261104/reproduction/retry_pnr.py) | 当前网络位流 setup 余量 −1.103 ns，尚未闭合。功能访问成功不替代时序验收。 |

各阶段说明保留写作当时的固件大小、页面哈希和“未推送”等措辞。当前入口以首页、[当前进度](../HANDOFF_2026-11-04.md)及最终应用标识为准；旧版模型、数据与 RTL 指标仍可从[历史数字出处](../../submission/NUMBERS_SOURCE.md)追溯。
