# ==========================================================================
#  run_rv32_tests.ps1 -- build + run every RV32 bare-metal test under rv32sim
# --------------------------------------------------------------------------
#  This is the project's only way to actually *execute* firmware: there is no
#  host C compiler and no RISC-V emulator on this machine, and no board yet, so
#  "it compiles" used to be the strongest statement available.  rv32sim.py
#  turns that into "it produces these exact numbers".
#
#  Usage:  powershell -File sw\run_rv32_tests.ps1
# ==========================================================================
$ErrorActionPreference = 'Continue'

$sw  = $PSScriptRoot
$sim = 'D:\FPGA\易灵思\工作区\_工具\rv32sim.py'
$bld = Join-Path $sw 'build_rv32_test.ps1'

function Run-Test {
    param([string]$Name, [string]$Src, [string[]]$More, [string[]]$Inc,
          [switch]$Libm, [int]$Max = 50000000)
    # ★ 这里一律用 Write-Host 而不是 Write-Output：
    #   本函数被用在 `if (-not (Run-Test ...))` 这种**表达式上下文**里，
    #   PowerShell 会把函数的整个输出流吃掉当作表达式的值 —— 于是所有
    #   Write-Output 的行都不会显示（只有 return 的真假有效）。用 Write-Host
    #   直接写控制台，才不受影响。
    Write-Host ''
    Write-Host ('=' * 66)
    Write-Host ("== " + $Name)
    Write-Host ('=' * 66)

    if ($More -and $Libm -and $Inc) {
        $out = & $bld -Src $Src -Name $Name -SrcMore $More -Inc $Inc -UseLibm -UseNosys 2>&1
    } elseif ($More -and $Libm) {
        $out = & $bld -Src $Src -Name $Name -SrcMore $More -UseLibm -UseNosys 2>&1
    } elseif ($More -and $Inc) {
        $out = & $bld -Src $Src -Name $Name -SrcMore $More -Inc $Inc 2>&1
    } elseif ($More) {
        $out = & $bld -Src $Src -Name $Name -SrcMore $More 2>&1
    } elseif ($Inc) {
        $out = & $bld -Src $Src -Name $Name -Inc $Inc 2>&1
    } elseif ($Libm) {
        $out = & $bld -Src $Src -Name $Name -UseLibm -UseNosys 2>&1
    } else {
        $out = & $bld -Src $Src -Name $Name 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        $out | Select-Object -Last 14 | ForEach-Object { Write-Host $_ }
        Write-Host '[RESULT: BUILD FAILED]'
        return $false
    }
    $out | Select-String -Pattern '^\s+\d+\s+\d+\s+\d+|^bin :' | ForEach-Object { Write-Host $_.Line }

    $bin = Join-Path $sw "test\build\$Name.bin"
    $sym = Join-Path $sw "test\build\$Name.sym"
    python $sim --bin $bin --sym $sym --base 0 --entry-symbol _start --max $Max 2>$null |
        ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) { Write-Host '[RESULT: PASS]'; return $true }
    Write-Host '[RESULT: FAIL]'
    return $false
}

$fail = 0

# ★ 先把上次的产物清掉。否则某个测试**编译失败**时，目录里还留着上一次成功的
#   .bin，仿真器照样能跑它并给出绿灯 —— 本轮就真被这个坑了一次：t_mlx 的
#   -I 参数漏传导致编译失败，但旧 t_mlx.bin 还在，verify_mlx 一路"通过"。
Remove-Item (Join-Path $sw 'test\build') -Recurse -Force -ErrorAction SilentlyContinue

# 1) 指令集自检：操作数走 const 数组，避免常量折叠把测试变成空测试
if (-not (Run-Test -Name 't_alu' -Src 'test\t_alu.c')) { $fail++ }

# 2) 综合冒烟：算术 + xorshift 1000 轮 + 十进制打印
if (-not (Run-Test -Name 't_smoke' -Src 'test\t_smoke.c')) { $fail++ }

# 3) ★ 厂商 Melexis 库真跑：需要头文件搜索路径 + libm（sqrt）+ nosys
if (-not (Run-Test -Name 't_mlx' -Src 'test\t_mlx.c' -Inc @('lib\mlx90640') `
        -More @('lib\mlx90640\MLX90640_API.c', 'test\rv32_fastmath.c') -Libm -Max 400000000)) { $fail++ }

# 4) 逐项比对厂商库输出 vs Python 独立重算
Write-Output ''
Write-Output ('=' * 66)
Write-Output '== MLX90640 param verification (vendor C on RV32 vs Python)'
Write-Output ('=' * 66)
python (Join-Path $sw 'test\verify_mlx.py') 2>&1 |
    Select-String -Pattern 'MISMATCH|MISSING|PASSED|finite results|TO_|CALC_' | ForEach-Object { $_.Line }
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Output ''
Write-Output ('=' * 66)
if ($fail -eq 0) { Write-Output '=== RV32 TESTS: ALL PASSED ===' }
else             { Write-Output ("=== RV32 TESTS: " + $fail + " FAILED ===") }
exit $fail
