# v29 正式配置候选（10/28）

构建已完成，离线 ±1 门槛未通过。随后用户在看到离线差异说明后发出“串口重新连接，上板”，据此加载候选并记录诊断数据；本目录不将离线核对或板测写成通过。

## 固件与相机

| 预设 | 文件 | 字节 | CRC32 |
|---|---|---:|---|
| NIGHT | tinyml_pdti8_v29_night.bin | 298834 | C7927468 |
| DAY | tinyml_pdti8_v29_day.bin | 298826 | 58347D5F |

SHA256 见 `firmware_identities.json`。`CAM_PRESET=NIGHT/DAY` 在编译期选择，默认 NIGHT；DAY 的入口为 `main_live29_day.cc`。NIGHT：VTS=1500、exp20=47824、gc=0x81、gf=0x3F；DAY 保持曝光和 VTS，gf 降到 0x2A，模拟增益约为 NIGHT 的 2/3。启动打印 `MMT_CAM_PRESET name=... mean_sensor=...`，并读回固定值。AE=0，采集期间不改变相机参数。

MERGE15 SHA256：74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40。没有修改 RTL、重新综合或调红外参数。

## 模型、输入与输出

模型固定到 `aea24d501f9c7e4df7297a40a9b58d1c6dd8f74e` 的 Generator 产物。生成的 C 数组与 `v29_person_96_int8.tflite` 逐字节相同，101088 B，SHA256 `605b2ba8a2e8d47038e758c4dc921a222def896525f87edcf4a72c583597741b`。所需算子为 CONV_2D、MEAN、FULLY_CONNECTED、SOFTMAX，注册表与新模型同步。

`src/model/model_settings.h`（官方项目）定义 `kPersonIndex=1`、`kNotAPersonIndex=0`；同目录 `model_settings.cc` 的标签依次为 notperson、person。新模型输出 `[1,2]`，取 `output(0)->data.int8[1]` 为 person。

`INPUT_SUB128=1`。`preprocess_core.h` 输出 `(signed char)u`，原始串口字节仍是 u。`input_snapshot` 保留 u，导图保持字节原样；只有 `input_contract.h::prepare_model_input()` 将 `(uint8_t)u-128` 写到模型输入。MMT_IMG 每 40 轮、MMT_THUMB 每 4 轮；缩略图仍是原始 u 的 2×2 均值。MMT_DEC 格式保持 v28。

## 判决参数

按本次指令设置 AI_P_TH=0、AI_P_STRONG=60、AI_P_OFF=-40。前两项保留 v28 的开启/强确认口径，释放阈值按本次明确要求从 -60 改为 -40；这里没有宣称已完成新阈值的实测评估。运动候选、IR_WIN=10、IR_NEED=2、IR_OFF_WIN=15、投票和低功耗逻辑保持 v28。四个决策函数的原文 SHA1 不变，见 `manifest.json`；宏展开后的释放阈值变化属于预期。

## 离线核对：未通过

从原始日志严格解码 F 段全部 55 张图；只在模型输入减 128。`offline_invoke.cc` 使用官方同源 TFLite Micro C++、生成的模型数组、共享输入函数、Invoke 和真实输出索引。主机驱动返回 OP_ERR，使卷积/FC 走原有参考软件回退核；这不是 FPGA 加速器仿真。

与按 `evidence/v29_model/eval_log.py` 规则重建的逐帧参考比较：

| 主机参考 | ±1 内 | 最大绝对误差 |
|---|---:|---:|
| LiteRT 2.3 默认核（含 XNNPACK） | 38/55 | 6 |
| LiteRT 2.3 BUILTIN_REF 对照 | 50/55 | 3 |

全部差异在 `F_frame_scores*.csv`，不剔除超差帧。原仓库只有 54 个已标注 F 样本的汇总，没有逐帧分数表，也没有文档引用的标签 CSV；因此没有复核真值分组的 +100/−91.5 中位数。参考运行时也不是 DSH 的 TensorFlow 2.16，不能把当前差异直接归因于模型权重或板上加速器。尝试安装 TF 2.16 的独立环境在 240 秒超时，已记录到 comms/。

主机构建的适配仅为硬件头/驱动桩、计时、MSVC 不能初始化零长度维度对象的存储写法；输入转换、量化运算和决策代码没有为对齐分数而修改。

## 复现与板测

`build_board.py` 在工作区创建官方项目副本，替换模型数据，分别构建 NIGHT/DAY；不修改外部官方项目。`build_offline.py`、`check_offline.py` 生成 C++ 逐帧结果。工具链/命令、ELF 和构建日志随目录保存。

`capture_v29.py` 是唯一 COM15 读写程序，支持断线重连；主机错误不回退位流。亮度超过 130 切 DAY。空场/有人提示窗口只是计划阶段，不能充当人工真值；分数符号相反时停止，其余未确认情况写明。数据输出 `evidence/v29_gate/`，完整过程及异常见该目录和 comms/codex/。
