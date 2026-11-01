# SANITIZE_REPORT — 脱敏扫描结果

- 扫描范围：`code_package/` 下全部文本文件（32 个：`.py .cc .c .h .md .ps1 .txt .diff .v`）。
- 未修改任何 `.bin` / `.bit`；未改动固件源码的宏与常量（仅替换路径字符串）。

## 结果

| 检查项 | 命中文件数 | 处理 |
|---|---|---|
| 学校名称（南京邮电 / NJUPT / 邮电） | 0 | 无需处理 |
| 老师/同学真实姓名（Kevin / MakiseAohara / imlukier 等） | 0 | 无需处理 |
| 邮箱地址（正则匹配） | 0 | 无需处理 |
| 绝对路径（`D:\`、`D:/`、`C:\Users`、`/home/`） | **10 个文件 / 159 处** | 已替换为中性占位 |
| 协作工具名（Claude / Codex） | 0 | 无需处理 |

## 路径替换规则

| 原文 | 替换为 |
|---|---|
| `D:\Efinity` / `D:/Efinity` | `TOOLS:\Efinity` / `TOOLS:/Efinity` |
| `D:\riscv` | `TOOLS:\riscv` |
| `D:\FPGA\易灵思` | `PROJECT:\workspace` |
| `D:\FPGA\mmt` | `PROJECT:\mmt` |
| `D:\v7work` | `PROJECT:\v7work` |
| `D:\v292_build` | `PROJECT:\v292_build` |
| `C:\Users\<用户名>` | `USER` |
| `/home/<用户名>` | `/USER` |
| 其余 `D:\` / `D:/` | `PROJECT:\` / `PROJECT:/` |

替换后复查：**绝对路径 0 处残留**。
