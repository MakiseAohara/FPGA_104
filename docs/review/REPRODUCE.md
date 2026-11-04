# 构建与运行

[返回首页](../../README.md) · [演示验收](ACCEPTANCE.md) · [功能对照](FEATURES.md) · [结果与证据](EVIDENCE.md)

此页用于从当前仓库找到完整工程并构建。现成二进制的现场加载步骤见[演示验收](ACCEPTANCE.md)。本轮仅整理工程与核查交付物，不新增现场运行结论。

## 1. 下载与校验

GitHub 仓库选择 **Code → Download ZIP** 并解压，或使用 Git 克隆。建议放在 `D:\FPGA104` 等不含空格和中文的短目录。以下命令均在仓库根目录运行。

```powershell
py -3 tools/verify_delivery.py
```

检查器使用 Python 3.9+ 标准库，核对当前 BIN/位流标识、完整硬件与软件依赖快照、模型和 Efinity 文件引用；不会连接板卡或下载文件。输出 `passed: true` 只证明交付物一致，不代表时序闭合、算法准确率或现场验收通过。

## 2. 必需环境

| 工作 | 环境 |
|---|---|
| 核查交付物 | Python 3.9+ |
| PC 网页 / UART 加载 | Python 3、`pyserial`（`py -3 -m pip install pyserial`） |
| RISC-V 应用编译 | xPack `riscv-none-elf` GCC，实际构建使用 15.2.0-1 |
| FPGA 工程 / JTAG | Efinity 及匹配 FTDI 驱动；本机记录为 Efinity 2026.1.132 |

用户原软件版本为 Efinity 2025.1；本仓库未验证 2025.1 重建。工具安装器、个人许可、USB 驱动不打包进源码目录。

## 3. 重建 RISC-V 固件

完整 SDK 已在 [project/current/riscv](../../project/current/riscv/) 中。应用入口为 [evidence/v30_mot/main_live30.cc](../../evidence/v30_mot/main_live30.cc)，构建脚本会覆盖 SDK 示例主文件的编译入口，保留 BSP、TFLM、模型和平台静态库。

```powershell
$repoRoot = (Get-Location).Path
$compilerBin = 'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
py -3 tools/embed_page.py
py -3 evidence/v30_mot/build_v30.py --project (Join-Path $repoRoot 'project/current/riscv') --toolchain $compilerBin --out (Join-Path $repoRoot 'out/review_fw')
```

把 `$compilerBin` 改为评委电脑的实际安装目录。`--project`、`--toolchain` 和 `--out` 应使用绝对路径；底层脚本会切换工作目录，不能直接把相对项目路径当成可搬迁路径。

成功后，`out/review_fw/` 包含 BIN、ELF、链接图、大小、编译命令和日志。脚本还会生成 `evidence/v30_mot/_stage/` 与 `firmware_identity_v30.json` 构建记录，不会覆盖 [firmware/tinyml_pdti8.bin](../../firmware/tinyml_pdti8.bin) 的交付副本。重新编译应记录自己的 SHA256/CRC，不凭构建成功直接宣称与交付镜像逐字节相同。

当前模型数据在 SDK 的 `src/model/`、`src/generator/` 两处，与 [submission/model/v29_model/generator/](../../submission/model/v29_model/generator/) 的同名文件一致，SHA256 为 `f05d58e192b6efd9b0a2837b0c883e7fbee0fb5cabc390ad9674ed33f7f9aea7`。旧训练说明包含历史数据与本机路径，仓库不保证一键完整重训。

## 4. Efinity 硬件工程

打开 [project/current/efinity/ti60f225_oob.xml](../../project/current/efinity/ti60f225_oob.xml)。同目录包含 `rtl/`、`source/`、SDC、Interface Designer 设置、RAM 初始化和字体资源；TinyML、Sapphire、DDR3 等沿用实际功能基线。

交付位流为 [firmware/netfix04_rxq2_seed1.bit](../../firmware/netfix04_rxq2_seed1.bit)，来自 seed 1 重试。XML 的默认 seed 为 0；实际构建脚本、seed 1 参数和日志保存在：

- [工程来源与设置清单](../../evidence/network_20261104/project_settings/)
- [实际构建 / 重试脚本](../../evidence/network_20261104/reproduction/)
- [时序与构建证据](../../evidence/network_20261104/)

原位流 setup 最差余量 −1.103ns，尚未闭合。再次综合、布局布线后应独立检查时序与功能；本轮不以网页通信成功替代这项检查。

## 5. 加载与双端网页

按[演示验收](ACCEPTANCE.md)的命令先临时加载位流，再通过 UART RAM 加载应用。加载时与 PC 监控程序分时使用串口。当前没有配置掉电自启动，断电需重载，不要混用历史 MERGE17 位流或旧应用。

| 入口 | 地址 | 服务位置 |
|---|---|---|
| PC 监控页 | `http://169.254.47.62:8090/` | PC Python 服务，可保留 PC 端事件记录 |
| FPGA 内网页 | `http://169.254.47.63/` | FPGA 内 RISC-V HTTP 服务，无须 PC 网页服务转发 |

两端页面来自 [tools/page.html](../../tools/page.html)。修改页面后先运行 `embed_page.py`，再重建并加载应用；仅刷新 PC 文件不会更新 FPGA 内嵌页面。本机快捷脚本默认 COM15，其他电脑请按[演示验收](ACCEPTANCE.md)显式传入实际串口。

## 6. 查阅回归与历史结果

原始回归、浏览器测量、合成数据和历史实拍索引见[证据入口](EVIDENCE.md)。部分 C 回归需要本机 C 编译器、生成的 DLL，浏览器测量需要 Edge/Playwright 及真实网络链路；保存的 `PASS` 记录不能替代另一台电脑的新测试。

旧版 ZIP 和 `submission/` 保留其时间点，不作为当前二进制默认来源。源码组织说明见[当前工程](../../project/current/README.md)。
