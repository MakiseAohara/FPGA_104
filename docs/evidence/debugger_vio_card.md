# Debugger / VIO 调增益 —— 10 步卡片（Kevin）

> 压缩自 `out\evidence\debugger_vio_howto.md`（552 行，静态调研）。未上板验证，按卡片操作即可。
> 工程固定用 `v7_work2` 的 profile；位流用当前烧进去的那份。

## 1. 启动 Debugger
```bat
D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat ^
  --project_home "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2" ^
  --profile_file "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2\debug.json"
```
（目录里没有 .exe，只能用这个 .bat；它会自己调 setup.bat 设环境。）

## 2. 顺序：先烧位流，再开 Debugger（JTAG 独占）
烧录和 Debugger 都走 FT4232H 的 B 通道 JTAG，同一时刻只能一个：
1. 先 `flash_vendor.ps1` 烧 `.bit`（成功标志：`Device ID read from JTAG: 0x10660A79` + `finished with JTAG programming`）；
2. **关掉 Efinity Programmer 页 / 结束所有烧录进程**；
3. 再启动 Debugger。换位流时反过来：`Unconfig` → 关 Debugger → 再烧。

## 3. 导入 profile
Profile 页 → **`Import Profile`** → 选 **`v7_work2\debug.json`**。
**不要**用 `debug_profile.wizard.json`（没有 vio0、la0 UUID 不符、USER2），也**不要**用 `out\debug_profile.mark_debug.json`（没有 `debug_cores`，加载必报错）。
若启动时已带 `--profile_file`，可跳过此步。

## 4. 连接板子
Debug 页：**`USB Target`** 选 FT4232H（`0403:6011`，没看到就点刷新）→ 指令选 **`USER1`** → 点 **`Configure`**。
（Debugger 里**没有** Board Profile 下拉框，那是烧录器那边的档。）

## 5. 找到 vio0 窗口
Configure 成功后主界面出现 `vio0`（4 个探针：`r_gain` / `g_gain` / `b_gain` / `gamma_sel`）。
表 7 列：`Name / Type / Width / Radix / Value / Control / Comparator`。

## 6. 改增益的填法（关键）
- `Radix` 列双击 → 选 **`Hex`**；
- `Value` 列双击 → 填**裸数字**，如 **`118`** —— **不能写 `0x118`，校验器会拒收**；
- 或用 `Radix = Dec`，直接填十进制 **`280`**（两者等价）；
- 填完回车 / 点开别处提交。

## 7. 默认值（上电即生效，不是 1.0×）
| 探针 | Hex | Dec | 倍数 |
|---|---|---|---|
| r_gain | `118` | 280 | 1.094× |
| g_gain | `ff` | 255 | 0.996× |
| b_gain | `15e` | 350 | 1.367× |

想回 1.0× 基准：三路都填 `100`（Dec 256）。寄存器 ÷256 = 实际倍数（Q8.8）。

## 8. 确认生效
改完看画面**实时变化**（红/蓝增益变化最明显）；也可重新点该单元格看 Value 是否保留。
不生效先检查：像素时钟是否在跑（见第 9 条）、值是否写成了 `0x` 前缀、是否已回车提交。

## 9. 注意事项
- `vio0_clk = vid_clk_dvi2`（`ti60f225_oob_top.v:1045`），**必须有像素时钟**（摄像头出图 / HDMI 有输出），否则写入不被采到；
- `.bit` 若用 `-m jtag` 临时加载，**掉电即失效**，断电/复位后必须重烧再连；
- 增益为 0 不会黑屏（RTL 按 255 处理），但调太大会饱和发白，属正常；
- `gamma_sel` 保持 0，别动。

## 10. 连不上先查这四项
1. **JTAG 被占用**：残留 `python` / `openocd` / 上次 Debugger / Programmer 页 → 全部结束再刷新；
2. **驱动版本**：FTDI 需 `2.12.36.4`（版本混杂可能蓝屏 0xFC），设备管理器应见 `0403:6011`；
3. **板子是否上电**（USB 只给 JTAG，不供电）；
4. **位流是否还在**（断电后需重烧）。
日志：Debugger Console 面板，或 `C:\Users\18915\.efinity\log\<时间戳>\`。
