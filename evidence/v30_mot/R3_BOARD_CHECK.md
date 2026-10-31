# R3 上板验证清单（队友用）

> 分支 `v30-r3-offline`；源码 `evidence/v30_mot/`（`mot_core.h`、`main_live30.cc`、`test_mot.c`、`replay_mot.c`）。
> 约束：WB 保持 0x158/0x118/0x1A4 未动；`dec_update()` 与 v29.2 逐字节一致（见 `FIX_REPORT.md` 第九节）；v29.2 固件与 `fw_v30_final.bin`（318,322 B / CRC32 `E6535D37`）原样保留，未覆盖。

## 1. 编译 fw_v30_r3.bin

前置：
- SoC 软件工程树（`Ti60F225_tinyml_hello_world`）复制到**无空格短路径**，例如 `D:\v30_build\project`
- 模型：`evidence/v29_model/generator/v29_person_96_int8_model_data.{cc,h}` 拷到
  `project/.../tinyml_pdti8/src/model/` 与 `.../src/generator/`
- 工具链：`D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin`

命令（原文）：

```
py -3 evidence/v30_mot/build_v30.py --project D:\v30_build\project --out D:\v30_build\out_v30
```

产物：`D:\v30_build\out_v30\tinyml_pdti8.bin`，请记录**字节数与 CRC32**，填到下表并回报。

| 项 | 值 |
|---|---|
| fw_v30_r3.bin 字节数 | （待填） |
| fw_v30_r3.bin CRC32 | （待填） |

## 2. 烧录

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\load_v30.ps1 -Bit <MERGE17.bit 路径> -Fw <fw_v30_r3.bin 路径> -Port COM15
```

成功判据：日志里出现 `MMT_LOAD_PASS` 与 `MMT_WB_INIT r=344 g=280 b=420`（0x158/0x118/0x1A4），
以及 `MMT_LIVE_BOOT ... AE=0 ...`。若 `MMT_WB_INIT` 不是这组值，立即停止并回报。

## 3. 六段验证（每段记录括号里的数）

| 段 | 怎么做 | 看什么 |
|---|---|---|
| A 入场 | 从画面边缘走进来，重复 10~15 次 | `MMT_PREWARN` 次数（召回）、提前量 `lead_ms` 中位、误预警次数 |
| B1 站立 | 站定不动 60 s，换 2~3 个位置 | 唯一 ID 数（应 ≤2）、`conf≥1` 的连续帧数、并存航迹最大帧数（应 ≤3） |
| B3 快走 | 快速横穿 5~10 次 | 唯一 ID 数（应 ≤2）、是否换号 |
| C 双人 | 两人同时入画 60 s | `conf≥2` 的帧数（>0 即进步）、`nd≥2` 帧占比 |
| D 抖动 | 手持画面轻微抖动 30 s | PREWARN / 报警 / 确认航迹应为 0 |
| E 空场 | 无人空场 120 s | PREWARN / 报警 / 确认航迹应为 0/0/0 |

### 基线 vs 第三轮（空表，测完填）

| 指标 | 第二轮基线 | 第三轮（本次） | 判定 |
|---|---|---|---|
| 预警召回（命中/ROI 进入） | 6/47（12.8%） | | |
| 提前量中位 | 250 ms | | |
| 误预警次数 | 2 | | |
| B1 唯一 ID 数 | 4 | | |
| B1 并存最大帧数 | 15 | | |
| B3 唯一 ID 数 | 3 | | |
| C `conf≥2` 帧数 | 0 | | |
| D/E PREWARN/报警/航迹 | 0/0/0 | | |
| 两帧预测误差 p90 | 27.46 px | | |

## 4. 分项开关（上板后哪项变差，只关那一项重编）

| 宏 | 默认 | 置 0 的效果 |
|---|---|---|
| `MOT_V15_SPEED` | 1 | 速度回到"3/4 旧 + 1/4 新"的 EMA，无首帧直取/无停止衰减 |
| `MOT_V15_ENTRY` | 1 | 关闭边缘入场与 ROI 相交判定，回到"质心进 ROI 才预警" |
| `MOT_V15_MERGE` | 1 | 关闭碎片合并与航迹合并，静止目标 MAX_MISS 回到 6 |
| `MOT_V15_GATE` | 1 | 二级关联门限回到固定 16 px |
| `MOT_PRE_OK_N` | 1 | 改 2 表示预警需连续 2 帧满足（2 fps 下可能几乎不触发） |

编译时传宏（例）：`-DMOT_V15_ENTRY=0`（`build_v30.py` 目前不透传 -D，需在 `main_live30.cc` 顶部预先 `#define` 后再编）。

## 5. 已知限制（先看再测）

- 离线回放用的是 **48×48 缩略图 2× 放大**，与板上 96×96 真帧的口径不同：航迹行数 −70%、唯一 ID +89%，
  **回放不能代表板上**，只能做"改前 vs 改后"的相对对比。
- 因此第三轮各项是否达标，**只能以本次上板数据为准**。
