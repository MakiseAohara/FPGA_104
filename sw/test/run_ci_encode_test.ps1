# ============================================================
#  run_ci_encode_test.ps1 —— task-27 命令编码自测
#  编译 sw\test\ci_encode_test.c → 反汇编 → 逐字段核对自定义指令编码
#
#  核对内容：
#    · opcode 必须 = 0x0B（CUSTOM-0）
#    · 三条用例的 (func3, func7) 必须等于宏里写的值
#    · CFG_READ(0)/(1) 的 rs1 **运行值**：反汇编里紧挨指令前的 `li a1, N` 必须是 0 / 1
#  退出码：0 = 全过；非 0 = 有失败
# ============================================================
$ErrorActionPreference = 'Continue'

$sw   = Split-Path $PSScriptRoot -Parent          # D:\FPGA\mmt\sw
$tc   = "D:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$gcc  = "$tc\riscv-none-elf-gcc.exe"
$objd = "$tc\riscv-none-elf-objdump.exe"
$out  = Join-Path $env:TEMP "ci_encode_test"

New-Item -ItemType Directory -Force -Path $out | Out-Null
$src  = Join-Path $PSScriptRoot "ci_encode_test.c"
$elf  = Join-Path $out "ci_encode_test.elf"

Write-Output "=== 1. 编译（-march=rv32im -mabi=ilp32 -Os，与固件同配置）==="
# ⚠️ PowerShell 会把 `-Wl,--gc-sections` 里的逗号当参数分隔符 ⇒ 链接选项必须数组 splat
$CF = @("-march=rv32im", "-mabi=ilp32", "-Os", "-Wall", "-I", $sw)
$LF = @("-nostartfiles", "-Wl,--gc-sections", "-e", "main")
& $gcc @CF @LF $src -o $elf
if ($LASTEXITCODE -ne 0) { Write-Output "!! 编译失败"; exit 1 }
Write-Output "编译 OK"

Write-Output ""
Write-Output "=== 2. 反汇编（列出每条 custom-0 及其所在函数的相关 li）==="
$raw = & $objd -d $elf 2>$null

# xN → ABI 名（objdump 用 ABI 名打印 li）
$abi = @{5='t0';6='t1';7='t2';8='s0';9='s1';10='a0';11='a1';12='a2';13='a3';14='a4';15='a5'}

$curFunc = ""
$byFunc = @{}     # 函数名 → 该函数内所有指令文本
$rows = @()
foreach ($line in $raw) {
    if ($line -match "^([0-9a-f]{8}) <(.+)>:\s*$") {
        $curFunc = $Matches[2]
        if (-not $byFunc.ContainsKey($curFunc)) { $byFunc[$curFunc] = @() }
        continue
    }
    if ($line -match "^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s+(.*)$") {
        $hex = $Matches[1]; $txt = $Matches[2].Trim()
        if ($curFunc) { $byFunc[$curFunc] += $txt }
        $v = [Convert]::ToUInt32($hex,16)
        if (($v -band 0x7F) -eq 0x0B) {
            $rows += [pscustomobject]@{
                func=$curFunc; word=$hex
                op=($v -band 0x7F); f3=(($v -shr 12) -band 7); f7=(($v -shr 25) -band 0x7F)
                rd=(($v -shr 7) -band 0x1F); rs1=(($v -shr 15) -band 0x1F); rs2=(($v -shr 20) -band 0x1F)
            }
        }
    }
}
if ($rows.Count -eq 0) { Write-Output "!! 没找到 custom-0 指令"; exit 2 }
$rows | ForEach-Object { "  {0,-16} 0x{1} op=0x{2:X2} f3={3} f7={4} rd=x{5} rs1=x{6} rs2=x{7}" -f $_.func,$_.word,$_.op,$_.f3,$_.f7,$_.rd,$_.rs1,$_.rs2 }

# 该函数里把 <预期值> 装进 rs1 寄存器的 li（用 ABI 名匹配）
function Rs1LoadedWith($fn, $rs1num, $want) {
    $name = $abi[[int]$rs1num]
    if (-not $name) { return $false }
    foreach ($t in $byFunc[$fn]) {
        if ($t -match ("^li\s+" + $name + ",\s*(-?[0-9]+)$")) { if ([int]$Matches[1] -eq [int]$want) { return $true } }
    }
    return $false
}

Write-Output ""
Write-Output "=== 3. 逐项核对 ==="
$pass = 0; $fail = 0
function Chk($name, $got, $exp) {
    if ("$got" -eq "$exp") { Write-Output ("  PASS  {0} = {1}" -f $name, $got); $script:pass++ }
    else { Write-Output ("  FAIL  {0} = {1} (期望 {2})" -f $name, $got, $exp); $script:fail++ }
}
function Row($fn) { $rows | Where-Object { $_.func -eq $fn } | Select-Object -First 1 }

$c0 = Row "ci_case_cfg0"
$c1 = Row "ci_case_cfg1"
$cp = Row "ci_case_param"

Chk "cfg0 存在"            ([bool]$c0) $true
Chk "cfg0 opcode"          $c0.op 0x0B
Chk "cfg0 func3=1 (读配置)" $c0.f3 1
Chk "cfg0 func7=0"         $c0.f7 0
Chk "cfg0 rs1 运行值=0"     (Rs1LoadedWith "ci_case_cfg0" $c0.rs1 0) $true

Chk "cfg1 存在"            ([bool]$c1) $true
Chk "cfg1 func3=1"         $c1.f3 1
Chk "cfg1 func7=0"         $c1.f7 0
Chk "cfg1 rs1 运行值=1"     (Rs1LoadedWith "ci_case_cfg1" $c1.rs1 1) $true

Chk "param 存在"           ([bool]$cp) $true
Chk "param func3=3"        $cp.f3 3
Chk "param func7=2 (参数bank)" $cp.f7 2

# 生产宏 MMT_CI_R（自由分配）也要能编出来，且字段一致
$pr = Row "ci_case_prod"
Chk "生产宏 MMT_CI_R 存在"  ([bool]$pr) $true
Chk "生产宏 opcode"         $pr.op 0x0B
Chk "生产宏 func3=1"        $pr.f3 1
Chk "生产宏 func7=0"        $pr.f7 0
Write-Output "  （参考：厂商 tinyml_accel_get_uuid 的 .insn = 0x00a5150b，上面生产宏编出的是 0x$($pr.word)）"

Write-Output ""
if ($fail -eq 0) { Write-Output "=== 编码自测: PASS $pass / FAIL 0 ==="; exit 0 }
else             { Write-Output "=== 编码自测: PASS $pass / FAIL $fail ==="; exit 1 }
