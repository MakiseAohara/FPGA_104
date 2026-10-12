# ==========================================================================
#  build_ddr.ps1 — 构建「固件跑在 DDR」的两级镜像
# --------------------------------------------------------------------------
#  产出（都在 sw\ddr\build\）：
#     loader.elf / loader.bin     阶段 1：跑在片内 RAM 0xF9000000 的搬运器
#     ddr_app.elf / ddr_app.bin   阶段 2：跑在 DDR 0x00001000 的应用
#     ddr_image.bin               烧进 flash 的完整镜像（头 + app + 权重）
#
#  用法：
#     powershell -File build_ddr.ps1
#     powershell -File build_ddr.ps1 -Weights D:\path\model.bin
#     powershell -File build_ddr.ps1 -FlashBase 0x380000
#     powershell -File build_ddr.ps1 -SkipImage          # 只编两个 elf/bin
#     powershell -File build_ddr.ps1 -AppSrc ..\main.c   # 换成真业务固件（可选）
#
#  ★ 本脚本**不跑 Efinity**（efx_map/efx_pnr 由 Lead 独占），只调 RISC-V 工具链。
#  ★ 构建完成后**不会**自动安装到 IP：装 loader 进片内 RAM 是
#       powershell -File ..\hex2soc.ps1 -Bin <sw>\ddr\build\loader.bin -Install
#     这一步会写 ip\sapphire_soc\**，属于 Lead 的动作，所以这里只打印命令、不执行。
# ==========================================================================
param(
    [string]$Weights  = '',
    [int]   $FlashBase = 0x380000,
    [string]$AppSrc   = '',
    [switch]$SkipImage
)

$ErrorActionPreference = 'Continue'   # 原生程序写 stderr 会被 PS 当异常，见 build_sw.ps1 的说明

$sw    = Split-Path -Parent $PSScriptRoot          # D:\FPGA\mmt\sw
$here  = $PSScriptRoot                             # D:\FPGA\mmt\sw\ddr
$tc    = 'D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
$gcc   = Join-Path $tc 'riscv-none-elf-gcc.exe'
$objcopy = Join-Path $tc 'riscv-none-elf-objcopy.exe'
$size  = Join-Path $tc 'riscv-none-elf-size.exe'
$nm    = Join-Path $tc 'riscv-none-elf-nm.exe'
$objdump = Join-Path $tc 'riscv-none-elf-objdump.exe'

if (-not (Test-Path $gcc)) { Write-Output "!! 找不到工具链: $gcc"; exit 1 }
if (-not $AppSrc) { $AppSrc = Join-Path $here 'ddr_app.c' }

$out = Join-Path $here 'build'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

# Sapphire：RV32IMA? 实际用的是 rv32im（--Fpu false、--Atomic false，见 soc_config:6,13）
$CFLAGS = @(
    '-march=rv32im', '-mabi=ilp32',
    '-Os', '-ffunction-sections', '-fdata-sections',
    '-Wall', '-Wextra',
    '-I', $sw, '-I', $here,
    ("-DMMT_FLASH_IMG_BASE=0x{0:X8}u" -f $FlashBase)
)
$COMMON_OBJS = @(
    (Join-Path $sw 'startup.S'),
    (Join-Path $sw 'uart.c')
)

function Build-One {
    param([string]$Name, [string]$LdScript, [string]$MainSrc, [string[]]$ExtraSources)
    Write-Output ""
    Write-Output "=================================================="
    Write-Output " 构建 $Name   (link: $(Split-Path $LdScript -Leaf))"
    Write-Output "=================================================="

    $odir = Join-Path $out $Name
    if (-not (Test-Path $odir)) { New-Item -ItemType Directory -Path $odir -Force | Out-Null }

    $objs = @()
    foreach ($src in ($COMMON_OBJS + $ExtraSources + @($MainSrc))) {
        $o = Join-Path $odir ((Split-Path $src -Leaf) -replace '\.[Sc]$', '.o')
        Write-Output ("  CC   {0}" -f (Split-Path $src -Leaf))
        & $gcc @CFLAGS -c $src -o $o
        if ($LASTEXITCODE -ne 0) { Write-Output ("!! 编译失败: {0}" -f $src); exit 1 }
        $objs += $o
    }

    $elf = Join-Path $out "$Name.elf"
    $bin = Join-Path $out "$Name.bin"
    $map = Join-Path $out "$Name.map"
    Write-Output "  LD   $Name.elf"
    $LDFLAGS = @(
        '-march=rv32im', '-mabi=ilp32',
        '-T', $LdScript,
        '-nostartfiles',
        '-Wl,--gc-sections',
        ("-Wl,-Map,$map")
    )
    & $gcc @LDFLAGS @objs -o $elf
    if ($LASTEXITCODE -ne 0) { Write-Output "!! 链接失败: $Name"; exit 1 }

    & $objcopy -O ihex   $elf (Join-Path $out "$Name.hex") | Out-Null
    & $objcopy -O binary $elf $bin

    Write-Output "  SIZE"
    & $size $elf
    Write-Output ("  bin  = {0} bytes" -f (Get-Item $bin).Length)

    Write-Output "  关键符号（必须落在预期的地址区间）:"
    & $nm -n $elf | Select-String -Pattern '^[0-9a-f]+\s+[A-Z]\s+(_start|_bss_start|_bss_end|_stack_bottom|_stack_top|_end)$' |
        ForEach-Object { "    " + $_.Line.Trim() }

    Write-Output "  段表（VMA 必须在预期区间，否则就是链接脚本错了）:"
    & $objdump -h $elf | Select-String -Pattern '^\s+\d+\s+\.' | ForEach-Object { "    " + $_.Line.Trim() }

    return @{ Elf = $elf; Bin = $bin }
}

# ---- 阶段 1：loader（片内 RAM 0xF9000000，32KB）----
$r1 = Build-One -Name 'loader' -LdScript (Join-Path $here 'link_loader.ld') -MainSrc (Join-Path $here 'loader.c') -ExtraSources @()

# ---- 阶段 2：DDR 应用（0x00001000）----
$r2 = Build-One -Name 'ddr_app' -LdScript (Join-Path $here 'link_ddr.ld') -MainSrc $AppSrc -ExtraSources @()

# ---- 静态守卫：地址必须对 ----
Write-Output ""
Write-Output "=================================================="
Write-Output " 地址守卫"
Write-Output "=================================================="
$OCRAM_BASE = [Convert]::ToInt64('F9000000', 16)      # 注意：PowerShell 里 0xF9000000 字面量会溢出成负数，必须用 ToInt64
$APP_BASE   = [Convert]::ToInt64('1000', 16)
$APP_LIMIT  = [Convert]::ToInt64('100000', 16)
$OCRAM_LIMIT= [Convert]::ToInt64('F9008000', 16)
$ldStart = (& $nm $r1.Elf | Select-String -Pattern '\sT\s+_start$').Line
if ($ldStart -match '^([0-9a-f]+)') {
    $v = [Convert]::ToInt64($Matches[1], 16)
    if ($v -ne $OCRAM_BASE) { Write-Output ("!! loader _start = 0x{0:X8}，必须是 0xF9000000（SoC 复位向量）" -f $v); exit 2 }
    Write-Output "  loader _start = 0xF9000000  OK（片内 RAM / 复位向量）"
}
$apStart = (& $nm $r2.Elf | Select-String -Pattern '\sT\s+_start$').Line
if ($apStart -match '^([0-9a-f]+)') {
    $v = [Convert]::ToInt64($Matches[1], 16)
    if ($v -lt $APP_BASE -or $v -ge $APP_LIMIT) { Write-Output ("!! app _start = 0x{0:X8}，必须落在 0x00001000..0x000FFFFF" -f $v); exit 2 }
    Write-Output ("  app    _start = 0x{0:X8}  OK（DDR app 区）" -f $v)
}
$ldBin = (Get-Item $r1.Bin).Length
if ($ldBin -gt 32768) { Write-Output ("!! loader.bin = {0} bytes > 片内 RAM 32768 —— hex2soc 会拒绝" -f $ldBin); exit 2 }
Write-Output ("  loader.bin = {0} bytes（片内 RAM 预算 32768，余 {1}）" -f $ldBin, (32768 - $ldBin))
$ldEnd = (& $nm $r1.Elf | Select-String -Pattern '\sB\s+_end$').Line
if ($ldEnd -match '^([0-9a-f]+)') {
    $v = [Convert]::ToInt64($Matches[1], 16)
    if ($v -gt $OCRAM_LIMIT) { Write-Output ("!! loader _end = 0x{0:X8} 越过片内 RAM 末尾 0xF9008000" -f $v); exit 2 }
    Write-Output ("  loader _end   = 0x{0:X8}  OK（片内 RAM 末尾 0xF9008000 之内）" -f $v)
}

# ---- 打包镜像 ----
if (-not $SkipImage) {
    Write-Output ""
    Write-Output "=================================================="
    Write-Output " 打包 flash 镜像"
    Write-Output "=================================================="
    $mk = Join-Path $here 'mkimage.ps1'
    if ($Weights) {
        & powershell -NoProfile -File $mk -App $r2.Bin -Weights $Weights -FlashBase $FlashBase
    } else {
        & powershell -NoProfile -File $mk -App $r2.Bin -FlashBase $FlashBase
    }
    if ($LASTEXITCODE -ne 0) { Write-Output "!! mkimage.ps1 失败"; exit 3 }
}

Write-Output ""
Write-Output "=================================================="
Write-Output " 下一步（需要 Lead / 上板，本脚本不自动做）"
Write-Output "=================================================="
Write-Output " 1) 先按 docs\DDR执行路径决策.md §3 把 SoC 的 SPI0 接到 flash 引脚（RTL + Interface Designer）"
Write-Output "    —— 不做这一步，loader 读不到 flash，会停在 stage 1 并打印 SPI 超时。"
Write-Output " 2) 重新综合布线生成位流（Lead 独占），位流大小必须 < $(('0x{0:X}' -f $FlashBase))"
Write-Output " 3) 把 loader 装进片内 RAM（会写 ip\sapphire_soc\**，Lead 执行）："
Write-Output ("      powershell -File {0} -Bin {1} -Install" -f (Join-Path $sw 'hex2soc.ps1'), $r1.Bin)
Write-Output "    （装完之后**必须重新跑 Efinity**，BRAM 初值才会更新；再烧位流）"
Write-Output (" 4) 用 Efinity Programmer 烧 flash：位流 -> 0x0，{0} -> {1}" -f (Join-Path $here 'build\ddr_image.bin'), ('0x{0:X}' -f $FlashBase))
Write-Output " 5) 开串口 115200 8N1：应先看到 stage-1 loader 的横幅与 CRC OK，再看到 stage-2 的 'running from DDR'"
