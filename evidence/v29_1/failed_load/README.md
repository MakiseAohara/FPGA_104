# failed_load：板上没有固件在跑的那一次（2026-10-28 21:04）

## 现象

- 21:04:22 操作者按 S 启动 c 段 20 分钟脚本，上位机正常记了阶段行；
- 但 `raw_serial.log` 是 **0 字节**：整段测试板子一行串口都没输出，`MMT_DEC/MMT_AI/MMT_ALARM` 全无，
  所以"一帧都不报警"。
- 同一套上位机在 20:59（`a_wb2`）还收到过 1.27 MB 串口数据，说明 20:59→21:04 之间板子停了。

## 判断

不是判决逻辑的问题，是**板上没有固件在跑**：判决（`FW_DEC=1`）在固件里做，固件没跑就只剩 RTL，
自然不会有 `alarm_req`。

## 处置（未改位流、未重编）

1. 关掉上位机、释放 COM15；
2. 用 `evidence/v29_fw/upload_raw.py` 重新烧 MERGE16（同一个位流，SHA256 `81332CD1…`）+ 上传
   `tinyml_pdti8_v291_day.bin`（CRC32 `AE5896F2`，b 段验证过的那个）；
3. 加载结果：`MMT_LOAD_CRC AE5896F2` → `MMT_LOAD_PASS DDR_CRC` → `MMT_LIVE_BOOT v29.1`，
   `MMT_WB_INIT r=344 g=280 b=368 cal=0`，`IR_SOLO_ON=1`；
4. 30 秒复核（`evidence/v29_1/load_check/load_check_30s.log`）：66 行 `MMT_AI`，有人时 p=+107，
   离开后 p=−7…−16，`alarm_req` 保持 1（背景有人，属预期）。

## 文件

- `failed_load_c_20min_timeline.csv`：失败那次的 timeline（只有脚本阶段行）
- `failed_load_c_20min_raw_serial.log`：0 字节，证明没有串口数据
- `failed_load_a_wb2_timeline.csv` / `failed_load_a_wb2_raw_serial.log`：20:59 那次仍有数据，
  用来定位"什么时候停的"
