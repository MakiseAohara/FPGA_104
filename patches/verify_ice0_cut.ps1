# ============================================================================
#  verify_ice0_cut.ps1 —— 「ice=0 + 剪 TinyML」这一轮的构建后判定器
#
#  为什么需要它：
#    这一轮改的是「综合器行为」，成败不能靠"看起来编译过了"判，
#    而是靠 ① 容量是否装得下 ② 写通道关键信号有没有被折成常量。
#    两者都只需要读报告、不需要上板 —— 先把离线判据钉死，再去占板子。
#
#  用法（在工程根 D:\FPGA\mmt 下）：
#    powershell -File tools\verify_ice0_cut.ps1
#    powershell -File tools\verify_ice0_cut.ps1 -Root D:\FPGA\mmt
#
#  退出码：0 = 全部通过（可以进 bitgen + 上板）
#          1 = 有不过项（先别上板）
#          2 = 报告缺失（构建没跑完 / 路径不对）
# ============================================================================
param(
    [string]$Root = '',
    [int]$MaxXlr = 60800,
    [int]$MaxMem = 256
)
$ErrorActionPreference = 'Continue'

if (-not $Root) {
    $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    if (-not (Test-Path (Join-Path $Root 'mmt.xml'))) { $Root = 'D:\FPGA\mmt' }
}
$out   = Join-Path $Root 'out'
$place = Join-Path $out 'mmt.place.rpt'
$map   = Join-Path $out 'mmt.map.rpt'
$pnr   = Join-Path $out 'efx_pnr.log'

Write-Host "==================== verify_ice0_cut ===================="
Write-Host "工程 : $Root"

$fails = New-Object System.Collections.ArrayList
function Fail($msg) { [void]$fails.Add($msg); Write-Host "  FAIL  $msg" -ForegroundColor Red }
function Pass($msg) { Write-Host "  PASS  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow }

# ---------- 0. 报告存在性 ----------
if (-not (Test-Path $place)) { Write-Host "!! 缺 $place （构建没跑到 PnR？）" -ForegroundColor Red; exit 2 }
if (-not (Test-Path $map))   { Write-Host "!! 缺 $map" -ForegroundColor Red; exit 2 }

# ---------- 1. 容量：XLR / Memory Blocks ----------
Write-Host ""
Write-Host "--- (1) 容量判据 ---"
$txt = [System.IO.File]::ReadAllText($place)
$mXlr = [regex]::Match($txt, 'XLRs:\s*(\d+)\s*/\s*(\d+)')
$mMem = [regex]::Match($txt, 'Memory Blocks:\s*(\d+)\s*/\s*(\d+)')
if (-not $mXlr.Success) {
    Fail "place.rpt 里找不到 'XLRs:' 行"
} else {
    $xlr    = [int]$mXlr.Groups[1].Value
    $xlrMax = [int]$mXlr.Groups[2].Value
    $pct    = [math]::Round(100.0 * $xlr / $xlrMax, 2)
    Write-Host ("  XLRs = {0} / {1}  ({2}%)" -f $xlr, $xlrMax, $pct)
    if ($xlr -le $MaxXlr) { Pass "XLR 未超上限（余量 $($MaxXlr - $xlr)）" }
    else                  { Fail "XLR 超限：$xlr > $MaxXlr" }
    if ($pct -ge 95.0)    { Warn "XLR 利用率 $pct% 达到 95% 以上，时序风险高" }
}
if (-not $mMem.Success) {
    Fail "place.rpt 里找不到 'Memory Blocks:' 行"
} else {
    $mem    = [int]$mMem.Groups[1].Value
    $memMax = [int]$mMem.Groups[2].Value
    Write-Host ("  Memory Blocks = {0} / {1}  ({2}%)" -f $mem, $memMax, [math]::Round(100.0*$mem/$memMax,2))
    if ($mem -le $MaxMem) { Pass "BRAM 未超上限（余量 $($MaxMem - $mem)）" }
    else                  { Fail "BRAM 超限：$mem > $MaxMem" }
    if (($MaxMem - $mem) -lt 4) { Warn "BRAM 只剩 $($MaxMem - $mem) 块：写 FIFO 若回来会爆" }
}

# ---------- 2. TinyML 是否真的不在网表里 ----------
Write-Host ""
Write-Host "--- (2) TinyML 剪除生效 ---"
$pnrTxt = ''
if (Test-Path $pnr) { $pnrTxt = [System.IO.File]::ReadAllText($pnr) }
$hit = ([regex]::Matches($pnrTxt, 'u_tinyml_accel')).Count
Write-Host "  efx_pnr.log 中 u_tinyml_accel 次数 = $hit （期望 0）"
if ($hit -eq 0) { Pass "TinyML 未进网表" }
else { Fail 'u_tinyml_accel 仍在网表 —— 宏没生效（检查 mmt_top.v 顶部 // `define 行）' }

# ---------- 3. 写通道是否被折成常量（核心判据） ----------
Write-Host ""
Write-Host "--- (3) 写通道折叠判据（本轮成败关键）---"
$mapTxt = [System.IO.File]::ReadAllText($map)
foreach ($sig in @('fb_awvalid', 'fb_wvalid', 'fb_wlast')) {
    $mm = [regex]::Matches($mapTxt, [regex]::Escape($sig) + '[^\r\n]*optimized\s+to\s+(0|1)')
    if ($mm.Count -gt 0) {
        Fail "$sig 被常量折叠（$($mm.Count) 处）—— 写通道仍死，别上板"
        $mm | Select-Object -First 2 | ForEach-Object { Write-Host ("        " + $_.Value.Trim()) }
    } else {
        Pass "$sig 未被折成常量"
    }
}
$fsmPats = @('\bstate\[[01]\][^\r\n]*optimized', '\bsync_r[012]\b[^\r\n]*optimized')
foreach ($pat in $fsmPats) {
    $mm = [regex]::Matches($mapTxt, $pat)
    if ($mm.Count -gt 0) {
        Fail "写 FSM 相关信号被折叠（$($mm.Count) 处）"
        $mm | Select-Object -First 3 | ForEach-Object { Write-Host ("        " + $_.Value.Trim()) }
    } else {
        Pass "写 FSM（state/sync_r*）未被折叠"
    }
}
$fifo = [regex]::Matches($mapTxt, 'u_wr_fifo[^\r\n]*(RADDR[^\r\n]*disabled|RDATA disconnected)')
if ($fifo.Count -gt 0) { Fail "u_wr_fifo 读端口仍被 disabled（写 FIFO 没回来）" }
else                   { Pass "u_wr_fifo 读端口未被裁剪" }

# ---------- 4. 时序负 slack 提醒 ----------
Write-Host ""
Write-Host "--- (4) 时序余量（提示，不判失败）---"
$tim = Join-Path $out 'mmt.timing.rpt'
if (Test-Path $tim) {
    $t = [System.IO.File]::ReadAllText($tim)
    $mins = [regex]::Matches($t, '-\d+\.\d+')
    if ($mins.Count -gt 0) {
        Write-Host "  timing.rpt 里出现 $($mins.Count) 个负数（疑似负 slack），请人工核对" -ForegroundColor Yellow
    } else {
        Pass "timing.rpt 未见负 slack"
    }
} else {
    Warn "没有 mmt.timing.rpt，跳过"
}

# ---------- 总结 ----------
Write-Host ""
Write-Host "==================== 结论 ===================="
if ($fails.Count -eq 0) {
    Write-Host "全部通过 —— 可以 bitgen + 上板。" -ForegroundColor Green
    Write-Host "上板第一眼：dbg= 最高字节应为路标常量，且 [WR] AW/W 开始涨。" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "$($fails.Count) 项未过：" -ForegroundColor Red
    $fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "先别上板，按文档 (5) 失败分支处置。" -ForegroundColor Yellow
    exit 1
}
