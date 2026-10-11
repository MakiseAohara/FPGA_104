# ============================================================
#  RTL 功能仿真脚本（Icarus Verilog）
#  用法:
#    .\sim.ps1 -Tb sim\tb_i2c_master.v -Src rtl\mmt\sensors\mmt_i2c_master.v [-Top tb_i2c_master]
#    .\sim.ps1 -Tb x.v -Src @('a.v','b.v') -Vcd        # 顺便导出波形
#
#  ── 环境说明（踩过的坑，别重复踩）────────────────────────────
#  iverilog 11.0 是用 micromamba 从 conda-forge 装的（装到 D:\iverilog，
#  不碰系统、不弹 UAC）。它跑不起来有三个原因，都要处理：
#    1) 缺 DLL：PATH 里必须同时有 Library\bin 和 Library\mingw-w64\bin
#    2) conda 版没带 zlib1.dll / libbz2-1.dll（只有 zlib.dll / libbz2.dll），
#       system.vpi 的导入表认的是前者 —— 已各建一个同名副本解决
#    3) 少了任何一条，vvp 只会报含糊的
#       "failed to open using dlopen() ... 找不到指定的模块"，不说是哪个 DLL
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Tb,
    [Parameter(Mandatory=$true)][string[]]$Src,
    [string]$Top,
    [string]$Out = "sim\_run\a.out",
    [string[]]$IncDir,
    [switch]$Vcd,
    [switch]$KeepQuiet
)

$ivRoot = "D:\iverilog"
$ivBin  = "$ivRoot\Library\bin"
$ivMg   = "$ivRoot\Library\mingw-w64\bin"

if (-not (Test-Path "$ivBin\iverilog.exe")) {
    Write-Output "!! 找不到 $ivBin\iverilog.exe —— 仿真器没装好。"
    Write-Output "   安装方法（免安装、免管理员）:"
    Write-Output "     micromamba create -y -p D:\iverilog -c conda-forge iverilog bzip2"
    exit 1
}
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$args = @('-g2012', '-o', $Out)
foreach ($d in $IncDir) { $args += @('-I', $d) }
$args += $Src
$args += $Tb

Write-Output "=== 编译 ==="
Write-Output ("iverilog " + ($args -join ' '))
& "$ivBin\iverilog.exe" @args 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { Write-Output "[编译失败 exit=$LASTEXITCODE]"; exit $LASTEXITCODE }
Write-Output "[编译 OK]"

Write-Output "=== 仿真 ==="
$vargs = @()
if ($Vcd) { $vargs += '-vcd' }
& "$ivBin\vvp.exe" @vargs $Out 2>&1 | ForEach-Object { $_ }
$rc = $LASTEXITCODE
Write-Output "[vvp exit=$rc]"
exit $rc
