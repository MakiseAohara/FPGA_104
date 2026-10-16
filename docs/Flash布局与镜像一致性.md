# Flash 布局与镜像一致性（task-11）

> 范围：把"**烧进 flash 的东西**"整体对齐一遍 —— 位流多大、镜像从哪开始、loader 从哪读、
> 四份脚本对同一份镜像头的理解是否一致。本文档 + `sw\ddr\verify_flash_layout.ps1` +
> `sw\ddr\verify_combined_image.py` 是产物。
>
> 写权限遵守：只写 `sw\ddr\` 与本文档；**没碰** `rtl\`、`ip\`、`constr\`、`mmt.xml`、`sim\`、
> `docs\` 下已有文件、`sw\` 下已存在文件。**没跑 Efinity 流程**（efx_map/efx_pnr/build.ps1）。
> 本文档里唯一动过的"非校验"工具是 **Programmer 自带的合并工具**
> `multi_image_merger.py`（只做文件拼接，不碰工程 work 目录），输出落在 `sw\ddr\build\`。
>
> 约定：**【实测】**= 本轮真跑过命令/真解析过文件并给原始输出；**【推算】**= 由实测数算出；
> **【推断】**= 有依据但无直接证据，写明怎么证实；没把握的写"**无法确认**"。

---

## 0. 一页结论

1. **布局自洽，可以烧。** 位流 `0x00000000 + 959,901`、用户镜像 `0x00380000 + 304,780`，
   两者**不重叠**、都在 8MB 内、起始地址**扇区对齐**。校验脚本
   `verify_flash_layout.ps1`：**PASS 24 / FAIL 0 / WARN 2，退出码 0**。
2. **⚠️ 必须先纠正一个数：位流的 flash 占用不是 2,812.2 KB。**
   2,812.2 KB（2,879,721 字节）是 `out\mmt.hex` 的**文件大小**；这个文件是
   **"每行一个字节的十六进制文本"**，真实字节数只有 **959,901 字节 = 0xEA59D = 937.4 KiB = 0.915 MiB**。
   **这一点有厂商工具亲口作证**：用 Programmer 自带的合并工具跑出来的报告写着
   `0x00000000  0x000ea59d  mmt.hex`（§1.2）。按 2.75MB 规划 flash 会白白浪费 1.8MB 的余量判断。
3. **四份脚本的镜像头字段逐条一致**（魔数/版本/12 个字段偏移/长度/CRC 全对得上，§3.1），
   CRC32 有 **4 处独立实现 + zlib 参考实现**互相印证（§3.3）。
   但本轮**查出 5 处不一致/隐患**，其中 2 处**已当场修掉**：
   - ✅ 已修：`pack_image.ps1` 与 `mkimage.ps1` **默认输出同一个文件名**却是**不兼容的两种格式**（真陷阱）；
   - ✅ 已修：`verify_image.py` 把 flash 起始地址/容量**写死**，改了布局会"假通过"；
   - ⚠️ 未改（记录 + 缓解）：镜像头里**没有 flash 起始地址字段**；
   - ⚠️ 未改（记录）：loader 的 CRC 只认"标准载荷布局"，非标准布局时会**跳过** CRC；
   - ⚠️ 未改（无害）：`mkimage` 要求 app 在权重之前，loader 允许两种顺序；`verify_image.py` 的 app 上界判据偏弱。
4. **烧写有两条路，都实测过命令**（§4）：合成一个文件一次烧（`multi_image_merger.py`，已跑通，
   产物 `sw\ddr\build\flash_combined.hex`，逐字节校验 PASS 6 / FAIL 0）；或按厂商 readme 分两次烧。
5. **一个新发现（良性但要知情）**：合并工具会把位流文本头 `Project:` 路径里的**非 ASCII 字节换成 0xFF**
   （实测 `易灵思` 的 9 个 UTF-8 字节 → 9 个 0xFF，其余 959,892 字节完全一致）。
   该字段是信息性的，**【推断】不影响 FPGA 配置**；上电若配置失败就退回"分两次烧"（用原始 `mmt.hex`）。
6. 必须真机确认的项集中在 §5（合并文件的 9 字节替换、GD25LQ64 擦除粒度、Programmer 擦除范围、
   位流 CRC 校验是否生效、flash 实测容量）。

---

## 1. 先说清一个容易搞错的数：位流"文件大小" ≠ "flash 占用"

### 1.1 Efinity 的 `.hex`/`.bit` 到底是什么格式（**实测**）

厂商给的 `.hex`/`.bit` **不是** Intel HEX（没有 `:` 记录）。它是：

```
每行一个字节，十六进制文本：
  · 字节 < 0x80  → 2 位十六进制，例如 0x47 → "47"
  · 字节 ≥ 0x80  → 4 位十六进制（高位补 FF，是"有符号字节符号扩展"的痕迹），例如 0xE6 → "FFE6"
文件开头是一段**纯文本头**（也是"每行一个字节"），字段有：
  Version / Generated / Project / Family / Device / Width / Mode / Die Name / 4Byte / PADDED_BITS
文本头之后用 0x0A 填充到固定位置，然后是位流数据。
```

实测证据（本轮解析 `D:\FPGA\mmt\out\mmt.hex`）：

```
文件大小        : 2,879,721 字节 = 2,812.2 KiB = 2.75 MiB        ← Lead 给的那个数
行数            : 959,901
  其中 2 位行   : 959,892
  其中 4 位行   : 9      （就是下面"易灵思"的 9 个 UTF-8 字节）
  异常行        : 0
按"每行 1 字节"解码 = 959,901 字节 = 0xEA59D = 937.4 KiB = 0.915 MiB
文本头长度      : 256 字节（'PADDED_BITS' 之后 LF 填充结束处）
位流数据        : 959,901 - 256 = 959,645 字节
```

> **文件大小 ≈ 真实字节数 × 3**（每个字节写成 2 个十六进制字符 + 1 个换行）。
> 所以**千万不要用文件大小估 flash 占用**。

### 1.2 位流到底占多少：厂商工具亲口给的数（**实测**）

`out\mmt.hex` 的文本头（把 4 位行取低字节后解码，**实测**）：

```
Version: 2026.1.132
Generated: Sun Oct 11 20:03:05 2026

Project: D:\FPGA\易灵思          ← 9 个 UTF-8 字节（E6 98 93 E7 81 B5 E6 80 9D）
Family: Titanium
Device: Ti60F225
Width: 1
Mode: active
Die Name: Ti60_MP
4Byte: 0
PADDED_BITS: 0
```

用 **Programmer 自带的合并工具**（`D:\Efinity\2026.1\pgm\bin\multi_image_merger.py`）
把位流和用户镜像合起来，它自己打印的报告就是权威答案（原始输出见 §4.1）：

```
Generated FPGA Soc Image output file: D:\FPGA\mmt\sw\ddr\build\flash_combined.hex
Flash Address  Length      Input Image File
0x00000000     0x000ea59d  D:\FPGA\mmt\out\mmt.hex              ← 位流：959,901 字节
0x00380000     0x0004a68c  D:\FPGA\mmt\sw\ddr\build\ddr_image.bin ← 镜像：304,780 字节
```

`0x000ea59d = 959,901` —— **与 §1.1 的解码结果一模一样**，两条独立路径互相印证。
报告文件：`sw\ddr\build\flash_combined.rpt`。

> ⚠️ **本文档所有位流数字都绑定到这一份文件**：`out\mmt.hex`，
> 时间戳 `2026-10-11 20:03:05`，磁盘 2,879,721 字节（解码 959,901 字节）。
> **它生成于"SPI0 接线"之前**。本轮结束时 `rtl\mmt\soc\mmt_soc_subsystem.v:391-402` 与
> `rtl\mmt\mmt_top.v:192-206` **已经加上了 SPI 接线**（task-7 §3 的前置条件），
> 所以**下一次重跑流程后位流一定会变**（逻辑增加了）。
> ⇒ 重跑之后**必须重新执行**：
> `powershell -File D:\FPGA\mmt\sw\ddr\verify_flash_layout.ps1`
> （它会重新解码新位流、重算布局与重叠）。**【推算】**新位流仍会在 1MB 上下，
> 3.5MB 的余量不会被吃掉；但**这是推算，不是实测**，以重跑后的脚本输出为准。

> **结论（实测）**：位流在 flash 里占 **959,901 字节（0.915 MiB）**，不是 2,812.2 KB。
> 位流头里的 `Mode: active` / `Width: 1` / `Device: Ti60F225` 与 `mmt.xml:204/205`
> （`mode=active`、`width=1`）一致，说明这份位流确实是"从 flash 0x0 启动"的那种。
> （`out\mmt.bit` 与 `out\mmt.hex` 是**同一个文本格式**，`.bit` 少了 20 行 = 60 字节的
> "Version/Generated" 段，字节数 959,881；**实测**。）

### 1.3 【推断】合并工具会不会把文本头也写进 flash？

会——文本头本身就是位流的一部分（配置引擎要读 `Version/Device/Width/Mode/...`），
且工具报告的 `0x000ea59d` **正好等于包含文本头的全部字节数**。**实测支撑**：厂商那份
`ddr_demo_ti60.hex` 解出来的字节数与其 `soc_combine_hex.rpt` 的报告值在**同一量级且接近**
（654,335 vs 649,454，差 0.75%；那份 rpt 是 2025-09-12 生成的，与其 `.hex` 未必同一次构建，
所以这点差异**无法确认**原因，但不影响我们的结论——我们自己的文件是**精确相等**的）。

---

## 2. flash 布局表

### 2.1 布局表（每行都给依据）

| 区 | 起始(flash) | 长度 | 结束(含) | 依据 |
|---|---|---|---|---|
| **位流**（FPGA 配置用） | `0x00000000` | **959,901 B**（`0xEA59D`） | `0x000EA59C` | **实测**：`mmt.hex` 解码 + 合并工具报告 `0x000ea59d`（§1.2）；SPI Active 必须从 0 开始（`mmt.xml:204 mode=active`） |
| （间隙·未使用） | `0x000EA59D` | 2,710,115 B | `0x0037FFFF` | **实测**：合并工具把这里填 `0xFF` |
| **用户镜像**（头+app+权重） | `0x00380000` | **304,780 B**（`0x4A68C`） | `0x003CA68B` | **实测**：镜像头 `+8 total_size`；合并工具报告 `0x0004a68c`；起始地址是厂商约定（`_ddr_demo_ti60\outflow\soc_combine_hex.rpt:7`、`Ti60f225_sc431hai2hdmi_v1\readme.txt:84`），**也是本工程 loader 的编译常量** `mmt_ddr.h:67 MMT_FLASH_IMG_BASE = 0x00380000` |
| （剩余可用） | `0x003CA68C` | 4,413,812 B | `0x007FFFFF` | 8MB − 镜像末尾（`mmt_ddr.h:69 MMT_FLASH_SIZE = 0x00800000`） |

**镜像内部结构**（`ddr_image.bin` 的头部字段，**实测**逐字段读出来的）：

| 内部区 | flash 绝对地址 | 长度 | 内容/落点 |
|---|---|---|---|
| 镜像头 | `0x00380000` | 48 B | magic `0x31544D4D`、version 1、total_size 304,780 … |
| 头后填充 | `0x00380030` | 16 B | 全 0（把载荷对齐到 64 字节） |
| app 载荷 | `0x00380040` | 4,148 B | 由 loader 搬到 **DDR `0x00001000`** |
| 权重载荷 | `0x00381074` | 300,568 B | 由 loader 搬到 **DDR `0x00100000`** |

（`0x00380040 + 4148 = 0x00381074` ✓；`0x00381074 + 300568 - 1 = 0x003CA68B` ✓ 与上表一致。）

### 2.2 重叠/越界/对齐检查（**实测**，脚本输出）

```
PASS  位流结束 0x000EA59C ≤ 用户镜像起始 0x00380000（不重叠，间隙 2,710,115 = 2,646.6 KiB）
PASS  位流结束 0x000EA59C ≤ flash 容量 0x00800000
PASS  镜像结束 0x003CA68B ≤ flash 容量 0x00800000（剩余 4,413,812 = 4,310.4 KiB）
PASS  用户镜像起始 0x00380000 是 4096 字节扇区对齐的（擦除不会误伤位流区）
PASS  位流起始 0x0 是扇区对齐的
INFO  镜像需要擦除 75 个 4096 字节扇区（0x00380000 起始）
```

手动复算（都能在纸上验）：
- 位流末尾 `0xEA59C` < 镜像起始 `0x380000` ⇒ **不重叠**，中间浪费 2.65 MB（无害）；
- `0x3CA68B < 0x800000` ⇒ **不越界**；
- `0x380000 % 0x1000 == 0` ⇒ 擦除 `0x380000` 起的扇区**不会**碰到位流区（位流末尾离它还有 2.65MB）；
- 镜像 304,780 B 只占用户区预算 4,718,592 B（= 8MB − 3.5MB）的 **6.5%**。

### 2.3 关于"间隙 2.65MB"和"能不能把镜像前移"

**现状**：位流只占 0.92MB，但镜像按厂商约定放在 3.5MB 处，中间 2.65MB 空着。
**这是浪费但无害**，而且它带来一个好处：位流就算将来涨到 3.4MB 也不用改任何东西。

**如果哪天需要更多用户区**（例如模型换成 >4.5MB 的），可以前移镜像起始地址：

1. `build_ddr.ps1 -FlashBase 0x100000`（它会把同一个值**同时**传给 mkimage 的 `-FlashBase`
   和 loader 的 `-DMMT_FLASH_IMG_BASE`，见 `build_ddr.ps1:51/153/155`）；
2. 用同一个 `-FlashBase` 重跑 `verify_flash_layout.ps1`；
3. 重烧（**注意：loader 变了 → 必须重新跑 Efinity 综合**，因为 loader 是片内 RAM 初值）。

这样用户区从 4.5MB 变成 `0x800000 − 0x100000 = 7MB`。
**代价**：偏离厂商约定、每换一次地址要重跑流程；**现在没必要**（只用 6.5%）。

---

## 3. 四份脚本的字段逐条对照

"写的时候按一种格式、读的时候按另一种"是 bring-up 最经典的坑。下面逐字段对照
**生产者**（`mkimage.ps1` 写镜像头）与**消费者**（`loader.c` 读并解析、`verify_image.py` /
`verify_flash_layout.ps1` 独立复算），外加**旧的甲路线生产者** `pack_image.ps1`。
字段定义的单一定义源是 `sw\ddr\mmt_ddr.h` 的 `mmt_img_hdr_t`。

### 3.1 对照表（**全部一致**，除非另注）

| 字段 | 定义源 | 写：`mkimage.ps1` | 读：`loader.c` | 独立复算：`verify_image.py` | 独立复算：`verify_flash_layout.ps1` | 一致？ |
|---|---|---|---|---|---|---|
| 魔数 `0x31544D4D`("MMT1") | `mmt_ddr.h:79` | `:51`（`PutU32 $img 0`，`:143`） | `:103`（比对 `MMT_IMG_MAGIC`） | `:25` / `:96` | 脚本内 `$MAGIC` | ✅ |
| 版本 `1` | `mmt_ddr.h:80` | `:52` / `:144` | `:104` | `:26` / `:100` | `$VERSION` | ✅ |
| 头长 `48` | `mmt_ddr.h:81` | `:53`（读头用） | `:96`（读 `MMT_IMG_HDR_SIZE` 字节） | `:27` | `:23` | ✅ |
| 载荷偏移 `64` | `mmt_ddr.h:82` | `:54` / `:130`（app 放 64 处） | `:180/:192`（`base + 64 + off`） | `:28` / `:158` | `:23` | ✅ |
| `+0 magic` | `mmt_ddr.h:85` | `:143` | 结构体访问 | `:88` `<12I` 第 1 个 | 同 | ✅ |
| `+4 version` | `:86` | `:144` | 同 | 第 2 个 | 同 | ✅ |
| `+8 total_size` | `:87` | `:145`（= 64 + payload） | `:111`（`> MMT_FLASH_IMG_MAX` 就拒） | `:104`（== 文件长度） | 同 | ✅ |
| `+12 app_flash_off` | `:88` | `:146`（恒 0） | `:180` | `:172` | 同 | ✅ |
| `+16 app_ddr_addr` | `:89` | `:147`（`-AppDdr`，默认 `0x1000`，`:40`） | `:117/:120`（不许落空洞/越界） | `:123/:127` | 同 | ✅ |
| `+20 app_len` | `:90` | `:148`（4 字节对齐后的长度） | `:134`（4 的倍数）、`:215` | `:142` | 同 | ✅ |
| `+24 w_flash_off` | `:91` | `:149`（= app_len） | `:221`（分段 CRC 的边界判据） | `:173` | 同 | ✅ |
| `+28 w_ddr_addr` | `:92` | `:150`（`-WeightsDdr`，默认 `0x100000`，`:41`） | `:124/:129` | `:134/:138` | 同 | ✅ |
| `+32 w_len` | `:93` | `:151` | `:134`、`:196`、`:222` | `:142` | 同 | ✅ |
| `+36 payload_crc` | `:94` | `:152` | `:231/:233`（比对） | `:165` | `:254` | ✅ |
| `+40 payload_len` | `:95` | `:153` | `:114`（必须 == total−64）、`:227` | `:119` | 同 | ✅ |
| `+44 reserved0` | `:96` | `:154`（写 0） | 不检查 | `:109`（必须 0） | 同 | ✅ |
| CRC 算法（poly `0xEDB88320`、反射、init/xorout `0xFFFFFFFF`） | `spi_flash.h: mmt_crc32_update` | `mkimage.ps1 Get-Crc32` | `spi_flash.h`（编进 loader） | `crc32_bitwise()` + zlib 对照 | `Get-Crc32` | ✅ |
| CRC 覆盖范围 = 载荷（`[64, 64+payload_len)`） | — | `:134`（对 `$payload` 算） | `:214-227`（app 段 + 权重段，见下注） | `:158` | 同 | ✅（有条件） |
| app 的 DDR 落点 `0x1000` | `link_ddr.ld:62`（`ORIGIN`） | 默认 `-AppDdr` `:40` | 用头里的值 | 用头里的值 | 同 | ✅ |
| 权重 DDR 落点 `0x00100000` | `link_ddr.ld:69`（`PROVIDE`）+ `mmt_ddr.h:45` | 默认 `-WeightsDdr` `:41` | 用头里的值 | 用头里的值 | 同 | ✅ |
| flash 起始 `0x380000` | `mmt_ddr.h:67` | `-FlashBase` `:38` | 编译期 `MMT_FLASH_IMG_BASE`（`build_ddr.ps1:51` 传 `-D`） | **曾是写死常量** → 现在可 `--flash-base` | 参数 `-ImageBase` `:27` | ✅（已修，见 3.2-②） |
| flash 容量 8MB / 预算 4.5MB | `mmt_ddr.h:69-70` | `:103`（`FlashSize-FlashBase`） | `MMT_FLASH_IMG_MAX` | `FLASH_IMG_MAX` | `FlashSize`/`ImageBase` | ✅ |

> **注（loader 的 CRC 分段）**：`loader.c:214-227` 的 CRC 是**按 DDR 里的顺序分段累加**的
> （先 app、再权重），只有当 `app_flash_off == 0` **且** `w_flash_off == app_len` 时，
> 这个次序才等于"flash 载荷顺序"。不满足时 loader 会打印
> `(payload layout unexpected -> skip CRC)` 并**跳过** CRC（`:227-229`）。
> `mkimage.ps1` 默认生产的就满足这个条件（`:146/:149`），所以实测每次都能验；
> 但这是**格式允许、语义受限**的地方，见 3.2-④。

### 3.2 发现的不一致 / 隐患（5 条）

**① 两个打包脚本默认输出同一个文件名，格式却不兼容 —— 真陷阱（✅ 已修）**

- `mkimage.ps1` 的 `-Out` 默认 `sw\ddr\build\ddr_image.bin`（**新格式**：48B 头 + 载荷@64）；
- `pack_image.ps1`（旧甲路线）的 `-Out` 默认**也**是 `sw\ddr\build\ddr_image.bin`，
  但它产出的是**纯拼接**（app 直接在 0 处、无头、app 区被填到 `0xFF000`，`:39/:67/:90`）。
- 后果：**先跑 `mkimage.ps1` 再跑 `pack_image.ps1`，镜像会被悄悄覆盖成"没带头"的版本**。
  上板后 loader 在 `0x380000` 读到的是 app 的第一条指令当"魔数"，magic 检查失败
  ⇒ **它拒绝跳转**（`loader.c:103`），所以不会乱飞，但现象是"loader 报 magic wrong 然后停住"。
- **处置**：把 `pack_image.ps1` 的默认输出改名成 `LEGACY_routeA_image.bin`，并在文件头加了醒目警告；
  `verify_flash_layout.ps1` 在 magic 不对时也会提示"这可能是 pack_image.ps1 的产物"。

**② `verify_image.py` 把 flash 起始/容量写死（✅ 已修）**

- 原来 `FLASH_BASE = 0x00380000` / `FLASH_SIZE = 0x00800000` 是模块常量，
  与 `mkimage.ps1 -FlashBase`、`loader` 的编译常量**没有任何联动**。
  一旦把镜像前移（§2.3），它会拿旧地址算预算而**假通过**。
- **处置**：新增 `--flash-base` / `--flash-size` 参数（实测：`--flash-base 0x400000`
  后输出的预算从 4,718,592 变成 4,194,304，说明参数生效）。

**③ 镜像头里没有"flash 起始地址"字段（⚠️ 记录，未改）**

- loader 用的 `MMT_FLASH_IMG_BASE` 是**编译期常量**，镜像头里只记 app/权重在**载荷内**的偏移，
  不记整个镜像放在 flash 哪里。若"编 loader 时的基址"与"实际烧写地址"不一致，
  loader 会在错误地址读到别的数据 → magic 失败 → 停下。**安全但难查**。
- **缓解（已做）**：`build_ddr.ps1` 是唯一入口，它把同一个 `-FlashBase`
  同时喂给 mkimage（`:153/:155`）和 loader 编译（`:51`）；
  `verify_flash_layout.ps1` 每次都会打这条 WARN 提醒"头里没有这个字段"。
- **建议（若要根治）**：在头里加 `+44 flash_base`（把 `reserved0` 用起来），
  并把 `version` 升到 2，四处脚本同步。**本轮不改**——改格式会让已实测通过的镜像作废，
  收益不抵风险。

**④ loader 的 CRC 只认"标准载荷布局"（⚠️ 记录，未改）**

- 见 3.1 的表注。非标准布局时 loader **跳过** CRC 却仍然继续启动（返回 1）。
  语义上"跳过校验"和"校验通过"在 UART 上打印不同（`skip CRC` vs `CRC32 OK`），
  但如果只看结果会误以为验过了。
- **建议**：要么让 loader 在跳过时**拒绝启动**（更严格），要么头里加布局标志位。
  `mkimage.ps1` 默认布局是标准的，所以现阶段不影响；**本轮不改**（改了要重跑整套验证）。

**⑤ 判据强度不一致（⚠️ 记录，无害）**

| 差异点 | `mkimage.ps1`（生产者） | `loader.c`（消费者） | 影响 |
|---|---|---|---|
| app 与权重的先后顺序 | `:123` 要求 `AppDdr + appLen ≤ WeightsDdr` | `:129-130` 允许两种顺序（只要不重叠） | 生产者更严；手工造的"权重在前"镜像会被 mkimage 拒绝、被 loader 接受。**无害** |
| app 是否越 `0x00100000` | `:123` 蕴含（由权重起始约束） | `:120` 只查物理 DDR 上限，不查 1MB | loader 不查 1MB 是有意的（内存图可改），但意味着"1MB app 区"是 `link_ddr.ld` 的 ASSERT 在守（`link_ddr.ld:119-124`），不在这三份脚本里 |
| `verify_image.py` 的 app 上界 | — | — | `:151` 的判据是"不越界**或**整个在界之上都算 OK"，偏弱（**无害**：它只是复算，不是生产者） |

### 3.3 CRC32：四处实现 + zlib 交叉验证（**实测**）

| 实现 | 文件 | 本轮实测结果 |
|---|---|---|
| C（编进 loader） | `sw\ddr\spi_flash.h` `mmt_crc32_update` | 同一算法；由 PowerShell/Python 的标准测试向量间接验证 |
| PowerShell（写头） | `sw\ddr\mkimage.ps1` `Get-Crc32` | 自检 `'123456789' → 0xCBF43926`（标准向量）通过；对实际载荷算出 `0xCFCF5E87` |
| PowerShell（复算） | `sw\ddr\verify_flash_layout.ps1` `Get-Crc32`（**独立写的第二份 PS 实现**） | 复算 `0xCFCF5E87`，与头里一致 |
| Python 位运算 | `sw\ddr\verify_image.py` `crc32_bitwise()` | `0xCFCF5E87` |
| Python `zlib.crc32`（第三方参考） | 同上 | `0xCFCF5E87`（与位运算实现一致，双向印证） |

⇒ 生产/消费两侧对 CRC 的理解**完全一致**；loader 上板后的 `[5] CRC32 OK` 就是这条链的最后一环。

---

## 4. 烧写步骤

### 4.1 方案 A：合成一个文件，一次烧（**推荐**；本轮已实测跑通）

Programmer 自带合并工具（**实测命令与输出**）：

```powershell
# 必须先 call setup.bat，否则 python3.bat 找不到 PYTHONHOME（第一次直接跑会报
# "ModuleNotFoundError: No module named 'encodings'"）
cmd /c 'call "D:\Efinity\2026.1\bin\setup.bat" >nul 2>&1 && python "D:\Efinity\2026.1\pgm\bin\multi_image_merger.py" -m generic_comb_image -ifile "D:\FPGA\mmt\out\mmt.hex" -iaddr 0x00 -ifile "D:\FPGA\mmt\sw\ddr\build\ddr_image.bin" -iaddr 0x380000 -o "D:\FPGA\mmt\sw\ddr\build\flash_combined.hex"'
```

原始输出（**实测**）：

```
#-----------------------------------------
# User Configuration
#-----------------------------------------
Mode		: generic_comb_image
No	: Starting Address	: Image
Image  1: 0x00                 : D:\FPGA\mmt\out\mmt.hex
Image  2: 0x380000             : D:\FPGA\mmt\sw\ddr\build\ddr_image.bin
#-----------------------------------------
Unexpected error: expected str, bytes or os.PathLike object, not NoneType      ← 见下注

Generated FPGA Soc Image output file: D:\FPGA\mmt\sw\ddr\build\flash_combined.hex
Flash Address  Length      Input Image File
0x00000000     0x000ea59d  D:\FPGA\mmt\out\mmt.hex
0x00380000     0x0004a68c  D:\FPGA\mmt\sw\ddr\build\ddr_image.bin

Generated report file D:\FPGA\mmt\sw\ddr\build\flash_combined.rpt
```

> 注：工具会打印一行 `Unexpected error: ... not NoneType`，但**报告和输出文件都正常生成了**，
> 且产物经逐字节校验完全正确（下游 §4.3）。**【推断】**这是工具内部一个非致命的收尾异常。
> **无法确认**它的确切含义；如果在意，用方案 B（分两次烧）即可完全绕开。

产物（**实测**）：`flash_combined.hex` 磁盘 11,924,388 字节 = 3,974,796 × 3，
即内容 **3,974,796 字节 = 0x3CA68C**（覆盖 `0x0` 到 `0x3CA68B` 整段）。

**烧写操作（GUI，厂商 readme 原样做法）**：
1. Efinity → Programmer（本机启动器 `D:\Efinity\2026.1\bin\efinity_pgm.bat`）；
2. 选 `sw\ddr\build\flash_combined.hex`；
3. Programming Mode = **spi active**；
4. Starting flash Address = **`0x000000`**；
5. Start Program。

### 4.2 方案 B：分两次烧（厂商 OOB readme 的做法）

依据 `Ti60f225_sc431hai2hdmi_v1\readme.txt:75-102`（原文：位流
`Hardware Bitstream for spi flash programming at Address 0x000000`；
软件 `Software Bitstream for spi flash programming at Address 0x380000`）：
1. Programmer → 选 `out\mmt.hex` → **spi active** → 地址 **`0x000000`** → Start；
2. 同一窗口 → 选 `sw\ddr\build\ddr_image.bin` → **spi active** → 地址 **`0x380000`** → Start。

**优点**：位流用的是**原始** `mmt.hex`（没有 §5-V1 那 9 字节替换），
万一方案 A 的合并产物配置不起来，直接退到这条。

> ⚠️ 无论哪种方案，**烧之前先跑**：
> `powershell -File sw\ddr\verify_flash_layout.ps1`（布局+镜像自洽，退出码 0 才烧）。
> 用方案 A 的话，再跑一遍
> `python sw\ddr\verify_combined_image.py`（合并产物逐字节校验）。

### 4.3 校验（PC 侧 + 上板）

**PC 侧（本轮全部实测通过）**：

| 检查 | 命令 | 结果 |
|---|---|---|
| 布局/镜像自洽 | `powershell -File sw\ddr\verify_flash_layout.ps1` | **PASS 24 / FAIL 0 / WARN 2**，exit 0 |
| 镜像格式（模拟 loader 搬运） | `python sw\ddr\verify_image.py ...` | **18 PASS / 0 FAIL** |
| 合并产物逐字节 | `python sw\ddr\verify_combined_image.py` | **PASS 6 / FAIL 0 / WARN 1**，exit 0 |

`verify_combined_image.py` 的核心结论（**实测**）：

```
合并文件内容长度 3974796 (0x3CA68C) == max(位流末尾, 镜像末尾)      PASS
位流段差异 9 处，全部是'非 ASCII -> 0xFF'的已知替换（Project 路径字段）  PASS
镜像段 [0x380000, 0x3CA68C) 与 ddr_image.bin 逐字节一致            PASS
间隙 [0xEA59D, 0x380000) 全部填 0xFF（2,710,115 字节）             PASS
偏移 0 是位流文本头（'Vers'）                                      PASS
偏移 0x380000 是用户镜像 magic 'MMT1'                             PASS
```

**上板读回（三层次，都不需要额外的 PC 工具）**：

| 层次 | 谁在验 | 怎么看出来 |
|---|---|---|
| 位流完整性 | **FPGA 配置引擎自己**（`mmt.xml:212 enable_crc_check=on`） | 配置成功=能进用户模式；失败会配置不起来（DONE 不置位）。**这是位流唯一的读回校验** |
| 用户镜像完整性 | **loader 自己**（`loader.c:207-235`，从 flash 读出来搬进 DDR 后重算 CRC32） | 串口打印 `[5] CRC32 OK`；不一致会打印 `!! CRC MISMATCH` 并**拒绝跳转** |
| 端到端 | **DDR 里的 app 自己**（`ddr_app.c` 重读 flash 头再算一遍 CRC） | 串口打印 `==> CRC32 MATCH: loader copied app+weights correctly` |

> 注意：**App 区/权重区在 flash 里没有独立的文件系统或校验尾**，唯一的完整性依据就是
> 镜像头里的 `payload_crc`。所以"CRC 对"= "flash 里那段和 PC 上那份字节一致"（这也是 §4.3 第一层
> PC 侧校验已经在证明的事）。**烧写器自身有没有"读回比对"功能，无法确认**（没有跑过 Programmer GUI）。

---

## 5. 必须在真机确认的项

| # | 项 | 现状 | 怎么确认 |
|---|---|---|---|
| V1 | 合并产物里位流头 `Project:` 的 **9 个非 ASCII 字节被换成 0xFF** 会不会影响配置 | **实测**替换存在；**【推断】**不影响（该字段信息性，且是厂商工具自己做的） | 用方案 A 的 `flash_combined.hex` 上电，看能否正常配置。失败 → 退方案 B（用原始 `mmt.hex`） |
| V2 | GD25LQ64 的**擦除粒度**（4KB 扇区 / 64KB 块） | **推断** 4KB 扇区（脚本按 4KB 估算，需要 75 个扇区） | 查 GD25LQ64 数据手册；或先擦一个 4KB 扇区再读回全 0xFF |
| V3 | Programmer 烧 `0x380000` 时**擦除范围**是否只覆盖镜像区（不误擦位流区） | **推算**安全：`0x380000` 扇区对齐，位流末尾离它 2.65MB | 烧完后读回 `0x000000–0x000EA59C` 与 `out\mmt.hex` 比对（或直接看 FPGA 还能否配置） |
| V4 | 位流**真实写入 flash 的长度**是否等于 959,901 | **实测**（合并工具报告 `0x000ea59d`） | 已确认；如需再证，读回 flash 前 959,901 字节与 `mmt.hex` 解码结果比对 |
| V5 | flash 实际容量是否 8MB | **实测**（两处资料：`参考资料\_目录说明.md:67`、板卡说明 pdf.txt `:124/:640`） | 读芯片丝印 GD25LQ64 / 手册 64Mbit=8MB |
| V6 | 位流 CRC 校验是否真的生效 | `mmt.xml:212 enable_crc_check=on`（配置项） | 配置成功后故意改坏 flash 里位流区一个字节，看是否配置失败 |
| V7 | 上电后 loader 的 CRC 是否通过 | 未上板 | 串口 115200 看 `[5] CRC32 OK` / `==> CRC32 MATCH` |
| V8 | 物理 DDR 256MB（影响 `0x10000000` 上限判据） | **推断**（`rtl\ddr3_controller\ddr3_parameter.vh:6-15` 几何反推） | 见 task-7 文档 §7-V9 |
| V9 | **重跑流程后的新位流**（SPI 已接线，逻辑变了）的 flash 占用与布局 | 本文档验的是接线**之前**那份（`20:03:05`） | 重跑后执行 `verify_flash_layout.ps1`，看新的"解码字节"与布局表；【推算】仍在 1MB 上下 |

---

## 6. 复现命令与产物清单

```powershell
# 1) 布局 + 镜像自洽（最快，先跑这个）
powershell -File D:\FPGA\mmt\sw\ddr\verify_flash_layout.ps1

# 2) 镜像格式（模拟 loader 搬运 + CRC 三重比对）
& "<python>" D:\FPGA\mmt\sw\ddr\verify_image.py `
    D:\FPGA\mmt\sw\ddr\build\ddr_image.bin `
    --app D:\FPGA\mmt\sw\ddr\build\ddr_app.bin `
    --weights D:\FPGA\mmt\sw\ddr\weights\mobilenetv1_person_detect_model_data.bin

# 3) 合成一个可烧文件（方案 A）+ 校验它
cmd /c 'call "D:\Efinity\2026.1\bin\setup.bat" >nul 2>&1 && python "D:\Efinity\2026.1\pgm\bin\multi_image_merger.py" -m generic_comb_image -ifile "D:\FPGA\mmt\out\mmt.hex" -iaddr 0x00 -ifile "D:\FPGA\mmt\sw\ddr\build\ddr_image.bin" -iaddr 0x380000 -o "D:\FPGA\mmt\sw\ddr\build\flash_combined.hex"'
& "<python>" D:\FPGA\mmt\sw\ddr\verify_combined_image.py
```

本轮新增/改动的文件（都在 `sw\ddr\`）：

| 文件 | 动作 | 作用 |
|---|---|---|
| `verify_flash_layout.ps1` | **新增** | 输入位流+镜像 → 布局表 + 重叠/越界/对齐 + 镜像头/CRC 复核 + PASS/FAIL 退出码 |
| `verify_combined_image.py` | **新增** | 校验合并后的"整片 flash 镜像"（长度/两段内容/间隙/magic） |
| `verify_image.py` | **改** | 新增 `--flash-base` / `--flash-size`（不再写死） |
| `pack_image.ps1` | **改** | 默认输出改名 `LEGACY_routeA_image.bin` + 醒目警告（避免与 mkimage 撞车） |
| `build\flash_combined.hex` / `.rpt` | **产物** | 方案 A 的一次性烧写文件与工具报告（11.9MB / 884B 报告） |

---

## 7. 证据清单

| 来源 | 关键行/数 | 证明什么 |
|---|---|---|
| `D:\FPGA\mmt\out\mmt.hex` | 磁盘 2,879,721 B；959,901 行 | 位流文件大小 ≠ flash 占用 |
| 同上（解码） | 2 位行 959,892 + 4 位行 9 = **959,901 B = 0xEA59D** | 真实字节数 |
| 同上（文本头） | 256 字节；`Device: Ti60F225` / `Width: 1` / `Mode: active` | 位流是"SPI Active、Ti60F225"的那一份 |
| `sw\ddr\build\flash_combined.rpt` | `0x00000000 0x000ea59d` / `0x00380000 0x0004a68c` | **工具亲口确认**两段的 flash 长度 |
| `sw\ddr\build\ddr_image.bin` | `+0 0x31544D4D`、`+8 0x4A68C`、`+36 0xCFCF5E87` | 镜像头字段实测值 |
| `sw\ddr\build\flash_combined.hex` | 内容 3,974,796 B；间隙全 0xFF；镜像段逐字节一致 | 合并产物正确 |
| `sw\ddr\mmt_ddr.h` | `:67` / `:69` / `:70` / `:79-96` | flash 基址/容量/预算、头定义 |
| `sw\ddr\mkimage.ps1` | `:38/:40/:41`（地址参数）、`:51-54`（常量）、`:143-154`（写头） | 生产者字段 |
| `sw\ddr\loader.c` | `:96`（读 48B）、`:103-139`（9 条边界检查）、`:180/:192`（源地址）、`:207-235`（CRC） | 消费者字段 |
| `sw\ddr\verify_image.py` | `:25-35`、`:88-90`、`:96-168` | 独立复算 |
| `sw\ddr\pack_image.ps1` | `:39`（AppRegion `0xFF000`）、`:67/:90`（无头拼接） | 旧格式与不兼容性 |
| `sw\ddr\link_ddr.ld` | `:62`（app ORIGIN `0x1000`）、`:69`（权重 `0x00100000`） | DDR 落点 |
| `D:\FPGA\mmt\mmt.xml` | `:204`（`mode=active`）、`:205`（`width=1`）、`:212`（`enable_crc_check=on`）、`:213`（压缩开） | 配置模式与位流校验 |
| `D:\Efinity\2026.1\pgm\bin\multi_image_merger.py` | `:110-138`（`-m/-t/-ifile/-iaddr/-o`） | 合并工具的用法 |
| `07_官方demo工程\Ti60f225_sc431hai2hdmi_v1\readme.txt` | `:75-76`、`:84-85`、`:90-102` | 厂商的烧写地址约定（0x0 / 0x380000）与操作步骤 |
| `_ddr_demo_ti60\outflow\soc_combine_hex.rpt` | `:6-7` | 厂商也是"位流→0x0、用户软件→0x380000" |
| `D:\FPGA\易灵思\参考资料\_目录说明.md` | `:67` | flash 8MB / GD25LQ64 |
| `...TI60F225I3-V4 DEMO板软硬件设计说明-260813-1.pdf.txt` | `:124`、`:640` | flash 8MB / GD25LQ64 |
