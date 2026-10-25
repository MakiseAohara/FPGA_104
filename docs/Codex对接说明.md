# 工程对接说明（给 Codex）

> 对象：接手本项目的 AI 编码代理 / 工程师
> 作用：读完这一份就能独立上板、改固件、采数据、推仓库，不必再问历史问题
> 最后更新：2026-10-25（v22 关口实测完成后）

---

# 0. 一页速览

| 项 | 值 |
|---|---|
| 项目 | 2026 嵌入式芯片与系统设计竞赛 · FPGA 赛道 · 赛题三「多模态 AI 智能终端」 |
| 场景 | 宿舍/寝室门入侵检测：摄像头 + 红外 + 温湿度 + TinyML，非工作时段报警 |
| 板卡 | **Efinix Ti60F225**（Titanium 系列） |
| 当前位流 | **`v7_MERGE14.bit`**，2,829,903 B，SHA256 `E399F99067E6544262315607B27FC3DD2394F37FD245F909DEE1EBA8A8B41FE8` |
| 当前固件 | **`tinyml_pdti8_v19.bin`**（正式，CRC32 `E0EE7BE1`）/ **`_v19_dump.bin`**（诊断，CRC32 `9410DBEF`） |
| 仓库 | GitHub `MakiseAohara/FPGA_104`，**只推 main** |
| 截止 | 2026-11-04 18:00（视频 + 设计文档） |
| 立即能做 | 上板验证、采数据、改预处理/决策、写文档；**不要动 RTL 除非明确要求** |

---

# 1. 项目背景

赛题要求：摄像头（≥720p@30fps）+ MLX90640 红外 + SHT30 温湿度，RISC-V 跑 TinyML 人体检测，
多模态融合报警（OSD 红框 / LED / 蜂鸣器 / 置信度），并选 2 个扩展项。

已选的扩展项：**② RISC-V 决策控制**、**⑤ 低功耗场景管理**。

分工（历史）：RTL/视觉/OSD/传感器/位流由「Kevin 侧」负责；SoC + TinyML 固件由本侧负责。
现在整包交给 Codex，**两侧都可改，但需分清哪些已验证、哪些没有**。

---

# 2. 硬件与开发环境

## 2.1 固定路径（不要改）

| 用途 | 路径 |
|---|---|
| Efinity | `D:\Efinity\2026.1`（版本 2026.1.132） |
| RISC-V 工具链 | `D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin` |
| TinyML 工程 | `D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world` |
| 烧录脚本 | `<附件>\outputs\fpga_onboard_verified_20261020\tools\flash_vendor.ps1` |
| 固件构建脚本 | `sw/tinyml_live/build_tinyml_firmware.py`（仓库内） |

> ⚠️ `D:\FPGA\codex20` 是指向**含空格长路径**的 junction。直接在含空格目录编译会失败，
> 必须从无空格路径构建（见 §8.2）。

## 2.2 串口

| 项 | 值 |
|---|---|
| 芯片 | FTDI **FT4232H**（VID_0403 / PID_6011） |
| **UART 口** | **COM15**（115200 8N1） |
| 其它口 | COM13 / COM14 / COM16（不是 UART，别选错） |
| JTAG | `hiftdi://0x0403:0x6011/1`，设备 ID `0x10660A79` |

**COM15 会随插拔重新枚举**。每次上板前先确认端口存在，否则加载器会报 `PermissionError`。

## 2.3 环境变量陷阱

Efinity 的 python 需要自己的 `PYTHONHOME`，而系统 python 不需要。

- 跑 **Efinity 工具 / 带 pyserial 的脚本** → `PYTHONHOME=D:/Efinity/2026.1/python311`
- 跑 **普通分析脚本** → 必须 `Remove-Item Env:PYTHONHOME`，否则报
  `SRE module mismatch` 或 `No module named encodings`

实践：所有调用烧录/串口的脚本内部**自行**给子进程设置 `PYTHONHOME`，主进程保持干净。

---

# 3. 仓库与协作规范

| 项 | 规定 |
|---|---|
| 仓库 | `github.com/MakiseAohara/FPGA_104` |
| 分支 | **只有 main**，不新建分支、不新建目录（除 evidence/ 下按任务约定） |
| 推送方式 | GitHub Contents API（脚本见 §8.6），token 从环境变量 `GH_TOKEN` 取 |
| 提交信息 | 必须包含固件的 **CRC32 + 字节数**；证据类提交写清结论 |
| 证据目录 | `evidence/<任务名>/`，一次任务一个目录 |
| 大文件 | 位流 2.8 MB / 固件 470 KB / 日志 0.5–2.6 MB，API 可推，但注意超时 |
| 中文文件名 | 推 API 时路径必须 `urllib.parse.quote`，否则 `'ascii' codec can't encode` |

---

# 4. 系统架构与关键参数

## 4.1 数据通路

```
MIPI CSI-2 → csi_rx → debayer → 帧缓冲写 DDR @0x01000000
                                      │
                        ┌─────────────┴─────────────┐
                     显示通路(1920×1080@60)      RISC-V 采样通路(~2 fps)
                                                        │
                                              96×96 int8 → TinyML 加速器
                                                        │
                                            APB reg9/reg10 → 视频域融合 → OSD/报警
```

显示与推理**完全解耦**；推理慢不影响画面（实测 59.7–60.3 fps）。

## 4.2 帧缓冲几何（**最容易搞错的地方**）

| 项 | 值 |
|---|---|
| 基址 | `0x01000000` |
| 格式 | **原始 Bayer，1 字节/像素**（不是 YUV422，不是 RGB） |
| 行宽 | **1920 字节**（= 480 个 32 位字，每字含 4 个相邻像素） |
| 尺寸 | 1920 × 1080 |
| bank 数 | 3，bank 步长 `960*1080*4 + 0x200 = 0x3F4A00` |
| **活跃 bank** | **bank 2** |
| 访问地址 | `base + bank*FRAME_LEN + y*1920 + x` |

> 历史事故：曾按「每行 960 个 32 位字」采样，把两行并成一行，导致画面水平重复 3.3 次、
> 下半部分全黑。修正后左右相关系数从 0.921 降到 0.069。**改采样代码前先验证几何**。

## 4.3 预处理（v16 起）

| 宏 | 当前值 | 含义 |
|---|---|---|
| `CROP_MODE` | 1 | 取中间 1080×1080 正方形再缩小（消除 16:9→1:1 的横向压扁） |
| `NORM_ON` | 0 | 亮度归一化到均值 115（**实测反而压低检出，未采用**） |
| `STRETCH_ON` | 1 | 1%/99% 分位对比度拉伸（**有效**） |
| `INPUT_SUB128` | 0 | 原样位重解释（**减 128 会让空场恒报警，禁用**） |

降采样：96×96，每输出像素取 3×3 个采样点，每点取 2×2 Bayer 方块均值。

## 4.4 模型与推理

| 项 | 值 |
|---|---|
| 模型 | MobileNetV1 0.25x，int8 量化，96×96×1，2 分类 |
| 文件 | `sw/tinyml_live/v16/...` 或 `main_live*.cc` 内嵌 `mobilenetv1_person_detect_model_data.h`（300,568 B flatbuffer） |
| 输出 | `output[1]` = person（`kPersonIndex=1`），`output[0]` = not-a-person |
| 输入量化 | scale=1/127.5，zero_point=−1 |
| 单次推理 | **485 ms**（v16+），CI 指令 813,352 |
| 加速器 | `tinyml_accelerator_channels`，UUID `0x4923687a`，LITE/并行4/cache512/AXI128 |
| 理论上限 | **2.06 fps**（推理本身已占满，多出图必掉帧率） |

## 4.5 APB 寄存器映射

基址 `0xF8100000`，偏移 `4*N`。

| N | 读/写 | 内容 |
|---|---|---|
| 0 | R | DDR 校准完成 |
| 1–3 | R | SoC AXI 计数 / 桥状态 |
| 4–5 | R | TinyML AXI 计数 |
| 6 | R | CI 指令计数 |
| 7 | R | 中断计数 |
| 8 | RW | 系统复位 |
| **9** | R/W | OSD 报警位（bit0），固件写 → 硬件同步进视频域 |
| **10** | R/W | `0x100 \| (uint8_t)p`（bit8 有效标记 + int8 得分） |
| 11–15 | — | MERGE11 起预留（决策/低功耗回读） |
| 16–18 | — | 相机 SCCB 读写（MERGE10 起） |

> ⚠️ **不要擅自占用 11 及以上寄存器**，编号需与 RTL 侧对齐。

## 4.6 决策状态机（v19 起，当前生效）

```c
AI_P_TH      0      // 投票窗口内 p>=0 计「有人」
AI_VOTE_N    3      // 3 帧窗口
AI_VOTE_K    2      // >=2 帧为真 → person
AI_P_STRONG  60     // 单帧强证据可直接开报
AI_P_OFF    -40     // 3 帧全 < -40 → 可解除
DEC_CAND_FRAMES 6   // 运动候选窗口
```

- **起报**：`person && (cand_left>0 || p_now>=AI_P_STRONG)`
- **解除**：`infer_ran && 3帧全 off`（**只看 AI，与运动无关**）
- 进低功耗时清空 AI 历史

---

# 5. 版本谱系（重要：每个版本解决什么问题）

| 版本 | 关键改动 | 教训 |
|---|---|---|
| v9 | 盒式平均降采样 | 点采样会把人形切碎，判决乱跳 |
| v11 | 输入快照 | **TFLM 在 `Invoke()` 后回收 arena**，必须调用前拷贝 |
| v12 | 曝光探针（同帧 3 档亮度） | 证明分数被亮度单调主导 |
| v14 | **修正 Bayer 采样几何** | 960 字行距 → 1920 字节行距 |
| v15 | 亮度归一化开关 | 归一化把检出压死（AUC 0.52） |
| v16 | crop1 / crop2 / norm / stretch 四轴 | **crop1+stretch 最优（AUC 0.942）** |
| v17 | AI_P_TH=-86 + 3/4 投票 | 冷静期仍被 `irhot` 顶到恒报警 |
| v18 | 决策改为运动触发 + AI 确认 | 冷静期零报警达成 |
| v19 | AI_P_TH=0 / 3取2 / 强证据 60 / 只看 AI 解除 | 走入 5/5 检出；**AUC 0.997** |
| v20 | v19 + AE 冻结（`!motion && !alarm_on && !person`） | **AE 在推理分支内 → 低功耗暂停时 AE 也停** |
| v21 | 曝光标定扫描（23 状态 × 2 遍） | 曝光 14.5× 只让 mean 15→17；**增益 gc 影响远大于曝光** |

---

# 6. 已验证的数字（可直接引用）

## 6.1 AI 判决

| 场景 | p 均值 | 说明 |
|---|---|---|
| 空场（b0m 60） | **−71 ~ −95** | 零报警 |
| 人站 1 米 | **+33 ~ +51** | 检出率 84–97 % |
| 人站 0.5 米 | **+30 ~ +51** | 略差于 1 米 |
| 走入（6 次） | 逐次峰值 92–115 | v19 5/5 检出 |

**AUC**：v18 0.997（原版）/ v19 0.993（dump 版）；v16 crop1_stretch 0.942；base 0.437。
推荐阈值 **p ≥ −50**（误报 0–3 %、漏报 2–5 %）；FPR≤5 % 时检出率 95–98 %。

## 6.2 亮度与曝光

| 曝光值 | 输入均值 | 0xFF 占比 | 判决 |
|---|---|---|---|
| `0x01BBF0`（7103 行，原厂 ROM） | 166–185 | 21 % | ❌ 空场误报 p≈+20 |
| `0x00BAD0`（2989 行，曾临时降低） | 98 | 0 ‰ | ✅ 正确 |
| 当前（v16+ 默认） | 38–74 | — | 偏暗但可检出 |

`mean_sensor` 目标区间 **[80,110]**；实测长期在 32–74，**房间太暗是最大制约**。

## 6.3 性能

推理 485 ms → **2.06 fps 上限**；任何 `IMG_DUMP_EVERY < 40` 都会把帧率压到 2 fps 以下
（N=10 → 1.56 fps，N=1 → 0.46 fps）。显示通路 60 fps 不受影响。

---

# 7. 踩过的坑（按类别，全部实际发生过）

## 7.1 固件 / TFLM

1. **`MicroPrintf` 只支持 `%d`/`%x`，不支持宽度**。`%04x` 会打成 `04x`、`%02x` 打成 8 位。
   多字段行会串味（如 `vts=...p20=...`）。**要格式化就自己拼字符串 + `bsp_printf`**。
2. **`printf` 到不了 UART**，必须 `bsp_printf`（需 `ENABLE_BSP_PRINTF=1`）。
3. **`model_input->data.int8` 在 `Invoke()` 后失效**（arena 被回收）。要打印输入图必须**先拷贝**。
4. **减 128 是错的**（对本模型）：`(int8_t)(v-128)` 会让空场 p≈0 并大量误报。
5. 从 `0x0` 开始扫描 DDR 会**挂死**（0x0–0xFFF 是译码空洞），从 `0x00100000` 起。
6. 读寄存器时注意 **cache**：连续读同一地址会命中 cache 得到旧值，需扫大块内存挤掉。

## 7.2 采集 / 串口

7. **固件上传会在任意块中断**（`OSError: Block N acknowledgement b''`），常见于 40–75 KB 处。
   处理顺序：① 块级重试 ×3 → ② 整轮重试 → ③ **断电重上电**（DDR 校准重跑，最有效）。
8. **一次 dump 行 ≈ 204 B × 96 行 ≈ 19.6 KB**，115200 波特下约 1.7 s。dump 频率必须权衡。
9. 串口读取**必须做行缓冲**，否则长行会被拆成多条带时间戳的碎片，解析全错。
10. USB 会**瞬时掉线**导致 FPGA 复位（固件丢失）。抓取脚本要能自动重连并记 `### RECONNECT`。
11. 烧录走同一颗 FT4232H 的 JTAG，**复位瞬间串口输出会丢**（`MMT_BOOT`/`MMT_CFG` 常丢）。

## 7.3 构建 / 路径

12. 路径含空格会 `No such file`；`D:\FPGA\codex20` 是 junction 指向含空格路径 —— 照样失败。
    **构建要在真正无空格的目录**（如新建 `D:\build\vNN`）。
13. PowerShell `Set-Content -Encoding UTF8` 会写 **BOM** → Python 报 `U+FEFF`；
    `Get-Content -Raw` 按 ANSI 读会**破坏中文**。改文件一律用编辑工具或 `io.open(..., newline='')`。
14. Python 的 `re.sub` 替换串里 `\n` 会被解释成真换行 —— 要写字面量需 `\\\\n` 或用函数替换。

## 7.4 逻辑 / 系统

15. **低功耗暂停推理 ⇒ AE 停止工作**（AE 代码在推理分支内）。要验 AE 必须关 `LOWPOWER_ON`。
16. **`irhot` 门限过紧**会让无人房间恒判热点，score 顶到 255、报警常开（v17 现场）。
17. 离开画面后判决有**拖尾**（第一轮 7 s 内仍有 45–76 的峰值），融合侧需加释放迟滞。
18. 帧缓冲里是 **Bayer 原始数据**，显示通路与 CPU 读到的视图必须分别验证。

---

# 8. 工具与命令速查

## 8.1 烧位流 + 灌固件（标准流程）

```powershell
# 1) 先起加载器（等 MMT_LOADER_READY）
python <repo>\sw\tinyml_live\load_and_run.py --port COM15 `
    --image <firmware>.bin --out <run_dir> --boot-timeout 45 --run-timeout 60
# 2) 另开窗口烧位流（触发复位 → 开始灌固件）
powershell -File <mmt>\tools\flash_vendor.ps1 -Bit <bitstream>.bit `
    -Sha256 <SHA256> -EfinityHome D:\Efinity\2026.1 `
    -ExpectedDriverVersion 2.12.36.20 -UsbUrl hiftdi://0x0403:0x6011/1
# 3) 成功标志：日志出现 MMT_LIVE_BOOT
```

## 8.2 编译固件（从无空格路径）

```powershell
$proj='D:\FPGA\codex20\official-tinyml\tinyml_hello_world\Ti60F225_tinyml_hello_world'
$tc='D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
python <repo>\sw\tinyml_live\build_tinyml_firmware.py --project $proj --toolchain $tc `
    --out <out_dir> --main-source main_liveXX.cc `
    --define AUTOEXP_ON=0 --define IMG_DUMP_EVERY=40      # --define 需先给脚本加支持
```

## 8.3 Elfinx 位流构建（如需改 RTL）

```powershell
efx_map --project-xml ti60f225_oob.xml --project ti60f225_oob --root ti60f225_oob_top `
        --device Ti60F225 --family Titanium --veri_option verilog_mode=sv_09,vhdl_mode=vhdl_2008
efx_pnr --prj ... --circuit ... --family Titanium --device Ti60F225 --operating_conditions I3 `
        --pack --place --route --vdb_file out\*.vdb --use_vdb_file on --timing_analysis on `
        --sdc_file ti60f225_oob.sdc --optimization_level TIMING_3
python %EFINITY_HOME%\scripts\efx_run.py ti60f225_oob --prj -f interface --output_dir out
efx_pnr ... --sync_file out\ti60f225_oob.interface.csv
efx_pgm --project-xml ... --source work_pnr\*.lbf --dest out\new.bit --mode active
```
**判据：负 slack 必须为 0。**

## 8.4 采数据

| 脚本 | 用途 |
|---|---|
| `capture_v16/v20/v21/v22.py` | 一体化：烧录 + 灌固件 + 连续记录（含 GAP/重连） |
| `free_capture.py` | 纯串口连续记录（不带烧录） |
| `rec.py --variant X --scene S1_nobody --secs 35` | 单段录制 |
| `seq18.py --phase quiet/p1m/p05m/walk` | 分阶段录制 |

## 8.5 分析

| 脚本 | 用途 |
|---|---|
| `offline_eval/run_all.py` | 8 种预处理组合 + AUC/ROC + 一致性 |
| `offline_eval/replay19.py` | 把日志回放进决策状态机（可验证固件自身报警是否可复现） |
| `analyze16.py` | 多变体 p 分布对比 |
| `build_gate.py` / `build_ae.py` / `build_sweep.py` | 生成 ticks.csv / contact sheet / summary.md |
| `check_halves.py` | 验证帧缓冲几何（左右相关系数） |

## 8.6 推仓库

```python
# GitHub Contents API，token 从 GH_TOKEN 取
url = f'https://api.github.com/repos/MakiseAohara/FPGA_104/contents/{urllib.parse.quote(path)}'
payload = {'message': msg, 'content': base64.b64encode(data).decode(), 'branch': 'main'}
if sha: payload['sha'] = sha          # 覆盖已有文件必须带 sha
```
推送后可用 **git blob sha1** 抽查：`sha1(b'blob %d\0' % len(d) + d)` 与远端 `sha` 比对。

---

# 9. 当前未决问题（接手后优先处理）

| # | 问题 | 影响 | 建议 |
|---|---|---|---|
| 1 | **房间太暗**（mean_sensor 32–74，目标 80–110） | 检出余量小 | 加灯 / 提曝光 / 用增益（v21 显示增益比曝光有效） |
| 2 | **曝光寄存器响应弱**（14.5× 只带来 +2） | 无法靠曝光调亮 | 优先调**增益** `0x3E08` |
| 3 | **AE 与低功耗互斥** | AE 在空场景停摆 | 把 AE 评估移出推理分支，或 AE 开启时抑制 LP |
| 4 | 离开后判决拖尾 | 人走仍报警 | 融合加释放迟滞 |
| 5 | `MMT_CAM_VTS` / `MMT_SWEEP` 打印格式错 | 数值需靠上下文解析 | 改 `%x` 并把字段拆开 |
| 6 | 传感器曾间歇无读数 | SNS=ER | 检查 I2C 接触（后期自行恢复，尚未定位） |
| 7 | 采集分辨率 960×1080（水平 <1280） | 严格看未达 ≥720p | 需改 sensor 模式，属 RTL 范畴 |
| 8 | 上传不稳定 | 每次上板可能重试 | 已在脚本内做块级重试 + 断电提示 |

---

# 10. 接手检查清单

## 第一次上手

- [ ] 确认 `COM15` 存在、`VID_0403` 在线
- [ ] `git clone` 仓库，读 `evidence/v22_gate/summary.md` 了解最新状态
- [ ] 确认板子上的位流：能跑就抓 10 s 日志看 `MMT_CAM` / `MMT_LIVE_BOOT` 版本行
- [ ] 跑一次 §8.1 流程，确认能烧能灌能出 `MMT_LIVE_BOOT`
- [ ] 用 `check_halves.py` 复核帧缓冲几何（应得到单幅图像，左右相关系数 < 0.2）

## 每次改动前

- [ ] 先读第 7 节，确认没踩已知坑
- [ ] 决策相关改动先用 `replay19.py` 在 `evidence/v19_board` 日志上回放验证
- [ ] 预处理相关改动先离线跑 `offline_eval/run_all.py` 比较 AUC

## 每次上板后

- [ ] 记录固件 CRC32/SHA256 + 位流 SHA256 + 时间
- [ ] 抓到的日志带 GAP / 重连标记，确认没有静默丢数据
- [ ] 证据推到 `evidence/<任务名>/`，summary 只写事实，不下结论

---

# 附录 A：目录结构

```
FPGA_104/
├── project/v7_camera_ai/
│   ├── bitstream/            v7_MERGE9/11/12/14.bit + src.zip
│   ├── rtl/                  顶层、帧缓冲、debayer、OSD、TinyML 加速器
│   └── ti60f225_oob.xml/.sdc  工程与约束
├── sw/tinyml_live/
│   ├── main_live9..21.cc      各版本固件源码
│   ├── v16/ v17/ v18/         头文件与固件包（含 manifest.csv）
│   ├── build_tinyml_firmware.py / build_variants.py
│   ├── load_and_run.py        串口加载器
│   └── *.md                   设计说明、上板步骤、诊断报告
├── offline_eval/
│   ├── run_all.py            8 组合离线评估（含 ROC/AUC）
│   ├── replay19.py           决策回放
│   └── results.md            评估报告
├── evidence/
│   ├── ab_v16/               v16 变体对比（原始日志 + PNG）
│   ├── merge12_v17/          MERGE12+v17 验证
│   ├── merge14_v18/          两轮验证（含 AUC 0.997）
│   ├── v19/ v19_board/       v19 回放 + 30 分钟两轮抓取
│   ├── v20/ v20_ae/          AE 冻结 30 分钟
│   ├── v21_sweep/            曝光标定扫描
│   └── v22_gate/             入侵→报警关口实测
└── docs/                     设计说明（②⑤、v16、v18）
```

# 附录 B：一键复现历史结论

```powershell
# 决策回放（应得到 v19_board 的 7/7、2/2）
python offline_eval/replay19.py

# 预处理 8 组合（应得到 crop1_stretch AUC 0.942）
python offline_eval/run_all.py

# v18 两轮验证（应得到 AUC 0.997 / 0.993）
cd evidence/v20; python check_v20.py
```

# 附录 C：关键文件哈希

| 文件 | 大小 | CRC32 | SHA256 |
|---|---|---|---|
| `v7_MERGE14.bit` | 2,829,903 | 248EF418 | `E399F990…41FE8` |
| `v7_MERGE12.bit` | 2,826,123 | 3923C9C4 | `9940EF09…3EE4D94` |
| `v7_MERGE11.bit` | 2,831,490 | — | `ECE19288…4C15` |
| `tinyml_pdti8_v19.bin` | 477,722 | E0EE7BE1 | `83F13D58…69ECBD` |
| `tinyml_pdti8_v19_dump.bin` | 477,722 | 9410DBEF | `8C0AE09D…D2AD3` |
| `tinyml_pdti8_v21.bin` | 478,490 | A799929A | `EE9AB816…2A39F0` |
