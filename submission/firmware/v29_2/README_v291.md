# v29.1 固件（2026-10-28 晚）—— 编译、自检、上板冒烟

> 本目录是 v29 的第二份正式候选：新模型（第二轮白天校准）+ ir_solo + 白平衡。
> 位流用 MERGE16（`evidence/v29_rtl_display/v7_MERGE16.bit`，SHA256 `81332CD1…F8882`）。
> 本文件只记录已执行并核对过的事实；未做的（a–d 人工采集）明确标为未做。

## 1. 构建产物

| 预设 | 文件 | 字节 | CRC32 | SHA256 |
|---|---|---:|---|---|
| NIGHT | `tinyml_pdti8_v291_night.bin` | 299,210 | `B534DE8E` | `FBFA3C0F3BD0A565EB96833FCAF1F84DF85A0129C7B7DE02D515904CFBE57AF2` |
| DAY | `tinyml_pdti8_v291_day.bin` | 299,210 | `AE5896F2` | `590AA969AB3211A1E8444F76376560063A47995BFDC5538E4B97E7222008C35D` |
| DAY+标定 | `tinyml_pdti8_v291_daycal.bin` | 300,362 | `6BE60395` | `6FE20AED1A94429ADB07F73089CE3DA8C17E8F324ACF31FFB85F0D33CE8CA75D` |

构建入口：`build_v291.py`（NIGHT/DAY/DAYCAL 三个目标，`python build_v291.py [NIGHT|DAY|DAYCAL]` 可只建一个）。
官方工程副本建在 `<repo 上级>/v291_build/`，不修改外部官方工程。工具链
`D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1`。三个目标均 `FIRMWARE BUILD PASS`，ram 占用 15.2%。

体积 299 KB 对应新模型（旧 MobileNet 版本是 485 KB），与交接预期一致。

## 2. 模型来源（重要）

- v29.1 使用 **第二轮（白天校准）** 的 Generator：`evidence/v29_model/generator/v29_person_96_int8_model_data.cc`，
  与 `evidence/v29_model/v29_person_96_int8.tflite` **逐字节相同**，101,088 B，
  SHA256 `A78BB07CC09D5279CC88281EAAC5328746E98EDFD2CA471BDF28DDD4EF8941C5`。
- `evidence/v29_fw/generator/` 里还是**第一轮**模型（数组 SHA256 `605B2BA8…`），
  与当前 `v29_person_96_int8.tflite` 不同。`build_board.py` 原来指向这里，v29.1 改用
  `evidence/v29_model/generator`；两处文件大小相同（619,325 B），只看大小分辨不出来。
- 之前 `evidence/v29_fw/README.md` 写的 605B2BA8 是当时的第一轮模型；本次没有改动那份历史文档，
  以本文件为准。

## 3. 源码改动（相对 v29 的 main_live29.cc）

1. **ir_solo**：新增 `IR_SOLO_ON=1`、`IR_SOLO_N=6`；`dec_update` 里多算 `ir_cnt6`（最近 6 个 IR 样本），
   报警起始条件改为 `fusion || solo`，`MMT_ALARM start` 增加 `cause=fusion|ir_solo`。
   解除条件不变：`infer_ran && g_person_off && ir_cnt15==0`。
2. **白平衡**（MERGE16 word 19..26）：
   - 开机 `wb_initialize()` 写 19/20/21 = `WB_R/WB_G/WB_B`（默认 0x158/0x118/0x170，即 344/280/368）。
   - `WB_CAL=1` 时 `wb_calibrate()`：连续读 32 帧，`pix==0` 或 `sat*20 > pix`（饱和 >5%）的帧丢弃，
     其余累加求 Rmean/Gmean/Bmean；`newR = WB_G*Gmean/Rmean`、`newB = WB_G*Gmean/Bmean`（G 不变），
     打印 `MMT_WB_STAT`、`MMT_WB r= g= b= Rmean= Gmean= Bmean= used= skipped=` 后写回并打印 `MMT_WB_APPLY`。
   - `WB_CAL=0` 时完全不进标定分支，只用宏内固定增益。
3. 启动行：`MMT_LIVE_BOOT v29.1 …`；`MMT_FUSION` 末尾追加 `IR_SOLO_ON=%d IR_SOLO_N=%d`。

## 4. 固件自检（`check_v291.py`，结果 `selfcheck_v291.json`）

三个 bin 全部通过：

| 判据 | NIGHT | DAY | DAYCAL |
|---|---|---|---|
| 完整 101,088 B 模型字节（含头尾）在 bin 内 | ✅ | ✅ | ✅ |
| 旧 MobileNet 模型特征（前 32 B）不出现 | ✅ | ✅ | ✅ |
| `MMT_WB_INIT`、`IR_SOLO_ON=%d`、`cause=%s`、`v29.1` 字符串在 bin 内 | ✅ | ✅ | ✅ |
| `MMT_WB r=%d`、`MMT_WB_APPLY`（仅标定版） | — | — | ✅ |

## 5. 上板冒烟（MERGE16 + v29.1）

执行脚本 `board_v291.py`（JTAG 烧 MERGE16 → 等 `MMT_LOADER_READY` → 串口 `MMTL` 协议上传）。
烧录判据：`Device ID read from JTAG: 0x10660A79` + `finished with JTAG programming`，均 PASS。

标定版（DAYCAL）实测启动序列（`evidence/v29_gate/v291/board_v291.log`）：

```
MMT_LOAD_PASS DDR_CRC
MMT_LIVE_BOOT v29.1 CROP=1 NORM=0 STRETCH=1 AE=0 LPCAM=0 FW_DEC=1 LOWPOWER=1
MMT_CFG … INPUT_SUB128=1 AI_P_TH=0 AI_VOTE=2/3 …
MMT_FUSION … IR_SOLO_ON=1 IR_SOLO_N=6
MMT_WB_INIT r=344 g=280 b=368 cal=1
MMT_CAM_PRESET name=DAY vts=1500 exp20=47824 gc=129 gf=42 mean_sensor=22
MMT_WB_STAT pix=230400 sat=0 r=1267809 g=2519844 b=1077008
MMT_WB r=556 g=280 b=641 Rmean=1210007 Gmean=2406200 Bmean=1050307 used=32 skipped=0
MMT_WB_APPLY r=556 g=280 b=641
```

- `pix=230400` 与 640×360 理论值一致 → MERGE16 的统计寄存器通路确实在工作。
- **但这次标定无效**：当时房间是暗的（`mean_sensor=22`，空场），没有白卡/灰卡，
  算出的 556/641 不能当作白平衡结果，也**没有**写进宏。标定必须在目标照明下对着白卡做。
- 随后已把非标定的 `tinyml_pdti8_v291_day.bin`（WB 固定 344/280/368）烧回板上，
  板子当前跑的就是 MERGE16 + v29.1 DAY，启动行同样有 `INPUT_SUB128=1`、`IR_SOLO_ON=1`、`MMT_WB_INIT cal=0`。

上传细节：4,676 个 64 B 块全部 ACK，约 75 s；`MMT_LOAD_CRC` 与 bin 的 CRC32 一致。

## 6. 未做（需要人到场）

- a 白平衡标定：需要白卡 + 目标照明；本次暗场数字作废。
- b 分数方向：需要真人入画看 `MMT_AI p` 是否转正；方向反了就停。
- c 20 分钟自由走动：需要人。
- d 热图边缘闪点：需要看 HDMI 屏幕（MERGE16 新增 HDMI 域 hold 违例）。
