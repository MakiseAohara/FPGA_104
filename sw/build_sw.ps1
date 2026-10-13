# ============================================================
#  RISC-V 固件构建脚本
#  用法: .\build_sw.ps1
#
#  产出: build\mmt_fw.elf   可调试的 ELF
#        build\mmt_fw.hex   Intel HEX（要载入 SoC 的格式还要再确认，见文末）
#        build\mmt_fw.bin   纯二进制
#        build\mmt_fw.map   链接映射（看各段占多少 RAM）
#
#  工具链：xpack riscv-none-elf-gcc（免安装 zip，解压即用）
#    下载 https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases
#    本机 D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1
#
#  ★ 注意 $ErrorActionPreference 必须是 Continue：
#    原生程序把 warning 写到 stderr 时，PowerShell 会抛 NativeCommandError，
#    设成 'Stop' 会导致"明明链接成功却报失败"。正确做法是 Continue + 显式查 $LASTEXITCODE。
# ============================================================
$ErrorActionPreference = 'Continue'

$sw      = $PSScriptRoot
$tc      = "D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$gcc     = "$tc\riscv-none-elf-gcc.exe"
$objcopy = "$tc\riscv-none-elf-objcopy.exe"
$size    = "$tc\riscv-none-elf-size.exe"

if (-not (Test-Path $gcc)) {
    Write-Output "!! 找不到工具链: $gcc"
    Write-Output "   下载 https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases"
    Write-Output "   解压到 D:\riscv\ 即可（免安装、免管理员）"
    exit 1
}

$out = Join-Path $sw "build"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }

# Sapphire：单核 RV32，无 FPU（settings.json 里 FPU=0）→ rv32im + 软件浮点
$CFLAGS = @(
    "-march=rv32im", "-mabi=ilp32",
    "-Os", "-ffunction-sections", "-fdata-sections",
    "-Wall", "-Wextra",
    "-I", $sw
)
$LDFLAGS = @(
    "-march=rv32im", "-mabi=ilp32",
    "-T", (Join-Path $sw "link.ld"),
    "-nostartfiles",
    "-Wl,--gc-sections",
    "-Wl,-Map,$out\mmt_fw.map"
)

# ---- 1. 汇编启动代码 ----
Write-Output "=== 编译汇编启动代码 startup.S ==="
& $gcc @CFLAGS -c (Join-Path $sw "startup.S") -o "$out\startup.o"
if ($LASTEXITCODE -ne 0) { Write-Output "!! startup.S 编译失败"; exit 1 }

# ---- 2. 编译 C ----
$CSRC = @("main.c", "uart.c", "mmt_tinyml.c")
Write-Output "=== 编译 C: $($CSRC -join ', ') ==="
foreach ($src in $CSRC) {
    & $gcc @CFLAGS -c (Join-Path $sw $src) -o (Join-Path $out ($src -replace '\.c$', '.o'))
    if ($LASTEXITCODE -ne 0) { Write-Output "!! $src 编译失败"; exit 1 }
}

# ---- 3. 链接 ----
$OBJS = @("$out\startup.o") + ($CSRC | ForEach-Object { Join-Path $out ($_ -replace '\.c$', '.o') })
Write-Output "=== 链接 ==="
& $gcc @LDFLAGS @OBJS -o "$out\mmt_fw.elf"
if ($LASTEXITCODE -ne 0) { Write-Output "!! 链接失败"; exit 1 }

# ---- 4. 生成镜像 ----
Write-Output "=== 生成镜像 ==="
& $objcopy -O ihex   "$out\mmt_fw.elf" "$out\mmt_fw.hex"
& $objcopy -O binary "$out\mmt_fw.elf" "$out\mmt_fw.bin"

Write-Output ""
Write-Output "=== 段大小 ==="
& $size "$out\mmt_fw.elf"

Write-Output ""
Get-ChildItem $out -File | Select-Object Name, Length | Format-Table -AutoSize

Write-Output ""
Write-Output "============================================================"
Write-Output "产出在 $out"
Write-Output ""
Write-Output "下一步：把固件装进 SoC 的片内 RAM（格式已经完全搞清楚，不需要官方 EFX_HEX 工具）："
Write-Output "   powershell -File hex2soc.ps1            # 转换 + 往返校验"
Write-Output "   powershell -File hex2soc.ps1 -Install   # 顺便装进 IP（会覆盖原厂 demo 固件）"
Write-Output ""
Write-Output "   原理：SoC 网表 sapphire_soc.v 用 \$readmemb 直接吃 4 个文本文件"
Write-Output "         EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{0..3}.bin"
Write-Output "         每个 2048 行、每行 8 个 '0'/'1' 字符；地址 (4*i+N) 的字节 -> symbolN[i]"
Write-Output "   注意：装完必须重新综合整个工程，BRAM 初值才会更新。"
Write-Output "   原厂镜像备份在 ip\sapphire_soc\_vendor_ram_init_backup\"
Write-Output "============================================================"
