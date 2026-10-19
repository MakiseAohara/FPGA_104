# Efinity Debugger 连接问题 — 代码级解决方案

> 分析对象：Efinity 2026.1 (`D:\Efinity\2026.1`)
> 结论基于源码直读，行号可复核。
> 目标 profile：`v7_WBH1\debug.json`（vio0 + la0）

---

## 1. 结论：**能连**。用户只是找错了页面。

**一句话**：`Configure` 按钮不在 VIO 页，而在 **Run 页**；且它默认是 **disabled**，必须先到 **Program 页** 点 **USB Target 右边的刷新按钮** 才会变成可点。

### 1.1 三条硬证据

**证据 A —— 主窗口是 4 个 tab，按钮分散在不同页**

`Ui_DebuggerMainWindow.py:340/355/371/384` 定义了 4 个 tab 的标题：

```python
340: self.tabWidget.setTabText(... "Profile")
355: self.tabWidget.setTabText(... "Instructions")
371: self.tabWidget.setTabText(... "Program")
384: self.tabWidget.setTabText(... "Run")
```

- `label_usb_target`（**"USB Target"**）→ `parent=self.groupBox_program` → 属于 **Program 页**
  （`Ui_DebuggerMainWindow.py:93,97`）
- `pb_config_jtag`（**"Configure"**）→ `parent=self.widget_debug_target` → `groupBox_run` → 属于 **Run 页**
  （`Ui_DebuggerMainWindow.py:212,257,268`），`groupBox_run.setTitle("Configuration")`（:372）

> 用户在 vio0 tab 里找这两个控件，所以"找不到" —— 它们根本不在那个页面。

**证据 B —— `Configure` 默认被禁用**

`gui.py:3150`（初始化阶段）：

```python
self.ui.pb_config_jtag.setEnabled(False)
```

**证据 C —— 只有 `on_debug_refresh` 会把它打开（真正的开关）**

`gui.py:3961-3977`（`on_debug_refresh` 函数体）：

```python
dev_list = self.pgm_win.pgm_params.resolved_usb
if not dev_list:
    self.ui.pb_config_jtag.setEnabled(False)
    self.warning(self.MSG_W005)              # 'No target device available for JTAG configuration.'
else:
    if self._profile is None:
        self.ui.pb_config_jtag.setEnabled(False)
        self.warning(self.MSG_W006)          # 'Debug profile not available. ...'
    else:
        self.ui.pb_config_jtag.setEnabled(True)     # ← 两个条件都满足才可用
        self.info(self.MSG_I002, color=True)
```

`MSG_I002`（`gui.py:3057`）原文：

```
'Select the correct USB JTAG device and click Connect Debugger to start debugging.'
```

注意：**官方叫它 "Connect Debugger"，界面按钮文字却是 "Configure"**（`Ui_DebuggerMainWindow.py:380`
`setText("Configure")`，tooltip 仍是 `"Start Capture"` :379）。文档与界面不一致，这是用户困惑的第二个来源。

### 1.2 逐步操作（照做即可）

> 前提：`File → Import Profile` 载入 `v7_WBH1\debug.json` 已完成（用户已成功，`_profile` 非空）。

| 步骤 | 位置 | 动作 | 代码依据 |
|---|---|---|---|
| 1 | 顶部 tab **Program** | 看 `USB Target` 行的下拉框，确认里面有你正在用的编程器 | `Ui_DebuggerMainWindow.py:97,105` |
| 2 | **Program 页** | 点 `USB Target` 下拉框**右边的刷新图标按钮**（`redo.svg`，无文字） | `gui.py:3248` `pb_refresh_usb_target.clicked.connect(self.on_debug_refresh)` |
| 3 | 同上 | 刷新后下拉框里**选中目标**（会打印 `No Board Profile Selected`，见 §2，无害） | `gui.py:3251` → `on_usb_target_changed` |
| 4 | 顶部 tab **Run** | 进 `Configuration` 分组框，此时 **Configure** 按钮应已可点 | `Ui_DebuggerMainWindow.py:372,380` |
| 5 | **Run 页** | 点 **Configure**（= 官方文档的 Connect Debugger） | `gui.py:3249` `pb_config_jtag.pressed.connect(self.on_configure)` |
| 6 | Console | 应依次出现 `Connecting to URL: ...`，然后 `post_jtag_config` 生效，vio0/la0 变为可操作 | `gui.py:4136,4195` |

**判定成功的标志**：`gui.py:4136` 会打印

```
Connecting to URL: <你的编程器 url>
```

若卡在 `on_configure` 的提前返回（`gui.py:4124-4126`）：

```python
if not self._profile:
    self.console.write_error_msg('Debug profile must be imported before connecting debugger!')
    return
```
说明 profile 没真正加载 —— 用 §4 的 `--profile_file` 启动方式可绕过。

### 1.3 `on_configure` 内可能踩的两个坑（代码依据）

- `gui.py:4132` `validate_co_debug_support()`：只有当设了 `EFX_OPENOCD_JTAG_ENABLE=1` 或
  `EFX_CODEBUG_MODE=True`（**Shared 模式**）且 idcode ∈ {0x00000000, 0x00000001, 0x00210a79} 才报错。
  普通独占模式直接返回 True，**不影响**。
- `gui.py:4138-4140` 用的是 `cb_chip_num` 与 `get_jtag_params(...)`；`get_current_debug_target()`
  若 `pgm_win.devices` 为空会提示
  `"ERROR: Cannot detect JTAG devices. Please import JCF file or check JTAG connection and then refresh."`
  —— 注意这句话本身给了 **两条** 出路：import JCF **或** 检查 JTAG 后刷新。
  **既然 `flash_vendor.ps1` 能读到 Device ID，JTAG 链是通的，走"刷新"这条路即可，JCF 不是必需的。**

---

## 2. `No Board Profile Selected` 是否无害？——**完全无害**

**代码依据**：该字符串在 debugger 全部代码里**一次都不出现**；唯一来源是
`D:\Efinity\2026.1\pgm\bin\efx_pgm\main_window.py:1611-1615`：

```python
1611: self.pgm_params.board_profile = self.get_target_board_profile()
1612: if self.pgm_params.board_profile:
1613:     self.console.write(f"Board Profile Selected: {self.pgm_params.board_profile.name}")
1614: else:
1615:     self.console.write(f"No Board Profile Selected")
```

含义：你选中的 USB 编程器**没有匹配到"板卡配置文件"**（board profile 是一个可选的板卡描述 XML，
用于预填器件/闪存参数）。没有它，只是不会自动填参数，**不妨碍 JTAG 连接和 VIO 读写**。

**反过来说，这行字是个好消息**：它由 `on_usb_target_changed` 路径打印（`gui.py:3485-3486`
→ `pgm_win.on_usb_target_changed` → 上述函数），**说明用户已经成功选中过 USB target**，
第 3 步其实已经做到了，只差 §1.2 的第 2 步（刷新）+ 第 5 步（在 Run 页点 Configure）。

---

## 3. `Import JCF` 弹窗全黑 —— **可绕过，且不该需要它**

- 黑窗是 Qt 渲染问题（该对话框用 `.ui` 动态加载 + 自定义样式，在部分 Windows/显卡环境下字体与调色板未初始化即绘制 → 全黑）。
- **它对本任务不是必经步骤**：`get_current_debug_target()` 的提示明确写着
  "Please import JCF file **or** check JTAG connection and then refresh"。
- **绕过办法（推荐）**：完全不用 JCF 对话框，改为
  1. Program 页点刷新（`on_debug_refresh`）让 `pgm_win.devices` 通过 **auto-detect** 填充；
  2. 或在启动时用 `--profile_file` 直接带 profile（§4），避免走任何 File 菜单。
- 若一定要 JCF 的内容，也可以**手工提供 xml 路径**给 `pgm_win.xml`（`validate_co_debug_support`
  中 `if self.xml: devices = self.hw_backend.parse_jcf(self.xml, ...)`），即用命令行/配置注入，
  不经过那个会黑的对话框。

**结论：黑窗无解（Qt 侧不修），但完全不阻塞 —— 绕过即可。**

---

## 4. 【最有价值】命令行 / 免 GUI 方案

### 4.1 先记一个重要事实：`efx_dbg` **没有 headless VIO CLI**

`gui.py:4449-4474` 的 `main()` 无条件创建 `QApplication` 并 `qasync.run` ——
`--cls` 的 choices 只有 `['DbgGui']`（`gui.py:4273-4276`），所以 `python -m efx_dbg.gui`
**永远起 GUI**。参数只支持 `--project_home / --profile_file / --no_save / --device / --family / --netdb`。

**但有两个真正可用的命令行入口：**

### 4.2 入口一：`--profile_file` 启动（绕开所有 File 菜单，直击 GUI 毛病）

```bat
set EFINITY_HOME=D:/Efinity/2026.1
set PYTHONHOME=D:\Efinity\2026.1\python311
set EFXPT_HOME=D:/Efinity/2026.1/pt
set EFXPGM_HOME=D:/Efinity/2026.1/pgm
set EFXDBG_HOME=D:/Efinity/2026.1/debugger
set EFXIPM_HOME=D:/Efinity/2026.1/ipm
set EFXSVF_HOME=D:/Efinity/2026.1/debugger/svf_player
set EFXSERDESDBG_HOME=D:/Efinity/2026.1/debugger/serdes_debug_tool
set EFINITY_USER_DIR=C:/Users/18915/AppData/Local/efinity
set EFINITY_USER_DIR_INI=C:/Users/18915/AppData/Local/efinity/user_dir.ini
set PATH=D:\Efinity\2026.1\python311\bin;D:\Efinity\2026.1\bin;D:\Efinity\2026.1\pgm\bin;D:\Efinity\2026.1\debugger\bin;D:\Efinity\2026.1\scripts;%PATH%

D:\Efinity\2026.1\debugger\bin\efinity_dbg.bat ^
  --project_home "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WBH1" ^
  --profile_file "D:\FPGA\易灵思\工作区\07_官方demo工程\v7_WBH1\debug.json" ^
  --no_save
```

依据：
- `efinity_dbg.bat` 末尾 `-m efx_dbg.gui %*` —— **参数原样透传**。
- `gui.py:3280-3295`：`--profile_file` 若是绝对路径直接采用，并在启动时
  `on_startup(self.PROFILE_FILE)`；`gui.py:3588-3591` → `import_profile_from_file()` ——
  **等于自动完成 File→Import Profile**。
- `gui.py:3297-3298` 只有传了非空 `--profile_file` 才更新窗口标题，可用于确认参数生效。
- **务必加 `--no_save`**：`gui.py:3616` `if setting_changed and not self._args.no_save:` 才会回写
  `debug.json`（`--no_save` 是 `action='store_false'`，默认会写）。加它可防止误改 profile。

### 4.3 入口二：`efx_dbg.shell` —— 真正的 CLI，能直接读写 VIO

`D:\Efinity\2026.1\debugger\bin\efx_dbg\shell.py` 是一个 `cmd.Cmd` REPL
（`shell.py:93 class DbgShell(cmd.Cmd)`，`shell.py:473-475 def main(): DbgShell().cmdloop()`），
模块头注释自称 "Interactive CLI module (deprecating) for Efinix Debuggers"（:12）—— **能用**。

**内置命令（`shell.py` 行号）**：

| 命令 | 行号 | 作用 |
|---|---|---|
| `list_usb_devices` | 134 | 列编程器 |
| `config_jtag` | 213 | 配置 JTAG session |
| `list_configured_jtag` | 236 | 列已配置 session |
| `unconfig_jtag` | 241 | 断开 |
| `add_debug_profile` | 259 | 加载 debug profile |
| `list_debug_profile` | 279 | 列 profile |
| `auto_config` | 284 | 自动完成前几步 |
| `start_debug` | 328 | 进入 curses 版 VIO/LA 界面 |
| `shell` | 127 | **执行任意 Python 表达式** ← 关键 |

启动（同一套环境变量）：

```bat
set PYTHONPATH=D:\Efinity\2026.1\debugger\bin;D:\Efinity\2026.1\pgm\bin
D:\Efinity\2026.1\bin\python3.bat -m efx_dbg.shell
```

> 注：`start_debug` 用 `curses`（`shell.py:362 draw_vio(stdscr, ...)`），在原生 Windows cmd
> 下 curses 支持较差；**建议不要用 `start_debug`**，而是用 `shell` 命令直接调 API（下节）。

### 4.4 【强烈推荐】不用 GUI 也不用 curses：直接调 `JtagManager` 写 VIO

`VIO` 的底层原语（`D:\Efinity\2026.1\debugger\bin\efx_dbg\jtag.py`）：

```python
2330: def read_vio(self, dbg_sesh: DebugSession, core_name: str) -> List[Optional[BitSequence]]
2334: def write_vio(self, dbg_sesh: DebugSession, core_name: str) -> None
2338: def set_vio_probe_out(self, dbg_sesh: DebugSession, core_name: str, probe_out: List[BitSequence]) -> None
2343: def get_vio_property(self, dbg_sesh: DebugSession, core_name: str, attr: str) -> List[Optional[BitSequence]]
```

`shell.py:431-439` 给出的**官方写入三段式**（GUI 按 0/1 键时就是这么干的）：

```python
seq = probe_out[pid].sequence()          # 取第 pid 个探针的比特序列
bid = stop_x[pid] - 1 - cursor_x         # 定位要改的 bit
seq[bid] = 1 if k == ord('1') else 0     # 改值
probe_out[pid] = BitSequence(seq)        # 回写序列
JtagManager().set_vio_probe_out(url, core_name, probe_out)   # ① 设置探针值
JtagManager().write_vio(url, core_name)                      # ② 下发到 FPGA
```

调用路径参考 `adapter.py:40`：

```python
async def ...(self):
    ... AsyncTask(self._dbg_api.vio_write, self._dbg_sesh_id, self._core_name, probe_outs)
```

即：`vio_write(dbg_sesh_id, core_name, probe_outs)`。

**VBH4 的具体探针含义（本次要调的目标）**：

| 探针 | 位宽 | 信号 | 目标值 | 数值 |
|---|---|---|---|---|
| `PROBE_OUT0` | 16 | R 增益 | `0x158` | 344 = 1.344× |
| `PROBE_OUT1` | 16 | G 增益 | `0x130` | 304 = 1.1875× |
| `PROBE_OUT2` | 16 | B 增益 | `0x1D0` | 464 = 1.813× |
| `PROBE_OUT3` | 1 | gamma_sel | `0x0` | 0 |

> 注意 `debug_top.v:102-105` 已把这些值烧成**上电初值**，所以 **BWH4 烧录后即使不连 Debugger，
> 增益也已经是目标值** —— Debugger 只在需要"运行中改值对比"时才必需。这大幅降低了任务 2 的紧迫性。

结论一句话：**能连（GUI 走 §1.2 五步）；即使 GUI 有毛病，也能用 §4.3/§4.4 纯命令行读写 VIO，
完全绕开 Qt 渲染问题。**

---

## 4.5 【易踩】WBH1 与 WBH4 的 Debug Core UUID **不同**，profile 不能混用

对照 `debug.json` 实测：

| 核心 | WBH1 uuid | WBH4 uuid |
|---|---|---|
| `vio0` | `af5ad2e95cab41469fae6c93c1cfc5cd` | `d2d3643a7f1e49a3a7f48b242e104fdd` |
| `la0`  | `cf5d5db3e5c44a318184993664e4fb8a` | `40fc40c15a7b4e5392113defb86d2a4c` |

`v7_WBH4\debug_top.v:97` 的实例 UUID 为 `128'hd2d3643a7f1e49a3a7f48b242e104fdd`，
与 **WBH4 的 debug.json 一致**。

**因此：烧完 WBH4 位流后，Debugger 必须加载 `v7_WBH4\debug.json`，绝不能再用 `v7_WBH1\debug.json`。**
否则 `on_configure` 会抛 `EfxDbgMisMatchCoreUUIDError`（`gui.py:4148-4163`），报
`Debug Core UUID mismatch detected on ...` 并直接 `on_unconfig(force_quit=True)` 断开。

> 用户此前在 GUI 里导入的是 `v7_WBH1\debug.json` —— 若当前板上跑的是 WBH4，
> 那次连接**必然失败**，与 GUI 渲染无关。这是第二个独立故障点。

另注：`v7_WBH4\debug.json` 里探针 `init` 仍是旧值（`0x118/0xff/0x15e`），而
`debug_top.v:102-105` 的实际上电初值是 `0x158/0x130/0x1D0`。profile 的 `init` 只是 GUI 侧
显示/默认值，**硬件真实初值以 `debug_top.v` 的 `PROBE_OUTx_INIT_VAL` 为准**；
连上后以 GUI 读回值为准，不必为这个差异改 profile。

---

## 5. 附：`Import JCF` 之外的 UI 一致性坑

| 官方文档/消息里的名字 | 界面上实际的名字 | 出处 |
|---|---|---|
| Connect Debugger | **Configure** | `gui.py:3057` vs `Ui_DebuggerMainWindow.py:380` |
| Start Capture | Configure（tooltip 未改） | `Ui_DebuggerMainWindow.py:379` |
| Debug Target | `Configuration` 分组框 | `Ui_DebuggerMainWindow.py:372` |

用户按文档找 "Connect Debugger" 是找不到的 —— 那是 `MSG_I002` 里的措辞。
