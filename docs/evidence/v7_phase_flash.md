# v7 阶段记录：XV 已构建并烧录 / Y（work2 底）已构建未烧 / L 作废

- 工程根：`D:\FPGA\易灵思\工作区\07_官方demo工程`
- 构建脚本：`D:\FPGA\mmt\tools\v7_flow.ps1 -Work <工程目录> -Tag <标签>`
- 流程：efx_map → efx_pnr#1 → efx_run -f interface → filter_interface → efx_pnr --sync_file → bitgen
- 本次记录时间：2026-10-19 21:39 ~ 21:55（Asia/Shanghai）
- 本文件在前一版（记录 L/X 与"Y 以 A2 为底"）基础上更新：**新增 XV**，并**修正 Y 的底本为 v7_work2**。

> **画面由 Kevin 判断，本文件不下结论。**
> 本文件只记录可复核的客观事实：改了什么、diff 原文、构建是否通过（SDC/hold）、烧了什么、sha256 是多少。

---

## 1. 基线事实（不变）

| 变体 | 定义 |
|---|---|
| `v7_work2` | 厂商 v7 原样：增益由 VIO 驱动，初值 `r=0x118 / g=0xff / b=0x15e`，`0x3221=0x66` |
| `v7_A2` | v7_work2 + 增益硬编码 255（`r_gain/g_gain/b_gain` 三行改成 `16'd255`） |
| `v7_X` | v7_A2 + `debayer_top_2to1.v:85` 像素字节交换 |
| `v7_L` | 作废（A2 增益三路相等，翻行奇偶功能等价），未烧、不应烧 |

`v7_work2\rtl\ti60f225_oob_top.v` 第 783-785 行原文（VIO 驱动）：

```
783: 	.r_gain       (|r_gain? r_gain:255 ),
784:   .g_gain       (|g_gain? g_gain:255 ),
785:   .b_gain       (|b_gain? b_gain:255 ),
```

---

## 2. 本次修正：Y 的底本改为 v7_work2（重要）

- 前一版 Y 是 `Copy-Item v7_A2 → v7_Y`，因此 **Y 除了 `raw_to_rgb.v:349` 还夹带了 A2 的增益硬编码**。
  逐文件 SHA256 比对（v7_work2 vs 旧 v7_Y）当时为 **2 个文件不同**：
  `debayer\raw_to_rgb.v` 与 `ti60f225_oob_top.v`（后者 783-785 为 `16'd255`）。
  该旧 Y 位流：2,564,964 B，SHA256 `7010A4B37D82065893C929C3A20767F52994A389299E0F5F18DA53C2F352A728`。
- 按任务书要求"以 v7_work2 为底、只改 `raw_to_rgb.v:349`"，本次：
  1. 把 `v7_Y\rtl\ti60f225_oob_top.v` 恢复成 `v7_work2` 原文件（783-785 回到 VIO 表达式）；
  2. 清掉 `v7_Y\{out,work_syn,work_pnr,outflow}` 全量重编（Tag `Y`）。
- 旧位流与其 build.log 已随 `v7_Y\out` 清理一并删除，**旧 Y（A2 底）作废**，`v7_Y.bit` 现为下文新构建结果。

---

## 3. v7_XV：构造与 diff 证明

### 3.1 构造

```
Copy-Item v7_work2 v7_XV -Recurse
Remove-Item v7_XV\{out,work_syn,work_pnr,outflow} -Recurse -Force
```

### 3.2 `rtl\debayer\debayer_top_2to1.v` 第 85 行

改前（原文，行首为 Tab）：

```
			.i_p		(w_gain_data),	//(raw_datax4_i	),//
```

改后（原文）：

```
			.i_p		({w_gain_data[7:0],w_gain_data[15:8]}),	//(raw_datax4_i	),//
```

- 替换前精确匹配数 = **1**（`(w_gain_data),\t//(raw_datax4_i\t),//` 全文唯一），确认唯一命中后才写入。
- 文件 hash / 字节数可复核：
  - 改前（= work2 原文件）`F6240A41141046CE9888CFF98A5E59FB18CE81B7E7DE46DC2DB70C8F144B6DD9`，3,353 B
  - 改后（XV）`8E27D9167860689553DF1E1CA57CFDBD36FCCCFFFA3FE3462D38CB9CAAFDD660`，3,378 B

### 3.3 全 rtl 树逐文件 SHA256 比对（v7_work2 vs v7_XV）

文件数：work2 = 120，XV = 120；无缺失、无新增。

```
CHANGED: debayer\debayer_top_2to1.v
  work2=F6240A41141046CE9888CFF98A5E59FB18CE81B7E7DE46DC2DB70C8F144B6DD9
  v7_XV=8E27D9167860689553DF1E1CA57CFDBD36FCCCFFFA3FE3462D38CB9CAAFDD660
files_A=120 files_B=120 changed=1 missing=0 extra=0
```

行级 diff（144 行对 144 行，仅第 85 行）：

```
L85
  work2: 			.i_p		(w_gain_data),	//(raw_datax4_i	),//
  v7_XV: 			.i_p		({w_gain_data[7:0],w_gain_data[15:8]}),	//(raw_datax4_i	),//
```

结论：**XV 全 rtl 树仅 `debayer\debayer_top_2to1.v` 一个文件不同，且仅第 85 行**，无夹带改动。

### 3.4 `v7_XV\rtl\ti60f225_oob_top.v` 第 783-785 行（仍是 VIO 原表达式）

```
783: 	.r_gain       (|r_gain? r_gain:255 ),
784:   .g_gain       (|g_gain? g_gain:255 ),
785:   .b_gain       (|b_gain? b_gain:255 ),
```

即 XV 的增益仍由 VIO 驱动（不是 A2 的 `16'd255`）。

---

## 4. v7_XV：构建结果与验收

- 构建区间：`21:41:12` → `21:46:47`，5 步退出码全 0
- 位流：`v7_XV\out\v7_XV.bit`
- 大小：**2,579,904 B**
- SHA256：**`4D91C21A0D842FDDBF66679685D9172D78C05B268BD18B1BC48366F019A2C020`**
- SDC 验收（`build.log` 原文）：`'No valid pin(s) found for clock' = 0` ✅（必须 0）；`'No clocks matched' = 87`

hold 违例（`build.log` 原文，全部）：

```
WARNING  : Clock domain between tx_cal_clk_90edge (rising) and tx_cal_clk_90edge (rising) may not meet (slack: -0.532 ns) the hold (min) timing requirement
WARNING  : Clock domain between sdram_clk (rising) and sdram_clk (rising) may not meet (slack: -0.322 ns) the hold (min) timing requirement
WARNING  : Clock domain between rx_cal_clk (rising) and rx_cal_clk (rising) may not meet (slack: -0.731 ns) the hold (min) timing requirement
WARNING  : Clock domain between tx_cal_clk (rising) and tx_cal_clk (rising) may not meet (slack: -0.268 ns) the hold (min) timing requirement
WARNING  : Clock domain between core_clk (rising) and core_clk (rising) may not meet (slack: -0.659 ns) the hold (min) timing requirement
```

说明：均为同域内部 hold 负 slack（-0.268 ~ -0.731 ns），与 X（-0.286 ~ -0.814）同量级，属工程既有状况，未见因 1 行改动引入新时钟域或显著恶化。

---

## 5. 烧录记录：XV（2026-10-19 21:47，主记录；21:48 同一位流再烧一次）

- 命令：`flash_vendor.ps1 -Bit ...\v7_XV\out\v7_XV.bit -Sha256 <从文件实时计算>`
- 前置检查：文件类型 .bit ✅ / 大小 2,579,904 B ✅ / sha256 一致（实际 = 期望 = `4D91C2…2C020`）✅ / FTDI 2.12.36.4 ✅
- 模式：`-m jtag`，**仅 JTAG 临时加载，不写 SPI 闪存**
- 日志：
  - `D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_214709.log`
  - `D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_214844.log`（同一 `v7_XV.bit`、同一 sha256，再烧一次；两次 nativeExit 均为 0）
  - 控制台留存：`D:\FPGA\mmt\out\evidence\v7_XV_flash_console.log`

关键两行原文（两行同时出现 ⇒ 成功）：

```
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

判据（工具输出原文）：

```
=== 烧录判据 ===
  Device ID read from JTAG : PASS  (期望 0x10660A79)
  finished with JTAG programming : PASS
  native exit code (仅参考，不作判据): 0
  设备 ID: 0x10660A79
  烧录成功
```

---

## 6. v7_Y：构造与 diff 证明

### 6.1 构造

- 底本：`v7_work2`（增益仍由 VIO 驱动）
- `v7_Y\rtl\ti60f225_oob_top.v` 与 work2 逐字节相同（783-785 为 VIO 表达式，见 §1）
- 唯一改动：`rtl\debayer\raw_to_rgb.v` 第 349 行

### 6.2 `raw_to_rgb.v` 第 340-349 行（改前原文）

```
340: 	end else begin
341: 
342: 		if (!r_de_00_1P) begin
343: 			r_r_00_00_1P	<= {PW{1'b0}};
344: 			r_g_00_00_1P	<= {PW{1'b0}};
345: 			r_b_00_00_1P	<= {PW{1'b0}};
346: (空行)
347: (仅含 Tab 的空行)
348: (空行)
349: 		end else if (r_y_cnt[0])begin //偶数行
```

改后（原文）：

```
349: 		end else if (!r_y_cnt[0])begin //偶数行
```

- 替换：精确字符串替换，替换前精确匹配数 = **1**，确认唯一命中后才写入。
- 文件 hash / 字节数：`8EABEA4DDE2241A8D896B132EB991C4637ABC9441D5F58A9F448E14025C0B860`（14,064 B）
  → `264F3371070A52685C876842D037195480FCD37E087944568304671720C00804`（14,065 B，只多一个 `!`）

### 6.3 全 rtl 树逐文件 SHA256 比对（v7_work2 vs 新 v7_Y）

文件数：work2 = 120，Y = 120；无缺失、无新增。

```
CHANGED: debayer\raw_to_rgb.v
  work2=8EABEA4DDE2241A8D896B132EB991C4637ABC9441D5F58A9F448E14025C0B860
  v7_Y =264F3371070A52685C876842D037195480FCD37E087944568304671720C00804
files_A=120 files_B=120 changed=1 missing=0 extra=0
```

行级 diff（417 行对 417 行，仅第 349 行）：

```
L349
  work2: 		end else if (r_y_cnt[0])begin //偶数行
  v7_Y : 		end else if (!r_y_cnt[0])begin //偶数行
```

结论：**新 Y 相对 v7_work2 只有 `debayer\raw_to_rgb.v` 第 349 行一处不同**，增益仍走 VIO。

---

## 7. v7_Y：构建结果与验收

- 构建区间：`21:46:57` → `21:53:05`，5 步退出码全 0
- 位流：`v7_Y\out\v7_Y.bit`
- 大小：**2,582,406 B**
- SHA256：**`608A84BCAD36A157FBEF89E5A63B7F7078100D618B1D01E1C57514A64EE74BC6`**
- SDC 验收（`build.log` 原文）：`'No valid pin(s) found for clock' = 0` ✅（必须 0）；`'No clocks matched' = 87`

hold 违例（`build.log` 原文，全部）：

```
WARNING  : Clock domain between tx_cal_clk_90edge (rising) and tx_cal_clk_90edge (rising) may not meet (slack: -0.340 ns) the hold (min) timing requirement
WARNING  : Clock domain between sdram_clk (rising) and sdram_clk (rising) may not meet (slack: -0.364 ns) the hold (min) timing requirement
WARNING  : Clock domain between rx_cal_clk (rising) and rx_cal_clk (rising) may not meet (slack: -0.599 ns) the hold (min) timing requirement
WARNING  : Clock domain between tx_cal_clk (rising) and tx_cal_clk (rising) may not meet (slack: -0.455 ns) the hold (min) timing requirement
WARNING  : Clock domain between core_clk (rising) and core_clk (rising) may not meet (slack: -0.633 ns) the hold (min) timing requirement
```

**Y 未烧。**

---

## 8. 变体状态总表（本次结束时）

| 变体 | 改动 | 位流大小 | SHA256 | 烧录 |
|---|---|---|---|---|
| v7_A2 | work2 + 增益固定 `16'd255` | 2,564,964 B | `ACE34702ECFD43E2E0B79E5F7296978C09A6DABCF10644DF57F835F6228451D2` | 已烧（早前） |
| v7_L | A2 + `rgb_gain_v1.v:68` 取反 | 2,560,617 B | `0A0DC4582CC714B9B7B106EFF2FB13EEF7094094F303A9D15A352CDC8BEDB5E9` | **作废，未烧** |
| v7_X | A2 + `debayer_top_2to1.v:85` 字节交换 | 2,564,415 B | `C9F74CC98B3DCC11DCDBA2C587868D30B17B6ACD4919C923CE4094F629AAE219` | 已烧 21:35:44 |
| **v7_XV** | **work2 + `debayer_top_2to1.v:85` 字节交换** | **2,579,904 B** | **`4D91C21A0D842FDDBF66679685D9172D78C05B268BD18B1BC48366F019A2C020`** | **已烧 21:47:09（21:48:44 再烧一次）** |
| **v7_Y** | **work2 + `raw_to_rgb.v:349` y 奇偶取反** | **2,582,406 B** | **`608A84BCAD36A157FBEF89E5A63B7F7078100D618B1D01E1C57514A64EE74BC6`** | **未烧** |

---

## 9. 未做事项（明确）

- **v7_Y 未烧录**（位流已就绪，等指令）。
- **v7_L / v7_B2 / v7_C2 / v7_P 均未烧录**（L 已作废）。
- 只烧了 `v7_XV.bit`（两次，同一位流、同一 sha256）；未写 SPI 闪存，未生成/使用 `.hex`。
- 构建期只改了 2 个文件各 1 行：`v7_XV\rtl\debayer\debayer_top_2to1.v:85`、`v7_Y\rtl\debayer\raw_to_rgb.v:349`。
- 未推 GitHub。

---

## 10. 判断边界

**画面由 Kevin 判断，本文件不下结论。**

---

## 11. v7_XZ：构造、diff 证明、构建与烧录（2026-10-19 21:55 ~ 22:03）

### 11.1 构造

以 **v7_XV** 为底（即 work2 + `debayer_top_2to1.v:85` 字节交换，增益仍走 VIO）：

```
Copy-Item v7_XV v7_XZ -Recurse
Remove-Item v7_XZ\{out,work_syn,work_pnr,outflow} -Recurse -Force
```

### 11.2 `v7_XZ\rtl\debayer\raw_to_rgb.v` 第 385-405 行（改前原文，行首为 Tab）

```
385: 			// 	r_g_00_00_1P[PW-1:P_DEPTH]	<= (((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1)) >> 1) + (((r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1)) >> 1);		
386: 			// 	r_b_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;
387: 			
388: 			// end
389: 			//G R G R 
390: 			if (r_valid_1P)
391: 			begin
392: 				r_r_00_00_1P[P_DEPTH-1:0]	<= w_r_00_00_l0>>2;//(((r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_11_2P_1 >> 1)) >> 1) + (((r_bayer_01_00_1P_1 >> 1) + (r_bayer_11_11_2P_1 >> 1)) >> 1);
393: 				r_g_00_00_1P[P_DEPTH-1:0]	<= w_g_00_00_l0>>2;//(((r_bayer_11_00_1P_0 >> 1) + (r_bayer_01_00_1P_0 >> 1)) >> 1) + (((r_bayer_00_00_1P_1 >> 1) + (r_bayer_00_11_2P_1 >> 1)) >> 1);
394: 				r_b_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0; 
395: 				
396: 				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_r_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
397: 				r_g_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;				
398: 				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
399: 				
400: 			end
401: 		end
402: 	end	
403: end
404: 
405: 
```

### 11.3 只改两处（精确字符串替换，替换前匹配数各 = 1）

第 396 行，改前：

```
<TAB><TAB><TAB><TAB>r_r_00_00_1P[PW-1:P_DEPTH]<TAB><= w_r_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
```

改后：

```
<TAB><TAB><TAB><TAB>r_r_00_00_1P[PW-1:P_DEPTH]<TAB><= w_b_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
```

第 398 行，改前：

```
<TAB><TAB><TAB><TAB>r_b_00_00_1P[PW-1:P_DEPTH]<TAB><= w_b_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
```

改后：

```
<TAB><TAB><TAB><TAB>r_b_00_00_1P[PW-1:P_DEPTH]<TAB><= w_r_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
```

即红/蓝高位字节的来源互换：`r_r` 取 `w_b_00_00_h0`、`r_b` 取 `w_r_00_00_h0`（wire 名未改）。

### 11.4 全 rtl 树逐文件 SHA256 比对（v7_XV vs v7_XZ）

文件数：XV = 120，XZ = 120；无缺失、无新增。

```
DIFF debayer\raw_to_rgb.v
  v7_XV=8EABEA4DDE2241A8D896B132EB991C4637ABC9441D5F58A9F448E14025C0B860
  v7_XZ=AAC0BC773D4C829BD3F1580A350B1957441BB1FC9588FE8D9E69CF36106F5516
files_A=120 files_B=120 changed=1 missing=0 extra=0
```

行级 diff（417 行对 417 行，仅 396 / 398 两行）：

```
--- L396 v7_XV: <TAB><TAB><TAB><TAB>r_r_00_00_1P[PW-1:P_DEPTH]<TAB><= w_r_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
+++ L396 v7_XZ: <TAB><TAB><TAB><TAB>r_r_00_00_1P[PW-1:P_DEPTH]<TAB><= w_b_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
--- L398 v7_XV: <TAB><TAB><TAB><TAB>r_b_00_00_1P[PW-1:P_DEPTH]<TAB><= w_b_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
+++ L398 v7_XZ: <TAB><TAB><TAB><TAB>r_b_00_00_1P[PW-1:P_DEPTH]<TAB><= w_r_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
```

结论：**XZ 全 rtl 树仅 `debayer\raw_to_rgb.v` 一个文件不同，且仅第 396 / 398 两行**，无夹带改动。

### 11.5 `v7_XZ\rtl\ti60f225_oob_top.v` 第 783-785 行（仍是 VIO 表达式）

```
783: 	.r_gain       (|r_gain? r_gain:255 ),
784:   .g_gain       (|g_gain? g_gain:255 ),
785:   .b_gain       (|b_gain? b_gain:255 ),
```

### 11.6 构建结果与验收

- 构建区间：`21:55:50` → `22:03:03`，5 步退出码全 0
- 位流：`v7_XZ\out\v7_XZ.bit`
- 大小：**2,583,228 B**
- SHA256：**`F6EE3856F8BBD0FF78FE7490E7D4DF32284071F1D01ED5322CA4A57F3FDEC5F0`**
- SDC 验收（`build.log` 原文）：`'No valid pin(s) found for clock' = 0` ✅（必须 0）；`'No clocks matched' = 87`

hold 违例（`build.log` / `pnr2.log` 原文，全部）：

```
WARNING  : Clock domain between tx_cal_clk_90edge (rising) and tx_cal_clk_90edge (rising) may not meet (slack: -0.492 ns) the hold (min) timing requirement
WARNING  : Clock domain between sdram_clk (rising) and sdram_clk (rising) may not meet (slack: -0.494 ns) the hold (min) timing requirement
WARNING  : Clock domain between rx_cal_clk (rising) and rx_cal_clk (rising) may not meet (slack: -0.086 ns) the hold (min) timing requirement
WARNING  : Clock domain between tx_cal_clk (rising) and tx_cal_clk (rising) may not meet (slack: -0.226 ns) the hold (min) timing requirement
```

说明：均为同域内部 hold 负 slack（-0.086 ~ -0.494 ns），与 XV/Y 同量级，未见因 2 行改动引入新时钟域或显著恶化。

### 11.7 烧录记录：XZ（2026-10-19 22:03）

- 命令：`flash_vendor.ps1 -Bit ...\v7_XZ\out\v7_XZ.bit -Sha256 <从文件实时计算>`
- 前置检查：.bit ✅ / 大小 2,583,228 B ✅ / sha256 一致（实际 = 期望 = `F6EE38…EC5F0`）✅ / FTDI 2.12.36.4 ✅
- 模式：`-m jtag`，**仅 JTAG 临时加载，不写 SPI 闪存**
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_220341.log`

关键两行原文（两行同时出现 ⇒ 成功）：

```
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

判据：`Device ID read from JTAG : PASS` / `finished with JTAG programming : PASS` / `烧录成功`，native exit code = 0。

### 11.8 状态更新

| 变体 | 改动 | 位流大小 | SHA256 | 烧录 |
|---|---|---|---|---|
| **v7_XZ** | **XV + `raw_to_rgb.v:396/398` 红蓝高位字节互换** | **2,583,228 B** | **`F6EE3856F8BBD0FF78FE7490E7D4DF32284071F1D01ED5322CA4A57F3FDEC5F0`** | **已烧 22:03:41** |

**Y 未烧；L / B2 / C2 / P 未烧；未推 GitHub。**

---

## 12. 判断边界（重申）

**画面由 Kevin 判断，本文件不下结论。**

---

## 13. 更正声明与补充口径（22:14 追加，A2 基线执行者补记）

### 13.1 更正声明（推翻旧说法）

1. **`rtl\debayer\debayer_top_2to1.v:85` 原文是 `.i_p (w_gain_data)`，没有字节交换。**
   只有 X / XZ 变体把它改成 `.i_p ({w_gain_data[7:0], w_gain_data[15:8]})`。
2. **此前"L79 字节交换"的说法作废（错误）。**
   L 从未改过 `debayer_top_2to1.v`：该文件在 A2 与 L 之间 `Compare-Object` 返回空，
   逐文件 SHA256 也完全相同。L 唯一改动在 `rgb_gain_v1.v:68`。

A2 vs X 逐字 diff（`Compare-Object`，仅 `debayer\debayer_top_2to1.v` 不同，144 行对 144 行）：

```
--- debayer\debayer_top_2to1.v ---
=> 			.i_p		({w_gain_data[7:0],w_gain_data[15:8]}),	//(raw_datax4_i	),//
<= 			.i_p		(w_gain_data),	//(raw_datax4_i	),//
```

（`=>` = X 侧，`<=` = A2 侧。）

### 13.2 L 作废的完整理由

- L 的改动：`rgb_gain_v1.v:68` `if(r_line_cnt)` → `if(!r_line_cnt)`，翻转**增益级的行奇偶**。
- A2 三路增益固定且相等（`r=g=b=16'd255`），行奇偶怎么翻，三路取到的都是同一个常量
  ⇒ **L 与 A2 功能等价**，不构成有效变体。
- **L 未烧，也不应烧。**

A2 vs L 逐字 diff（仅 `rgb_gain_v1.v` 不同，95 行对 95 行）：

```
--- debayer\rgb_gain_v1.v ---
=> 	if(!r_line_cnt) begin
<= 	if(r_line_cnt) begin
```

### 13.3 L / X 构建验收（复述关键项）

| 项 | v7_L | v7_X |
|---|---|---|
| 大小 | 2,560,617 B | 2,564,415 B |
| SHA256 | `0A0DC4582CC714B9B7B106EFF2FB13EEF7094094F303A9D15A352CDC8BEDB5E9` | `C9F74CC98B3DCC11DCDBA2C587868D30B17B6ACD4919C923CE4094F629AAE219` |
| `'No valid pin(s) found for clock'` | **0** ✅ | **0** ✅ |
| `'No clocks matched'` | 87 | 87 |

L 的 hold 违例行（build.log 原文，5 条：tx_cal_clk_90edge -0.307 / sdram_clk -0.498 /
rx_cal_clk -0.726 / tx_cal_clk -0.407 / core_clk -0.552 ns）。
X 的 hold 违例行（build.log 原文，5 条：-0.433 / -0.324 / -0.814 / -0.286 / -0.723 ns）。
均为既有同族 hold warning，量级与 A2 一致。

### 13.4 A2 基线 Y 对照构建（已作废，仅留档，**不要烧**）

在 §2 把 Y 底本改为 `v7_work2` 之前，曾按旧任务书以 A2 为底构建过 Y：

- 目录：`v7_Ya`（= `v7_A2` 全新复制 + 仅 `raw_to_rgb.v:349` 一行；
  `rtl\ti60f225_oob_top.v` 为 A2 版 `.r_gain (16'd255)`）
- 位流：`v7_Ya\out\v7_Ya.bit`，2,564,964 B，
  SHA256 `CD8A8F761BBF466897F97E3B805B4B9C7BF5D1FBA4C49A110CCF6866F32B3422`
- SDC：`'No valid pin(s) found for clock' = 0` ✅；hold 3 条（-0.370 / -0.582 / -0.341 ns）
- 收益：与 work2 底 Y 对照，可区分"raw 翻转"与"增益来源（VIO vs 硬编码 255）"各自的贡献。
- 状态：**未烧**；若不需要，可直接删除 `v7_Ya` 目录。

### 13.5 目录状态说明（可复核）

- `v7_Y\out\build.log` 现内容为 22:03:25 一次**中止的 A2 基线重建**（`[1] efx_map 退出码=0` 后
  `[2] efx_pnr#1 退出码=-1`），与 §7 引用的 21:46 那次构建日志**不是同一份**（那份已被覆盖丢失）。
- `v7_Y\out\v7_Y.bit` 仍是 §7 的 21:53 构建产物，SHA256 经复核 = `608A84BC…74BC6`，未变。
- `v7_Y\out\v7_Y_vendorTop_608A84BC.bit`、`v7_Y_vendorTop_8777E573.bit` 为该时期同源位流的副本。

### 13.6 判断边界

**画面由 Kevin 判断，本文件不下结论。**

---

## §14 XZL 上板结果（2026-10-19 22:4x）

**Kevin 反馈原文**：马赛克消失、点点消失，**红线显示为红色**（R/B 无对调），**白纸偏黄绿**（B 增益明显不够）。

**判定**：**XZL = 当前最佳基线**。马赛克/彩点问题已解决；剩余唯一问题是白平衡（B 不足 ⇒ 偏黄绿）。

**根因链（已证实）**：
1. 传感器 `0x3221=0x66`（镜像+倒置）⇒ 拜耳相位相对 debayer 假定值对角翻转
2. `debayer_top_2to1.v:85` 缺字节交换 ⇒ 像素奇偶错 ⇒ **X/XZ 修好**（紫→绿，蓝点消失）
3. `raw_to_rgb.v:396/398` R/B 插值来源对调 ⇒ **XZ 修好**（蓝点彻底消失，红线正确）
4. `line_buffer` 使 `raw_to_rgb` 的中心行 = 输入行 n−1，而 `r_y_cnt` 计当前行 n ⇒ **增益级 `r_line_cnt` 与去马赛克的行奇偶差一行** ⇒ G 被乘了 B/R 增益 ⇒ **XZL 修好**（马赛克/绿点消失）

**剩余**：白平衡缺失（VIO 默认 R=0x118/G=0xff/B=0x15e 不足以补偿）。

**画面由 Kevin 判断，本节记录的是他的原话。**

---

## 14. XZL / XZA 对照构建（底 = `v7_XZ`，各只改一处），XZL 已烧、XZA 只编不烧

时间：2026-10-19 22:35–22:47。底本 `v7_XZ`（板上原状态）未动；新目录为全新复制，未复用任何已有目录。

### 14.1 `v7_XZL`：`rgb_gain_v1.v:68` 取反（`if(r_line_cnt)` → `if(!r_line_cnt)`）

底：`v7_XZ` 全新复制；删除 `out` / `work_syn` / `work_pnr` / `outflow`。`rtl` 文件数 120。

`rtl\debayer\rgb_gain_v1.v` 第 60–75 行原文：

```verilog
wire [P_DEPTH-1:0] pix_high = i_data[P_DEPTH*2-1:P_DEPTH];
wire [P_DEPTH-1:0] pix_low  = i_data[P_DEPTH-1:0];

reg [Q_WIDTH+P_DEPTH-1:0] mul_high;
reg [Q_WIDTH+P_DEPTH-1:0] mul_low;

//多路选择对应通道增益
always @(*) begin
	if(r_line_cnt) begin
		//奇数行 high=Gr(gain_g)  low=R(gain_r)
		mul_high = pix_high * gain_g;
		mul_low  = pix_low  * gain_r;
	end
	else begin
		//偶数行 high=B(gain_b)  low=Gb(gain_g)
		mul_high = pix_high * gain_b;
		mul_low  = pix_low  * gain_g;
	end
end
```

第 68 行改前/改后（精确命中次数 = 1，改后旧串残留 = 0）：

```text
改前 L68 = [	if(r_line_cnt) begin]
改后 L68 = [	if(!r_line_cnt) begin]
```

`v7_XZ\rtl` 与 `v7_XZL\rtl` 逐文件 SHA256 比对：各 120 文件，**只有 1 个文件不同**：

```text
DIFF: debayer\rgb_gain_v1.v  XZ=EBC9C0B0FC589D7620B708FDD7A952E37CCC27B1ABFA94E041D0E10323602B09 XZL=020CFBFAA5D38A9B1D1C26AA804AFF3B55EC1790220D4651D9213D2177789161
```

行级 diff（95 行 vs 95 行，只有 1 行）：

```text
=> [	if(!r_line_cnt) begin]
<= [	if(r_line_cnt) begin]
```

`rtl\ti60f225_oob_top.v:783-785` 仍为 VIO 增益表达式（未改）：

```text
	.r_gain       (|r_gain? r_gain:255 ),
  .g_gain       (|g_gain? g_gain:255 ),
  .b_gain       (|b_gain? b_gain:255 ),
```

构建：`v7_flow.ps1 -Work ...\v7_XZL -Tag XZL`，5 步全部退出码 0。

| 项 | v7_XZL |
|---|---|
| 位流 | `v7_XZL\out\v7_XZL.bit` |
| 大小 | **2,580,369 B** |
| SHA256 | `1DD0EB7E5AB663FB8F780F2B8E40B9BDE307B9CD26A7E75D66789F50BE93D4AA` |
| `'No valid pin(s) found for clock'` | **0** ✅ |
| `'No clocks matched'` | 87 |
| hold 违例 | 5 条（build.log 原文） |

hold 原文（slack）：tx_cal_clk_90edge -0.431 / sdram_clk -0.565 / rx_cal_clk -0.462 /
tx_cal_clk -0.349 / core_clk -0.540 ns（与同族既有 warning 量级一致）。

### 14.2 `v7_XZL` 烧录（**只烧了 XZL**）

- 位流：`v7_XZL\out\v7_XZL.bit`，SHA256 由脚本实时计算并与文件一致
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_224328.log`
- 关键两行原文：

```text
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

判据两行均 PASS，脚本 exit code = 0，**烧录成功**（仅 JTAG 临时加载，不写 SPI 闪存）。

注：同一动作在 22:42:52 首次尝试时 FTDI 报 `OSError: No such device`（`usbtools.py` 取设备索引失败），
判据 FAIL、exit code = 1，未发生任何编程；22:43:28 原样重试即成功。失败日志留档
`vendor_flash_20261019_224252.log`，成功日志为上面那一份。

### 14.3 `v7_XZA`：VIO 增益改为常量 255（**只编不烧**）

底：`v7_XZ` 全新复制；删除 `out` / `work_syn` / `work_pnr` / `outflow`。`rtl` 文件数 120。

`rtl\ti60f225_oob_top.v` 原第 780–790 行（节选，含目标三行）：

```text
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b,ch0_g}	),
	.r_gain       (|r_gain? r_gain:255 ),
  .g_gain       (|g_gain? g_gain:255 ),
  .b_gain       (|b_gain? b_gain:255 ),
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
```

改后 783–785：

```text
	.r_gain       (16'd255),
  .g_gain       (16'd255),
  .b_gain       (16'd255),
```

逐文件 SHA256 比对：各 120 文件，**只有 1 个文件不同**：

```text
DIFF: ti60f225_oob_top.v  XZ=D22074352D6F895056852B66B8F2DEE77B9BC45D39D4BCFFA4BFD3876A2F0141 XZA=32F1535CFCF3CB4A63FCB23AAA2962DA8804E0F2725C4D55930B83197CAB5201
```

行级 diff（1058 行 vs 1058 行，只有 3 行）：

```text
=> [	.r_gain       (16'd255),]
=> [  .g_gain       (16'd255),]
=> [  .b_gain       (16'd255),]
<= [	.r_gain       (|r_gain? r_gain:255 ),]
<= [  .g_gain       (|g_gain? g_gain:255 ),]
<= [  .b_gain       (|b_gain? b_gain:255 ),]
```

构建：`v7_flow.ps1 -Work ...\v7_XZA -Tag XZA`，5 步全部退出码 0。

| 项 | v7_XZA |
|---|---|
| 位流 | `v7_XZA\out\v7_XZA.bit` |
| 大小 | **2,563,992 B** |
| SHA256 | `D59FE53233B3CC1C09C4D64FFA3E747B5F1A689BEFBD3F4187E6F831EB520DC1` |
| `'No valid pin(s) found for clock'` | **0** ✅ |
| `'No clocks matched'` | 87 |
| hold 违例 | 3 条（tx_cal_clk_90edge -0.468 / sdram_clk -0.387 / tx_cal_clk -0.153 ns） |
| 状态 | **只编不烧** —— 未下发到板上，未写 SPI 闪存 |

### 14.4 本轮烧录边界（可复核）

- 烧录：**仅 `v7_XZL`** 一次成功（另有 22:42:52 一次未编程的失败尝试）。
- 未烧：`v7_XZA`、`v7_Y`、`v7_Ya`、`v7_L`、`v7_B2`、`v7_C2`、`v7_P*`，以及底本 `v7_XZ`/`v7_XV`/`v7_work2`。
- 未推送 GitHub。
- 本轮新增目录仅 `v7_XZL`、`v7_XZA`；已有目录未被修改。

### 14.5 判断边界

**画面由 Kevin 判断，本文件不下结论。**
---

## 15. v7_WB1 / v7_WB2 / v7_WB3：基于 v7_XZL 的白平衡三档（只编 WB1/WB3，仅烧 WB2）

- 记录时间：2026-10-19 22:49 ~ 23:00（Asia/Shanghai）
- 底本：**`v7_XZL`**（当前最佳基线；马赛克/彩点/绿点已修，仅剩白平衡偏黄绿）
- 改动范围：**每个版本只改 `debug_top.v` 的 2 行** —— `PROBE_OUT0_INIT_VAL`（R 增益，Q8.8）与 `PROBE_OUT2_INIT_VAL`（B 增益，Q8.8）。
  **`PROBE_OUT1`（G=`'hff`）与 `PROBE_OUT3`（gamma=`'h0`）三版均未触碰。**

> **画面由 Kevin 判断，本文件不下结论。**
> **WB1/WB3 未烧，等 Kevin 看完 WB2 后按偏色方向决定。**

### 15.1 底本原文：`v7_XZL\debug_top.v` 第 98–110 行

```text
98:         .PROBE_OUT0_WIDTH       ( 16 ),
99:         .PROBE_OUT1_WIDTH       ( 16 ),
100:         .PROBE_OUT2_WIDTH       ( 16 ),
101:         .PROBE_OUT3_WIDTH       ( 1 ),
102:         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
103:         .PROBE_OUT1_INIT_VAL    ( 'hff ),
104:         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
105:         .PROBE_OUT3_INIT_VAL    ( 'h0 )
106:     ) vio0 (
107:         .bscan_CAPTURE          ( bscan_CAPTURE ),
108:         .bscan_DRCK             ( bscan_DRCK ),
109:         .bscan_RESET            ( bscan_RESET ),
110:         .bscan_RUNTEST          ( bscan_RUNTEST ),
```

三版档位（R/B 增益，Q8.8）：

| 版本 | `PROBE_OUT0_INIT_VAL`（R） | `PROBE_OUT2_INIT_VAL`（B） | R 十进制 | B 十进制 |
|---|---|---|---|---|
| **v7_WB1** | `'h140` | `'h280` | 320 / 256 = 1.250 | 640 / 256 = 2.500 |
| **v7_WB2** | `'h180` | `'h340` | 384 / 256 = 1.500 | 832 / 256 = 3.250 |
| **v7_WB3** | `'h1C0` | `'h400` | 448 / 256 = 1.750 | 1024 / 256 = 4.000 |

### 15.2 改前 / 改后原文（每版替换各命中 1 次）

替换采用整行精确字面匹配，`hits=1` 校验通过后才写入；写入后回读打印新行。

**v7_WB1**

```text
改前 L102:         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
改后 L102:         .PROBE_OUT0_INIT_VAL    ( 'h140 ),
改前 L104:         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
改后 L104:         .PROBE_OUT2_INIT_VAL    ( 'h280 ),
```

**v7_WB2**

```text
改前 L102:         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
改后 L102:         .PROBE_OUT0_INIT_VAL    ( 'h180 ),
改前 L104:         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
改后 L104:         .PROBE_OUT2_INIT_VAL    ( 'h340 ),
```

**v7_WB3**

```text
改前 L102:         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
改后 L102:         .PROBE_OUT0_INIT_VAL    ( 'h1C0 ),
改前 L104:         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
改后 L104:         .PROBE_OUT2_INIT_VAL    ( 'h400 ),
```

未改动的两行（三版一致，可复核）：

```text
L103:         .PROBE_OUT1_INIT_VAL    ( 'hff ),
L105:         .PROBE_OUT3_INIT_VAL    ( 'h0 )
```

### 15.3 diff 证明：每版只有 1 个文件不同、行级只有 2 行

**逐文件 SHA256 全目录比对**（`v7_XZL` 157 个文件 vs `v7_WBn` 157 个文件；两侧的 `out`/`work_syn`/`work_pnr`/`outflow` 为构建产物目录，比对时排除）：

```text
===== v7_XZL vs v7_WB1 =====
files compared: 157 ; differing: 1
  DIFF: debug_top.v
    XZL =81C1402E39E460E4BF81723534176D2D0F2EFA35BA57CC9366F75155DDA4ED6C
    WB1 =BEE62F56D79A365742577AD5CA77F704CCC7B35AF67A29CBA3CBF94B726B7E19

===== v7_XZL vs v7_WB2 =====
files compared: 157 ; differing: 1
  DIFF: debug_top.v
    XZL =81C1402E39E460E4BF81723534176D2D0F2EFA35BA57CC9366F75155DDA4ED6C
    WB2 =7DF121A4700F04DECECB8CCB8B7D8B027C294399C63000E941C26F6F5793F24F

===== v7_XZL vs v7_WB3 =====
files compared: 157 ; differing: 1
  DIFF: debug_top.v
    XZL =81C1402E39E460E4BF81723534176D2D0F2EFA35BA57CC9366F75155DDA4ED6C
    WB3 =080C5DA49806637317B7B349AB495698BA4F95858444E9A06E842F093E2CD2B3
```

**行级 diff**（三版均为 7495 行 vs 7495 行，只有 L102、L104 两行不同）：

```text
===== v7_XZL -> v7_WB1 (total differing lines = 2) =====
  L102:
    -         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
    +         .PROBE_OUT0_INIT_VAL    ( 'h140 ),
  L104:
    -         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
    +         .PROBE_OUT2_INIT_VAL    ( 'h280 ),

===== v7_XZL -> v7_WB2 (total differing lines = 2) =====
  L102:
    -         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
    +         .PROBE_OUT0_INIT_VAL    ( 'h180 ),
  L104:
    -         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
    +         .PROBE_OUT2_INIT_VAL    ( 'h340 ),

===== v7_XZL -> v7_WB3 (total differing lines = 2) =====
  L102:
    -         .PROBE_OUT0_INIT_VAL    ( 'h118 ),
    +         .PROBE_OUT0_INIT_VAL    ( 'h1C0 ),
  L104:
    -         .PROBE_OUT2_INIT_VAL    ( 'h15e ),
    +         .PROBE_OUT2_INIT_VAL    ( 'h400 ),
```

### 15.4 构建结果（5 步全部退出码 0；三版并行编译）

构建命令：`v7_flow.ps1 -Work ...\v7_WBn -Tag WBn`

| 项 | v7_WB1 | v7_WB2 | v7_WB3 |
|---|---|---|---|
| 位流 | `v7_WB1\out\v7_WB1.bit` | `v7_WB2\out\v7_WB2.bit` | `v7_WB3\out\v7_WB3.bit` |
| 大小 | **2,572,080 B** | **2,575,092 B** | **2,576,031 B** |
| SHA256 | `A8C887327428C67223A82A3D60EEF102261B947F7320975CF44C41DE51AE4578` | `4DDD672AFDAEFCAAABF6BDC474E85E55F5DC38E0564996B2576D58FDBB6C1702` | `080EDFE778FF1D45064299C5162C9243A05CB6042A057B95752A33EC2CFD6A77` |
| `'No valid pin(s) found for clock'` | **0** ✅ | **0** ✅ | **0** ✅ |
| `'No clocks matched'` | 87 | 87 | 87 |
| hold 违例条数 | 5 | 5 | **4**（core_clk 本版通过） |

基线参照 `v7_XZL`：2,580,369 B，SHA256 `1DD0EB7E5AB663FB8F780F2B8E40B9BDE307B9CD26A7E75D66789F50BE93D4AA`，`No valid pin(s)=0`，`No clocks matched=87`，hold 5 条。

**hold 违例明细（`build.log` 原文摘录）**

```text
--- v7_WB1 (5) ---
tx_cal_clk_90edge : -0.489 ns
sdram_clk         : -0.406 ns
rx_cal_clk        : -0.060 ns
tx_cal_clk        : -0.153 ns
core_clk          : -0.018 ns

--- v7_WB2 (5) ---
tx_cal_clk_90edge : -0.391 ns
sdram_clk         : -0.695 ns
rx_cal_clk        : -0.725 ns
tx_cal_clk        : -0.174 ns
core_clk          : -0.595 ns

--- v7_WB3 (4) ---
tx_cal_clk_90edge : -0.429 ns
sdram_clk         : -0.369 ns
rx_cal_clk        : -0.175 ns
tx_cal_clk        : -0.358 ns
（core_clk 无 hold 告警）

--- v7_XZL 基线 (5) ---
tx_cal_clk_90edge : -0.431 ns
sdram_clk         : -0.565 ns
rx_cal_clk        : -0.462 ns
tx_cal_clk        : -0.349 ns
core_clk          : -0.540 ns
```

说明：hold 违例数量与基线同量级（WB3 少 1 条），属该设计既有的时序状态，与本次白平衡改值无因果关系；三版 SDC 关键验收项 `No valid pin(s) found for clock` 均为 **0**。

### 15.5 烧录：仅 `v7_WB2`

- 命令：`flash_vendor.ps1 -Bit ...\v7_WB2\out\v7_WB2.bit -Sha256 4DDD67...C1702`（sha256 实时计算并做前置一致性校验，PASS）
- 前置检查：文件类型 / sha256 / FTDI 驱动 2.12.36.4 全部通过；**只做 JTAG 临时加载，不写 SPI 闪存**
- 烧录日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_225909.log`
- 控制台记录：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\WB2_console_20261019_225902.txt`
- 关键两行原文（日志 L6 / L7）：

```text
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

- 结果：**烧录成功**（`Device ID read from JTAG : PASS`、`finished with JTAG programming : PASS`，exit code 0）

### 15.6 本轮烧录边界（可复核）

- **只烧 `v7_WB2` 一次，成功。**
- **WB1/WB3 未烧，等 Kevin 看完 WB2 后按偏色方向决定。**
- 未烧：`v7_WB1`、`v7_WB3`、`v7_XZA`、`v7_Y`、`v7_Ya`、`v7_L`、`v7_B2`、`v7_C2`、`v7_P*`，以及底本 `v7_XZ`/`v7_XV`/`v7_XZL`/`v7_work2`。
- 未推送 GitHub。
- 本轮新增目录仅 `v7_WB1`、`v7_WB2`、`v7_WB3`；**已有目录（v7_work2、v7_XV、v7_XZ、v7_XZL、v7_XZA、v7_Y、v7_Ya、v7_X、v7_A2、v7_L、v7_B2、v7_C2、v7_P*）未被修改。**

### 15.7 判断边界

**画面由 Kevin 判断，本文件不下结论。** 白平衡是否收敛、偏黄绿是否改善，需 Kevin 上板目视确认；本文件只记录可复核的客观事实。


---

## §16 更正与补充（2026-10-19 23:12 追加；**§1–§15 原文一字未改**）

### 16.1 更正「全红」的性质：与烧录是否中断**无关**

**原文逐字照录：`vendor_flash_logs\vendor_flash_20261019_225909.log`（WB2 烧录，22:59:09 起）**

```
Using board profile: 'Generic Board Profile Using FT4232H' for pinout connection
Connecting to JTAG_TAP: efx_ti
jtag programming started!
JTAG Programming on hiftdi://0x0403:0x6011/1
Programming 'D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WB2\out\v7_WB2.bit' via JTAG at freq 6.0 MHz
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
file   : D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WB2\out\v7_WB2.bit
size   : 2575092
mtime  : 10/19/2026 22:58:09
sha256 : 4DDD672AFDAEFCAAABF6BDC474E85E55F5DC38E0564996B2576D58FDBB6C1702
mode   : jtag (JTAG 临时加载，未写 SPI 闪存)
board  : Generic Board Profile Using FT4232H
expect : Device ID read from JTAG: 0x10660A79 + finished with JTAG programming
nativeExit: 0
ts     : 20261019_225909
```

- 该日志里**同时出现** `Device ID read from JTAG: 0x10660A79` 与 `... finished with JTAG programming` ⇒ **WB2 实际烧录成功**，不是中断、也不是失败。
- 同批可复核：`vendor_flash_20261019_230042.log`（v7_XZL）与 `vendor_flash_20261019_230238.log`（v7_WB1）也都含这两行（判据回显 1 次 + 实际输出 1 次，各 2 次），nativeExit 均为 0 ⇒ **WB1 也烧录成功。**
- **结论**：WB2（R = `'h180` = 384 = ×1.5 ／ B = `'h340` = 832 = ×3.25）与 WB1（R = `'h140` = 320 = ×1.25 ／ B = `'h280` = 640 = ×2.5）的「偏红／全红」，是 `rtl\debayer\debayer_top_2to1.v` 里 **`gain_b` 接在红像素上（`.gain_b (r_gain)` ／ `.gain_r (b_gain)` 交换）导致的接线错配**，**与烧录是否中断无关**。
- **明确声明（作废）**：之前「JTAG 烧录失败会让 FPGA 掉配置、屏幕显示异常颜色」这条推断 **作废，删除**。本文件后续不得再以此为依据。

### 16.2 一个独立事实：FTDI 偶发 `DEVICE_NOT_OPENED` ／ `No such device`（疑似串口监听程序占用）

- 可查日志中**唯一一次**出现在 `vendor_flash_20261019_224252.log`（v7_XZL）：

```
Connecting to JTAG_TAP: efx_ti
jtag programming started!
JTAG Programming on hiftdi://0x0403:0x6011/1
Programming 'D:\FPGA\易灵思\工作区\07_官方demo工程\v7_XZL\out\v7_XZL.bit' via JTAG at freq 6.0 MHz
Traceback (most recent call last):
  File "D:\Efinity/2026.1/pgm/bin/efx_pgm/hiftdi/usbtools.py", line 263, in get_device
    dev = devs[devdesc.index or 0]
IndexError: list index out of range
  ...
  File "D:\Efinity/2026.1/pgm/bin/efx_pgm/hiftdi/usbtools.py", line 265, in get_device
    raise IOError("No such device") from exc
OSError: No such device
nativeExit: 0
```

- 特征：**Python 异常了但 native exit code 仍是 0** ⇒ 所以本仓库的烧录判据只认两行文本（`Device ID read from JTAG: 0x10660A79` + `finished with JTAG programming`），不认退出码。
- 这一次发生在 **configure 阶段（早于 Device ID 读取）**，该次确实没编程上；**紧接着 22:43:28 同一位流重试即成功**（`vendor_flash_20261019_224328.log`，两行判据齐全）⇒ 属**偶发**，不是位流问题。
- 指挥官另报告过：该提示也会**出现在编程完成之后**（日志已打印 `finished with JTAG programming` 之后才报 `DEVICE_NOT_OPENED`）。**这类收尾报错不影响实际编程结果。**
- 疑似原因：串口监听／调试程序占着 FT232H 的 JTAG 通道。**处理方式：只提示、不自动杀进程**（见 `tools\flash_vendor.ps1` 新增的第 ④ 段预检，见 §17.6）。

### 16.3 厂商 timing 报告：**找不到，无法比较 hold 违例**

- 厂商原目录 `Ti60f225_sc431hai2hdmi_v7\Ti60f225_sc431hai2hdmi_v7` 下**没有任何** timing／route／map／place 报告（递归检索 `timing|route|map|place|hold|setup|*.rpt` ⇒ **0 命中**）。
- 该目录 `outflow\` 里**只有两个文件**：`ti60f225_oob.bit`（2,654,763 B）与 `ti60f225_oob.hex`（2,654,823 B）。
- ⇒ **没有厂商 timing 报告，无法与我们的 hold 违例做比较。**（厂商 `.bit` 也不带时序信息。）

---

## §17 WBF / WBG 构建与烧录记录（2026-10-19 23:08–23:18 追加；**§1–§16 原文一字未改**）

### 17.1 `v7_WBF`：构造与 diff 证明（改自 `v7_XZL`，只改 2 个文件）

| 文件 | 行 | 内容 |
|---|---|---|
| `rtl\debayer\debayer_top_2to1.v` | 51 / 53 | `.gain_b (r_gain)` ／ `.gain_r (b_gain)`（**已交换**） |
| `debug_top.v` | 102 / 104 | `.PROBE_OUT0_INIT_VAL ( 'h140 )` ／ `.PROBE_OUT2_INIT_VAL ( 'h280 )` |

改后原文（`v7_WBF` 实读）：

```verilog
// rtl\debayer\debayer_top_2to1.v:51-53
	.gain_b (r_gain		),
	.gain_g (g_gain		),
	.gain_r (b_gain		),

// debug_top.v:102-104
        .PROBE_OUT0_INIT_VAL    ( 'h140 ),
        .PROBE_OUT1_INIT_VAL    ( 'hff ),
        .PROBE_OUT2_INIT_VAL    ( 'h280 ),
```

**逐文件 SHA256 比对（`v7_XZL` vs `v7_WBF`，排除 out/work_syn/work_pnr/outflow 构建产物；共 157 个文件）**

```
compared=157  diffCount=2
DIFF debug_top.v
DIFF rtl\debayer\debayer_top_2to1.v
```

⇒ **恰好只有这 2 个文件不同**，与上表一致。

### 17.2 `v7_WBF`：构建验收（`v7_flow.ps1 -Work ...\v7_WBF -Tag WBF`，5 步退出码全 0）

```
[1] efx_map 退出码=0
[2] efx_pnr#1 退出码=0
[3] efx_run -f interface   →  interface :	PASS
[4] filter_interface       →  wrote 472 lines
[5] efx_pnr#2 --sync_file 退出码=0
  验收: 'No valid pin(s) found for clock' = 0  （必须 0）   ✅
        'No clocks matched'              = 87
```

- 位流：`v7_WBF\out\v7_WBF.bit`，**2,568,357 B**，SHA256 `091EA20DAD060A81C49E819D2C78A256EBDE12CDD3A29C55CA7ED603191C9988`
- hold 违例（5 个时钟域，均为 WARNING 级）：

| 时钟域 | hold slack |
|---|---|
| tx_cal_clk_90edge | -0.549 ns |
| sdram_clk | -0.548 ns |
| rx_cal_clk | -0.660 ns |
| tx_cal_clk | -0.230 ns |
| core_clk | -0.339 ns |

### 17.3 `v7_WBF`：**已烧录**（2026-10-19 23:15:33，`-m jtag`）

- 命令：`flash_vendor.ps1 -Bit ...\v7_WBF\out\v7_WBF.bit -Sha256 091EA20D...C9988`（sha256 实时计算）
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_231533.log`
- **关键两行原文**：

```
Device ID read from JTAG: 0x10660A79
... finished with JTAG programming
```

- 判据：`Device ID read from JTAG : PASS` + `finished with JTAG programming : PASS`，nativeExit 0 ⇒ **烧录成功**。
- 前置检查 ④（本轮新增）实测输出：`OK   未发现明显占用 FTDI 的进程`。

### 17.4 `v7_WBG`：构造与 diff 证明（改自 `v7_WBF`，只改 `debug_top.v` 2 行）

- 构造：`robocopy ...\v7_WBF ...\v7_WBG /E /XD out work_syn work_pnr outflow`（**不复制构建产物**）⇒ 157 个源文件。
- **改前**（`v7_WBG\debug_top.v` 第 98–110 行实读；要改的是 L102/L104）：

```verilog
  98:         .PROBE_OUT0_WIDTH       ( 16 ),
  99:         .PROBE_OUT1_WIDTH       ( 16 ),
 100:         .PROBE_OUT2_WIDTH       ( 16 ),
 101:         .PROBE_OUT3_WIDTH       ( 1 ),
 102:         .PROBE_OUT0_INIT_VAL    ( 'h140 ),
 103:         .PROBE_OUT1_INIT_VAL    ( 'hff ),
 104:         .PROBE_OUT2_INIT_VAL    ( 'h280 ),
 105:         .PROBE_OUT3_INIT_VAL    ( 'h0 )
 106:     ) vio0 (
```

- 精确替换（每处替换前匹配数 = **1**）：`'h140` → `'h1B0`（R：320 → 432，×1.25 → ×1.69）；`'h280` → `'h330`（B：640 → 816，×2.50 → ×3.19）。
- **改后**：

```verilog
 102:         .PROBE_OUT0_INIT_VAL    ( 'h1B0 ),
 104:         .PROBE_OUT2_INIT_VAL    ( 'h330 ),
```

**逐文件 SHA256 比对（`v7_WBF` vs `v7_WBG`，同口径 157 文件）**

```
compared=157  diffCount=1
DIFF debug_top.v
```

**行级 diff**

```diff
-        .PROBE_OUT0_INIT_VAL    ( 'h140 ),
-        .PROBE_OUT2_INIT_VAL    ( 'h280 ),
+        .PROBE_OUT0_INIT_VAL    ( 'h1B0 ),
+        .PROBE_OUT2_INIT_VAL    ( 'h330 ),
```

⇒ **只有 1 个文件不同、行级只有 2 行。**

### 17.5 `v7_WBG`：构建验收（**只编不烧**）

```
[1] efx_map 退出码=0
[2] efx_pnr#1 退出码=0
[3] efx_run -f interface   →  interface :	PASS
[4] filter_interface       →  wrote 472 lines
[5] efx_pnr#2 --sync_file 退出码=0
  验收: 'No valid pin(s) found for clock' = 0  （必须 0）   ✅
        'No clocks matched'              = 87
```

- 位流：`v7_WBG\out\v7_WBG.bit`，**2,571,468 B**，SHA256 `CA514F6A56DBA30A9AF497944A0C2F1C470C60579BC2BB516CE06D511BF8142C`
- hold 违例（4 个时钟域）：

| 时钟域 | hold slack |
|---|---|
| tx_cal_clk_90edge | -0.454 ns |
| sdram_clk | -0.321 ns |
| rx_cal_clk | -0.174 ns |
| tx_cal_clk | -0.227 ns |

### 17.6 `tools\flash_vendor.ps1`：新增第 ④ 段「FTDI/JTAG 占用预检」（**只提示，不自动杀进程**）

```powershell
# ---------- ④ FTDI/JTAG 占用预检（只检查 + 提示，绝不自动杀进程）----------
# 背景：偶发 DEVICE_NOT_OPENED / No such device，疑似串口监听/调试器占着 FT232H 的 JTAG 通道。
# 该异常若出现在编程完成之后（日志已显示 finished with JTAG programming），不影响编程结果。
# 本段只提示，不计入 $fail，不阻断烧录，绝不 Stop-Process。
Write-Host ""
Write-Host "--- ④ FTDI/JTAG 占用预检（只提示，不自动杀进程）---"
$holders = Get-Process -ErrorAction SilentlyContinue |
           Where-Object { $_.ProcessName -match 'openocd|jtag|efinity_dbg|serial_daemon|efx_dbg' }
if ($holders) {
    Write-Host "  提示：以下进程可能占用 FTDI/JTAG，建议先关闭后再烧录（脚本不会自动杀）：" -ForegroundColor Yellow
    $holders | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-String | Write-Host
} else {
    Write-Host "  OK   未发现明显占用 FTDI 的进程" -ForegroundColor Green
}
```

- 语法检查：`[System.Management.Automation.Language.Parser]::ParseFile` ⇒ **0 errors**（脚本 171 行）。
- 安全检查逐项仍在（可复核）：
  1. 拒绝 `.hex`（`.hex` 是写 SPI 闪存的格式，脚本只做 JTAG 临时加载）
  2. 只接受 `.bit`
  3. sha256 白名单（与 `-Sha256` 不一致即拒绝）
  4. FTDI 驱动版本必须统一（防 0x000000FC 蓝屏）
  5. 双判据：`Device ID read from JTAG: 0x10660A79` **且** `finished with JTAG programming` 同时出现
- 全文**无** `Stop-Process` 调用（仅注释里写了「绝不 Stop-Process」）。
- 本段**不计入** `$fail`，不改判据、不改退出码逻辑。

### 17.7 本轮烧录边界（可复核）

- **本轮只烧了 `v7_WBF` 一个**（23:15:33，成功）。
- **未烧**：`v7_WBG`（只编）、`v7_WB3`、`v7_XZA`、`v7_Y`、`v7_Ya`、`v7_L`、`v7_B2`、`v7_C2`、`v7_P*`。
- `v7_WB1` 的 23:02:38 那次烧录属上一轮（见 16.1 的日志证据），**本轮未再烧 WB1**。
- **未推送 GitHub。**
- 未改动 `v7_XZL`／`v7_WBF` 的源文件（本轮对二者只读）；本轮新增目录仅 `v7_WBG`；本轮改动文件仅 `tools\flash_vendor.ps1`（新增第 ④ 段预检）。

---

## §20 WBH4 ：构建与烧录记录（2026-10-19 23:46–23:53 追加；**§1–§17 原文一字未改**）

### 20.1 初值原文（`v7_WBH4\debug_top.v` 第 98–110 行，只读核对，未改动）

```verilog
        .PROBE_OUT0_WIDTH       ( 16 ),
        .PROBE_OUT1_WIDTH       ( 16 ),
        .PROBE_OUT2_WIDTH       ( 16 ),
        .PROBE_OUT3_WIDTH       ( 1 ),
        .PROBE_OUT0_INIT_VAL    ( 'h158 ),
        .PROBE_OUT1_INIT_VAL    ( 'h130 ),
        .PROBE_OUT2_INIT_VAL    ( 'h1D0 ),
        .PROBE_OUT3_INIT_VAL    ( 'h0 )
    ) vio0 (
        .bscan_CAPTURE          ( bscan_CAPTURE ),
        .bscan_DRCK             ( bscan_DRCK ),
        .bscan_RESET            ( bscan_RESET ),
        .bscan_RUNTEST          ( bscan_RUNTEST ),
```

- 结论：初值 = `'h158` / `'h130` / `'h1D0` / `'h0`，与要求一致。
- 源文件**未改**：`debug_top.v` mtime 2026-10-19 23:29:35（本轮只读）；本轮对 `rtl\` 无任何写入。

### 20.2 构建（`v7_flow.ps1 -Work ...\v7_WBH4 -Tag WBH4`，5 步退出码全 0）

- 构建前清理：`out` / `work_syn` / `work_pnr` 已清空重建（`outflow` 构建时由第 3 步新建，清理时不存在）。
- 时间：23:46:02 起，23:52:10 位流落盘；构建日志 `v7_WBH4\out\build.log`。

### 20.3 位流

| 项 | 值 |
|---|---|
| 路径 | `D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WBH4\out\v7_WBH4.bit` |
| 大小 | **2,566,320 B** (2,566,320 bytes) |
| mtime | 2026-10-19 23:52:10 |
| SHA256 | `5759CE76330663DBC99650E716C2FB1D8FAB6ABE50E366B053046D3D70EBAC09` |

### 20.4 SDC / 时序验收（`out\pnr2.log`）

- SDC：`ti60f225_oob.sdc`（mtime 2026-08-13 16:50:12，SHA256 `7DEA948873E6BBAA2FDA92E4E26C67F5CF0FD435A26D3B53BFAA46659B3325FF`），与历次 WB 系列同一份，本轮未改。
- `No valid pin(s) found for clock` = **0** ✅（必须为 0）
- `No clocks matched` = 87（与既有基线一致，非本项判据）
- hold (min) 违例（WARNING，共 5 条）：
  - tx_cal_clk_90edge ← tx_cal_clk_90edge：slack **-0.399 ns**
  - sdram_clk ← sdram_clk：slack **-0.313 ns**
  - rx_cal_clk ← rx_cal_clk：slack **-0.776 ns**
  - tx_cal_clk ← tx_cal_clk：slack **-0.126 ns**
  - core_clk ← core_clk：slack **-0.535 ns**

### 20.5 烧录（`-m jtag`，只下 .bit，不写 SPI 闪存）

- 命令：`flash_vendor.ps1 -Bit ...\v7_WBH4\out\v7_WBH4.bit -Sha256 5759CE...AC09`（sha 实时重算，与文件一致）
- 时间：2026-10-19 23:53:32–23:53:41
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261019_235332.log`（803 B）
- **双判据原文**：
  - `Device ID read from JTAG: 0x10660A79`
  - `... finished with JTAG programming`
- 结果：**PASS / 烧录成功**（脚本退出码 0；FTDI 驱动 2.12.36.4 统一；无进程占用 FTDI）

### 20.6 本轮边界（可复核）

- 只构建 + 烧录 **WBH4** 一个变体；未烧 WBH1/WBH2/WBH3/WBG/WBF/XZA 等任何其他位流。
- **未研究、未触碰 Debugger**（`efx_dbg` 未启动、未交互）。
- **未改任何 rtl / debug_top.v 源文件**，只清理构建产物目录。
- **未推送 GitHub**。

---

### 20.7 补充：RTL 三项核对原文（2026-10-19 23:5x，**只读核对，未改任何文件**）

> §20.1 只贴了 `debug_top.v` 的初值；任务书要求的另三处 RTL 核对原文补记于此。
> 三项**全部通过**。

**(1) `v7_WBH4\rtl\debayer\debayer_top_2to1.v:51-53` —— 增益接线（已交换状态）**

```verilog
51: .gain_b (r_gain		),
52: .gain_g (g_gain		),
53: .gain_r (b_gain		),
```

即 `gain_b ← r_gain`、`gain_r ← b_gain` 两者互换，`gain_g ← g_gain` 直连。**与要求一致。**

**(2) `v7_WBH4\rtl\debayer\rgb_gain_v1.v:67-78` —— 第 68 行分支**

```verilog
67: always @(*) begin
68: 	if(!r_line_cnt) begin
69: 		//奇数行 high=Gr(gain_g)  low=R(gain_r)
70: 		mul_high = pix_high * gain_g;
71: 		mul_low  = pix_low  * gain_r;
72: 	end
73: 	else begin
74: 		//偶数行 high=B(gain_b)  low=Gb(gain_g)
75: 		mul_high = pix_high * gain_b;
76: 		mul_low  = pix_low  * gain_g;
77: 	end
78: end
```

`:68` 仍为 `if(!r_line_cnt) begin`。**与要求一致。**

**(3) `v7_WBH4\rtl\debayer\raw_to_rgb.v:392-398` —— 第 396/398 行（已交换状态）**

```verilog
392: 				r_r_00_00_1P[P_DEPTH-1:0]	<= w_r_00_00_l0>>2;
393: 				r_g_00_00_1P[P_DEPTH-1:0]	<= w_g_00_00_l0>>2;
394: 				r_b_00_00_1P[P_DEPTH-1:0]	<= r_bayer_00_00_1P_0; 
396: 				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h0>>1;
397: 				r_g_00_00_1P[PW-1:P_DEPTH]	<= r_bayer_00_00_1P_1;				
398: 				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_r_00_00_h0>>1;
```

`:396` `r_r ← w_b_00_00_h0`、`:398` `r_b ← w_r_00_00_h0`，高半像素 R/B **互换**。**与要求一致。**

> 另：`v7_WBH4\debug.json` 的 `vio0` uuid = `d2d3643a7f1e49a3a7f48b242e104fdd`，与 `debug_top.v:97`
> 的 `128'hd2d3643a7f1e49a3a7f48b242e104fdd` **一致**。该 json 的探针 `init` 仍是旧值
> （`0x118/0xff/0x15e`），但**硬件上电初值以 `debug_top.v` 的 `PROBE_OUTx_INIT_VAL` 为准**
> （`0x158/0x130/0x1D0`），差异不影响功能。

### 20.8 Debugger 连接诊断（**更正 §20.6 的"未研究 Debugger"**）

§20.6 写的是"未研究、未触碰 Debugger"，那是 WBH4 构建线自身的边界。**本轮另有一条并行的
Debugger 排查线已完成**（仅读源码 + 启动 shell 探查，未改任何 Efinity 文件），结论如下：

> **一句话：能连。用户找错了页面 —— `Configure` 按钮在 `Run` 页且默认 disabled，必须先去
> `Program` 页点 `USB Target` 右侧的刷新图标（redo.svg，无文字）才会启用；
> `No Board Profile Selected` 是无害日志；Import JCF 黑窗无解但不阻塞。**

完整代码级方案见 **`D:\FPGA\mmt\out\evidence\debugger_connect_solution.md`**。要点（均带行号）：

| 问题 | 结论 | 源码依据 |
|---|---|---|
| `USB Target` 在哪 | **Program 页** | `Ui_DebuggerMainWindow.py:93,97`（parent = `groupBox_program`） |
| `Configure` 在哪 | **Run 页** `Configuration` 分组框 | `Ui_DebuggerMainWindow.py:212,257,268`；标题 `:372` |
| 为何点不动 | 初始化即 disabled | `gui.py:3150` `pb_config_jtag.setEnabled(False)` |
| 谁能启用它 | 只有 `on_debug_refresh`，且需 USB 设备 + profile 双条件 | `gui.py:3961-3977` |
| 官方叫法不一致 | 消息里叫 "Connect Debugger"，按钮文字是 "Configure" | `gui.py:3057`（`MSG_I002`）vs `Ui_DebuggerMainWindow.py:380` |
| `No Board Profile Selected` | **无害**（未匹配到可选板卡 XML） | 唯一来源 `pgm\bin\efx_pgm\main_window.py:1611-1615`；debugger 代码零出现 |
| Import JCF 黑窗 | Qt 渲染缺陷，无解但不阻塞 | `get_current_debug_target()`：`"…or check JTAG connection and then refresh"` |
| 无 GUI 替代 | **有**：`python -m efx_dbg.shell`（`cmd.Cmd` REPL，实测可启动） | `shell.py:93,473-475`；命令 `:134/213/259/284/328` |
| 纯脚本写 VIO | **可以**（三段式） | `jtag.py:2330/2334/2338`；`shell.py:431-439` |
| **profile 混用陷阱** | **WBH1 的 debug.json 不能用于 WBH4**（UUID 不同） | 实测；失配抛 `EfxDbgMisMatchCoreUUIDError`（`gui.py:4148`） |

补记一个**独立故障点**（与 GUI 渲染无关）：`v7_WBH1\debug.json` 与 `v7_WBH4\debug.json` 的
Debug Core UUID 不同——

| 核心 | WBH1 | WBH4 |
|---|---|---|
| `vio0` | `af5ad2e95cab41469fae6c93c1cfc5cd` | `d2d3643a7f1e49a3a7f48b242e104fdd` |
| `la0`  | `cf5d5db3e5c44a318184993664e4fb8a` | `40fc40c15a7b4e5392113defb86d2a4c` |

⇒ 板上现在跑的是 WBH4，Debugger **必须**改导 `v7_WBH4\debug.json`；继续用 WBH1 的 profile
必然报 `Debug Core UUID mismatch detected on vio0` 并断开。

### 20.9 重复烧录事实（据实记录）

同一份 `v7_WBH4.bit`（sha256 `5759CE76…EBAC09`）在 23:53 被**烧录两次**，两次双判据均 PASS：

| 日志 | 时间 | 结果 |
|---|---|---|
| `vendor_flash_logs\vendor_flash_20261019_235309.log` | 23:53:09 | PASS（`Device ID read from JTAG: 0x10660A79` + `... finished with JTAG programming`） |
| `vendor_flash_logs\vendor_flash_20261019_235332.log` | 23:53:32 | PASS（同两行） |

原因：两条执行线并行处理同一任务，各自完成了一次烧录。**同一位流、同一 sha256，重复烧录无副作用**，
板上最终状态 = WBH4。此处如实记录，避免后续按日志计数误判为"烧了 2 个不同变体"。

### 20.10 边界补充

- 未修改任何 `v7_*` 工程的 rtl / `debug_top.v`（本节 20.7 全部为只读核对）。
- 只烧 `v7_WBH4` 的位流（共 2 次，同一文件）。
- **未推送 GitHub。**
- Debugger 线只读源码 + 启动 `efx_dbg.shell` 探查命令表；未改 `D:\Efinity\2026.1` 下任何文件。

---

## §21 WBH3 ：构建与烧录记录（2026-10-19 23:56–2026-10-20 00:02 追加；**§1–§20 原文一字未改**）

### 21.0 本轮动机：Kevin 对 WBH4 的反馈

> **Kevin 原话：「太绿了」**

反推链路（增益方向已由两次实机反馈夹逼）：

| 变体 | G 增益 | 实测观感 | 判定 |
|---|---|---|---|
| WBH1 | G = 0.996× | 偏弱（绿不足偏品红） | **偏低** |
| WBH4 | G = 1.1875× | **「太绿了」** | **偏高** |
| WBH3（本轮） | G ≈ **1.09×** | 待 Kevin 目视 | **目标值** |

⇒ 正确区间被夹在 0.996× 与 1.1875× 之间，**G ≈ 1.09×** 为插值目标（相对 WBH4 下调、相对 WBH1 上调）。

### 21.1 四项只读核对原文（**只读核对，源文件未改一字**）

**① `v7_WBH3\debug_top.v` 第 102–105 行**

```verilog
        .PROBE_OUT0_INIT_VAL    ( 'h158 ),
        .PROBE_OUT1_INIT_VAL    ( 'h118 ),
        .PROBE_OUT2_INIT_VAL    ( 'h1D0 ),
        .PROBE_OUT3_INIT_VAL    ( 'h0 )
```

⇒ `'h158` / `'h118` / `'h1D0` / `'h0`，**与要求一致**（PROBE_OUT1 为 `'h118`，WBH4 为 `'h130`，此为两变体唯一初值差异）。

**② `v7_WBH3\rtl\debayer\debayer_top_2to1.v` 第 51–53 行**

```verilog
	.gain_b (r_gain		),
	.gain_g (g_gain		),
	.gain_r (b_gain		),
```

⇒ **B/R 已交换**（`gain_b←r_gain`、`gain_r←b_gain`），`gain_g←g_gain` 保持直通，**与要求一致**。

**③ `v7_WBH3\rtl\debayer\rgb_gain_v1.v:68`**

```verilog
	if(!r_line_cnt) begin
```

⇒ `if(!r_line_cnt)`，**与要求一致**（偶奇行判定极性）。

**④ `v7_WBH3\rtl\debayer\raw_to_rgb.v` 第 396 / 398 行**

```verilog
				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_r_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
```

⇒ 高半像素 R/B **互换**（`r_r←w_b_00_00_h0>>1`、`r_b←w_r_00_00_h0>>1`），**与要求一致**。

**四项全部相符 → 放行构建。**

### 21.2 构建（`v7_flow.ps1 -Work ...\v7_WBH3 -Tag WBH3`，5 步退出码全 0）

- 构建前清理：`out` / `work_syn` / `work_pnr` / `outflow` 四个目录构建前**均不存在**（已确认，无需删除）。
- 时间：**23:56:27 起 → 00:01:01 位流落盘**（约 4 分 34 秒），日志 `v7_WBH3\out\build.log`。
- 各步：`[1] efx_map=0`、`[2] efx_pnr#1=0`、`[3] efx_run -f interface PASS`、`[4] filter_interface 472 行`、`[5] efx_pnr#2 --sync_file=0` → `===== [WBH3] 完成 =====`

### 21.3 位流

| 项 | 值 |
|---|---|
| 路径 | `D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WBH3\out\v7_WBH3.bit` |
| 大小 | **2,566,323 B** |
| mtime | 2026-10-20 00:01:01 |
| SHA256 | `A562A9FB86E5A3E81F9A73FD83B8FD0AFE74343B1348F830D4581F49CB062936` |

（与 WBH4 的 2,566,320 B 相差 3 B，属增益常数改变引起的布局微差，正常。）

### 21.4 SDC / 时序验收（`out\build.log` + `out\pnr2.log`）

- SDC：`ti60f225_oob.sdc`，41630 B，mtime 2026-08-13 16:50:12，
  SHA256 `7DEA948873E6BBAA2FDA92E4E26C67F5CF0FD435A26D3B53BFAA46659B3325FF`
  —— **与 §20.4 记录的 WBH4 同一份，字节级一致，本轮未改。**
- **`No valid pin(s) found for clock` = 0** ✅（必须为 0；`map.log` 全文复算亦为 0）
- `No clocks matched` = 87（与既有基线一致，非本项判据）
- hold (min) WARNING 共 5 条，与 WBH4 **数值完全一致**（同一布局骨架）：

| 时钟域对 | slack |
|---|---|
| rx_cal_clk ← rx_cal_clk | **-0.776 ns**（最差） |
| core_clk ← core_clk | -0.535 ns |
| tx_cal_clk_90edge ← tx_cal_clk_90edge | -0.399 ns |
| sdram_clk ← sdram_clk | -0.313 ns |
| tx_cal_clk ← tx_cal_clk | -0.126 ns |

- `ti60f225_oob.hold_fixing.rpt`：仅有表头，**无 hold fix 需求行**。

### 21.5 烧录（`-m jtag`，只下 .bit，不写 SPI 闪存）→ **成功**

- 命令：`flash_vendor.ps1 -Bit ...\v7_WBH3\out\v7_WBH3.bit -Sha256 A562A9FB...2936`（sha256 前置实时重算，一致）
- 前置检查：文件类型 OK / sha256 一致 / FTDI 驱动 2.12.36.4 统一 / 无进程占用 FTDI → 全通过，退出码 0
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261020_000206.log`
- **双判据原文**：
  - `Device ID read from JTAG: 0x10660A79`
  - `... finished with JTAG programming`
- 结果：**PASS / 烧录成功**（`nativeExit: 0`，`mode: jtag`）

### 21.6 重复烧录事实（据实记录）

同一份 `v7_WBH3.bit`（sha256 `A562A9FB…2936`）在 **00:01:54** 与 **00:02:06** 各出现一份 PASS 日志：

| 日志 | 时间 | 结果 |
|---|---|---|
| `vendor_flash_logs\vendor_flash_20261020_000154.log` | 00:01:54 | PASS（同两行） |
| `vendor_flash_logs\vendor_flash_20261020_000206.log` | 00:02:06 | PASS（同两行） |

原因同 §20.9：多条执行线并行处理同一任务，各完成一次烧录。**同一位流、同一 sha256，重复烧录无副作用**，
板上最终状态 = **WBH3**。

### 21.7 结论与边界

- 构建 + 烧录 **WBH3** 均完成，双判据 PASS，板上当前运行 **WBH3（G ≈ 1.09×）**。
- **画面由 Kevin 判断，本文件不下结论**——本文件只记录："WBH4 被判定太绿"，因此 WBH3 把 G 从 1.1875×
  降到 ≈1.09×，观感是否落到"不绿不品红"的合适区间，**由 Kevin 目视判定**，本节不作任何图像质量结论。
- **未改任何源文件**（21.1 四项全为只读核对），只清理/重建构建产物目录。
- 只烧 WBH3 一个变体（共 2 次，同一文件）。
- **未推送 GitHub。**
- **未研究、未触碰 Debugger。**

---

## §22 WBH6 ：构建与烧录记录（2026-10-20 00:07–00:14 追加；**§1–§21 原文一字未改**）

### 22.0 本轮动机：Kevin 对 WBH3 的逐项反馈

> **Kevin 反馈：WBH3 画面「白纸白 ✓、红表笔红 ✓、真实绿色 PCB 板显示成蓝色 ❌」**

反推（**只做现象→增益方向的推演，不做图像质量结论**）：

| 变体 | G 增益 | Kevin 观测 | 反推 |
|---|---|---|---|
| WBH4 | G = 1.1875× | **「太绿了」** | ⇒ **G 不是不足**，往 1.1875× 方向加过了头 |
| WBH3 | G ≈ 1.094× | 白纸✓ 红笔✓，但**绿 PCB 变蓝** | ⇒ 绿分量并非不足，**是 B 偏高**把中性绿压向蓝 |
| WBH6（本轮） | G ≈ 1.094×（不动） | 待 Kevin 目视 | **只降 B** |

⇒ 白平衡三轴中 R（`'h158`）、G（`'h118`）已由 Kevin 两次反馈判定为可用；矛盾集中在 B：
**WBH6 = WBH3 + B 下调**，即 `PROBE_OUT2_INIT_VAL` 由 `'h1D0`（**1.813×**）降到 `'h1A0`（**1.625×**）。

- `0x1D0 = 464`，`464 / 256 = 1.8125 ≈ 1.813×`
- `0x1A0 = 416`，`416 / 256 = 1.625×`
- 降幅 = **48/256 = 0.1875×**（相对 B 原来的 1.8125×，约 **-10.3%**）

### 22.1 构造：以 `v7_WBH3` 为底，只改 1 行

- 底本：`v7_WBH3`（**只读复制，未改动其中任何字节**）。
- 构建前 `v7_WBH6` **不存在**（已确认 `Test-Path = False`），故无需删除旧目录。
- 复制后删除 `out` / `work_syn` / `work_pnr` / `outflow` 四个产物目录（复制时存在，已逐个 Remove 成功）。

**改动原文（`v7_WBH6\debug_top.v` 第 104 行，改前 → 改后）**

```diff
-        .PROBE_OUT2_INIT_VAL    ( 'h1D0 ),
+        .PROBE_OUT2_INIT_VAL    ( 'h1A0 ),
```

- 精确替换：替换前该字符串全文命中数 = **1**，替换后回读确认命中 `'h1A0` = 1、`'h1D0` 全文残留 = **0**。
- **未动**：`PROBE_OUT0_INIT_VAL = 'h158`（R）、`PROBE_OUT1_INIT_VAL = 'h118`（G）、`PROBE_OUT3_INIT_VAL = 'h0`（gamma）。

**改后第 102–105 行原文（回读）**

```verilog
        .PROBE_OUT0_INIT_VAL    ( 'h158 ),
        .PROBE_OUT1_INIT_VAL    ( 'h118 ),
        .PROBE_OUT2_INIT_VAL    ( 'h1A0 ),
        .PROBE_OUT3_INIT_VAL    ( 'h0 )
```

### 22.2 diff 证明：SHA256 逐文件比对（排除 `out` / `work_syn` / `work_pnr` / `outflow`）

| 项 | WBH3 | WBH6 |
|---|---|---|
| 参与比对文件数 | **157** | **157** |
| 仅存在于本侧的文件 | 0 | 0 |
| **内容不同的文件** | — | **1（`\debug_top.v`）** |

**行级 diff（`Compare-Object`，`debug_top.v`，7495 行 vs 7495 行）**

```diff
<=         .PROBE_OUT2_INIT_VAL    ( 'h1D0 ),     # WBH3
=>         .PROBE_OUT2_INIT_VAL    ( 'h1A0 ),     # WBH6
```

⇒ 差异行 = 2 条（1 删 + 1 增）= **实际改动 1 行**，且**只落在 1 个文件**。

**`debug_top.v` 文件级 sha256**

| 版本 | SHA256 |
|---|---|
| WBH3（原） | `96FAA3D06AF5A6FC4BF8D43463FE0C09F0F33B2CE34D759BFFDA5DA9A4A0E126` |
| WBH6（新） | `3E4EB13092F1B233CBE2095899E9DAE80F8394D8E7C8B17F08CB846E1774D93A` |

### 22.3 三项只读核对原文（**只读核对，源文件未改一字**）

**① `v7_WBH6\rtl\debayer\debayer_top_2to1.v` 第 51–53 行**

```verilog
	.gain_b (r_gain		),
	.gain_g (g_gain		),
	.gain_r (b_gain		),
```

⇒ B/R 交换、G 直通，**与 WBH3 完全一致**（sha256 比对已证明该文件字节未动）。

**② `v7_WBH6\rtl\debayer\rgb_gain_v1.v:68`**

```verilog
	if(!r_line_cnt) begin
```

⇒ `if(!r_line_cnt)`，**与 WBH3 完全一致**。

**③ `v7_WBH6\rtl\debayer\raw_to_rgb.v` 第 396 / 398 行**

```verilog
				r_r_00_00_1P[PW-1:P_DEPTH]	<= w_b_00_00_h0>>1;//(r_bayer_00_01_0P_0 >> 1) + (r_bayer_00_00_1P_0 >> 1);
				r_b_00_00_1P[PW-1:P_DEPTH]	<= w_r_00_00_h0>>1;//(r_bayer_11_00_1P_1 >> 1) + (r_bayer_01_00_1P_1 >> 1);
```

⇒ 高半像素 R/B 互换，**与 WBH3 完全一致**。

**三项全部相符 → 放行构建。**

### 22.4 构建（`v7_flow.ps1 -Work ...\v7_WBH6 -Tag WBH6`，5 步退出码全 0）

- 时间：**00:08:26 起 → 00:13:45 位流落盘**（约 **5 分 19 秒**），日志 `v7_WBH6\out\build.log`。
- 各步：`[1] efx_map=0`、`[2] efx_pnr#1=0`、`[3] efx_run -f interface PASS`、`[4] filter_interface 472 行`、`[5] efx_pnr#2 --sync_file=0` → `===== [WBH6] 完成 =====`

### 22.5 位流

| 项 | 值 |
|---|---|
| 路径 | `D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WBH6\out\v7_WBH6.bit` |
| 大小 | **2,559,276 B** |
| mtime | 2026-10-20 00:13:45 |
| SHA256 | `480B931BA66D0318B41535365921DFC0770FD4D3E21A5827C5197794D1671331` |

（与 WBH3 的 2,566,323 B 相差 7,047 B，属增益常数改变引起的布局微差，正常。）

### 22.6 SDC / 时序验收

- SDC：`ti60f225_oob.sdc`，**41630 B**，mtime 2026-08-13 16:50:12，
  SHA256 `7DEA948873E6BBAA2FDA92E4E26C67F5CF0FD435A26D3B53BFAA46659B3325FF`
  —— **与 §21.4（WBH3）记录的同一份，字节级一致，本轮未改。**
- **`No valid pin(s) found for clock` = 0** ✅（流程脚本验收行原文：`验收: 'No valid pin(s) found for clock' = 0  （必须 0）`）
  - 复算：`map.log` = **0**、`pnr2.log` = **0**。
  - `pnr1.log` 中有 18 条 `No valid pin(s) found for clock`（SDC 第 10/13/14/16/17/18… 行，interface 前的首轮 PnR 未加载引脚约束所致）；**WBH3 基线同为 18 条，逐项计数完全一致（build=1/map=0/pnr1=18/pnr2=0）**，属既有基线行为，**非本轮回归**。
- `No clocks matched` = 87（与既有基线一致，非本项判据）
- hold (min) WARNING 共 **5** 条（与 WBH3 同为同样 5 个时钟域，数值因布局微差略有不同）：

| 时钟域对 | slack（WBH6） | 对比 WBH3（§21.4） |
|---|---|---|
| rx_cal_clk ← rx_cal_clk | **-0.651 ns**（最差） | -0.776 ns |
| tx_cal_clk_90edge ← tx_cal_clk_90edge | -0.490 ns | -0.399 ns |
| core_clk ← core_clk | -0.481 ns | -0.535 ns |
| tx_cal_clk ← tx_cal_clk | -0.385 ns | -0.126 ns |
| sdram_clk ← sdram_clk | -0.313 ns | -0.313 ns |

- `ti60f225_oob.hold_fixing.rpt`：`No router hold fixing is required.`（**无 hold fix 需求行**）

### 22.7 烧录（`-m jtag`，只下 .bit，不写 SPI 闪存）→ **成功**

- 命令：`flash_vendor.ps1 -Bit ...\v7_WBH6\out\v7_WBH6.bit -Sha256 480B931B...1331`（sha256 前置实时重算，一致）
- 前置检查：文件类型 OK / sha256 一致 / FTDI 驱动 2.12.36.4 统一 / 无进程占用 FTDI → 全通过，退出码 0
- 日志：`D:\FPGA\mmt\out\evidence\vendor_flash_logs\vendor_flash_20261020_001422.log`
- **双判据原文**：
  - `Device ID read from JTAG: 0x10660A79`
  - `... finished with JTAG programming`
- 结果：**PASS / 烧录成功**（`nativeExit: 0`，`mode: jtag`，`size: 2559276`，`sha256: 480B931B…1331`）

**旁记（据实记录，非本变体）**：`vendor_flash_20261020_001329.log`（00:13:29）为另一条执行线重烧的 **WBH3**（sha256 `A562A9FB…2936`），同样双判据 PASS；
本轮 WBH6 烧录发生在其后（**00:14:22**），故板上当前最终状态 = **WBH6**。

### 22.8 结论与边界

- 构建 + 烧录 **WBH6** 均完成，双判据 PASS，板上当前运行 **WBH6（G ≈ 1.094× 不变，B 1.813× → 1.625×）**。
- **画面由 Kevin 判断，本文件不下结论**——本节只记录："WBH4 被判太绿 ⇒ G 不是不足；WBH3 绿板变蓝 ⇒ B 偏高"，因此 WBH6 只把 B 从 1.813× 降到 1.625×，绿 PCB 是否回到绿色、白纸/红笔是否仍正确，**由 Kevin 目视判定**，本节不作任何图像质量结论。
- 只改 `v7_WBH6\debug_top.v` **1 行**；`v7_WBH3` 只读复制、未改动。
- 只烧 WBH6 一个变体（共 1 次）。
- **未推送 GitHub。**
- **未研究、未触碰 Debugger。**
