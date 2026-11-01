# SANITIZE_REPORT — 脱敏扫描结果

- 扫描范围：`code_package/` 与 `submission/` 下全部文本文件（`.md .py .cc .c .h .ps1 .txt .diff .v .json .csv .log`）。
- 未修改任何 `.bin` / `.bit`；未改动固件源码的宏与常量（仅替换字符串）。

## 结果

| 检查项 | 处理前命中 | 处理后 |
|---|---|---|
| 学校名称类词 | 0 | 0 |
| 真实姓名 / 协作人名 | submission 内 10 个文件 | **0** |
| 邮箱地址（正则） | 0 | 0 |
| 绝对路径（盘符 / 用户目录 / POSIX home） | submission 55 文件、code_package 10 文件 | **0** |

## 替换规则

| 原文类别 | 替换为 |
|---|---|
| 协作者人名（3 个不同拼写） | `USER` / `TOOL` |
| 工具链盘符路径 | `TOOLS:\Efinity`、`TOOLS:\riscv` |
| 工程根路径 | `PROJECT:\workspace`、`PROJECT:\mmt`、`PROJECT:\v7work` |
| 其余盘符路径 | `PROJECT:\` / `PROJECT:/` |
| 用户目录 | `USER` / `/USER` |

> 本报告不再列出敏感词原文，避免报告自身成为命中源。

替换后复查：`submission/` 与 `code_package/` 内**绝对路径 0 处、人名 0 处、校名 0 处、邮箱 0 处**。
