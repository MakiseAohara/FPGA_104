# v7_SENSE4 烧录记录 —— 2026-10-21 21:22

> **✅ 烧录成功（JTAG 临时加载，未写 SPI 闪存）。板上现在 = v7_SENSE4。**
> 两个成功判据同时出现：`Device ID read from JTAG: 0x10660A79` + `finished with JTAG programming`。
> 授权：Kevin 明确授权本次烧录（仅这一次）；指挥官下指令。原因：板子可能断过电、配置丢失（显示器无信号），需要重烧。

---

## 1. 前置核对（烧录前）

| 项 | 结果 |
|---|---|
| 位流路径 | `D:\v7work\v7_SENSE4\out\v7_SENSE4.bit` |
| 大小 | **2,634,708 B**（期望 2,634,708 B，**match**） |
| 时间戳 | 2026-10-21 18:17:21 |
| **sha256 实际** | `74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01` |
| **sha256 期望** | `74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01`（**一致**） |
| 板子 USB 在位 | ✅ FT4232HL（`VID_0403&PID_6011`）共 **9 个** PnP 实体（Converter A–D + Serial Port COM13–16 + Composite），状态全部 `OK` |
| FTDI 驱动 | ✅ 统一 **2.12.36.4**（8 个设备枚举值唯一） |
| FTDI/JTAG 占用预检 | ✅ `未发现明显占用 FTDI 的进程` |
| 前置 sha 白名单 | ✅ `sha256 一致`（`flash_vendor.ps1` 参数化校验，**未改脚本逻辑、未走旁路**） |

---

## 2. 烧录命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\FPGA\mmt\tools\flash_vendor.ps1 `
  -Bit "D:\v7work\v7_SENSE4\out\v7_SENSE4.bit" `
  -Sha256 74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01
```

- 模式：`-m jtag`（**只做 JTAG 临时加载，未写 SPI 闪存**）。
- 烧录时间：**21:22:05 → 21:22:25**（约 20 秒，一次成功；未出现 `No USB target detected`，未重试）。
- 脚本退出码：**0**。

---

## 3. 日志与判据

**日志路径**：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261021_212211.log`（735 B）
（脚本 stdout 快照：`D:\FPGA\mmt\out\evidence\v7_abc2\SENSE4\flash_stdout.log`）

**日志关键行原文：**
```
Using board profile: 'Generic Board Profile Using FT4232H' for pinout connection
Connecting to JTAG_TAP: efx_ti
jtag programming started!
JTAG Programming on hiftdi://0x0403:0x6011/1
Programming 'D:\v7work\v7_SENSE4\out\v7_SENSE4.bit' via JTAG at freq 6.0 MHz
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```
**日志尾部记录：**
```
file   : D:\v7work\v7_SENSE4\out\v7_SENSE4.bit
size   : 2634708
mtime  : 10/21/2026 18:17:21
sha256 : 74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01
mode   : jtag (JTAG 临时加载，未写 SPI 闪存)
board  : Generic Board Profile Using FT4232H
expect : Device ID read from JTAG: 0x10660A79 + finished with JTAG programming
nativeExit: 0
ts     : 20261021_212211
```

**判据逐项（脚本输出原文）：**
```
=== 烧录判据 ===
  Device ID read from JTAG : PASS  (期望 0x10660A79)
  finished with JTAG programming : PASS
  native exit code (仅参考，不作判据): 0
  设备 ID: 0x10660A79
  烧录成功
```

| 判据 | 要求 | 实测 | 判定 |
|---|---|---|---|
| `Device ID read from JTAG: 0x10660A79` | 必须逐字出现 | 出现（日志第 6 行） | ✅ PASS |
| `finished with JTAG programming` | 必须逐字出现 | 出现（日志第 7 行） | ✅ PASS |

---

## 4. 烧录内容（板载 = v7_SENSE4）

- 位流：`v7_SENSE4.bit`，**2,634,708 B**，sha256 `74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01`。
- 该位流构建信息见 `D:\FPGA\mmt\out\evidence\v7_sense4_build.md`（2026-10-21 18:17 构建；最终时序 18 setup + 18 hold 全正、0 负 slack；XLR 31,624 / Memory 118 / DSP 15）。
- 板上此前为 v7_SENSE2（16:26 烧入；本次已被覆盖）。
- **待 Kevin 观察屏幕**（本轮不下画面结论）。

### 回退参考（历史位流指纹，仅作记录）

| 位流 | 大小 | sha256 |
|---|---|---|
| **v7_SENSE4（本次板上）** | 2,634,708 B | `74024805235961A95E6D00FC9395A069E4F61F0CC697980FE03807DD1EA7AA01` |
| v7_SENSE3 | 2,616,858 B | `1164906E8DDAC2D1CC6DC7783F3A0D33B31EA2AB1FA6F791D0A6C02C33A224A5` |
| v7_SENSE2 | 2,628,522 B | `0F48EED8316972E4E9DF0DB15E4756385C854EF451CECB24072CFF2B8C38AB64` |

> 位流 sha256 不可复现，仅作"这一份产物"的指纹。

---

## 5. 边界声明

- 只执行了 JTAG 临时加载（`-m jtag`），**未写 SPI 闪存**。
- 未改任何 RTL/约束/IP；未 push；未删文件；未改 `flash_vendor.ps1` 逻辑（sha 白名单通过参数正常登记）。
- 本次烧录仅此一次（按授权）。
