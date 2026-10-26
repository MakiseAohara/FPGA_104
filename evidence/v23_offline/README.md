# 离线复现

本目录的工具只做离线检查，不访问串口或 JTAG。`wb_estimator.h` 是未接入项目固件的候选计算核。结果与限制见 [summary.md](summary.md)。

在仓库根目录使用 Python 3.12。将下文 `$taskPython` 设为本机 Python 的绝对路径；本次使用 Codex 自带运行时。

```powershell
$taskRepo = (Get-Location).Path
$taskWork = Join-Path $taskRepo '..\v23_work'
$taskOut = Join-Path $taskRepo 'evidence\v23_offline\results'
New-Item -ItemType Directory -Force -Path $taskWork | Out-Null
$taskVendor = Join-Path $taskWork 'vendor'
& $taskPython -m pip install --target $taskVendor unicorn==2.1.4

# 8 项采集/解析契约检查；只使用模拟串口和临时合成日志。
& $taskPython evidence\v23_offline\test_capture_contract.py

# RISC-V 工具链默认路径与工程对接说明相同。
& $taskPython evidence\v23_offline\run_wb_core.py `
  --vendor $taskVendor --work (Join-Path $taskWork 'wb_core') --out $taskOut

# 执行原样提取的 v19 C 决策函数，不重编译 main_live 固件。
& $taskPython evidence\v23_offline\replay_actual_c.py `
  --repo $taskRepo --source evidence\v19\main_live19_dump.cc `
  --vendor $taskVendor --work (Join-Path $taskWork 'replay') --out $taskOut

# 仿真原始 MERGE14 源码包；Icarus 路径可用 --iverilog 改写。
& $taskPython evidence\v23_offline\audit_colour_rtl.py `
  --source-zip project\v7_camera_ai\bitstream\src\v7_MERGE14_src.zip `
  --repo $taskRepo --work (Join-Path $taskWork 'colour') --out $taskOut
```

`audit_colour_rtl.py` 在独立工作目录解包五个原始 RTL 文件，并从已有 tb_debayer 刺激中显式绑定增益、读取命名 RGB 平面。没有将副本写回生产工程。`test_capture_contract.py` 的临时文件也限定在仓库旁的工作目录，清理前核对绝对路径。

`results/colour_rtl.json` 记录源码包及五个 RTL 文件的哈希；`results/decision_replay.json` 记录实际 C 函数及日志的哈希。模拟器日志不包含 GitHub 凭据。
