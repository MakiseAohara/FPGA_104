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
Write-Output "=== 2. 反汇编（列出每条 custom-0 及其前面一条 li）==="
$raw = & $objd -d $elf 2>$null

# 收集：函数名 → 该函数内所有指令
$curFunc = ""
$byFunc = @{}
$prevLi = ""      # 紧邻当前指令之前的一条 li a1, N
$rows = @()
foreach ($line in $raw) {
    if ($line -match "^([0-9a-f]{8}) <(.+)>:\s*$") { $curFunc = $Matches[2]; $prevLi = ""; continue }
    if ($line -match "^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s+(.*)$") {
        $hex = $Matches[1]; $txt = $Matches[2].Trim()
        $v = [Convert]::ToUInt32($hex,16)
        if (($v -band 0x7F) -eq 0x0B) {
            $rows += [pscustomobject]@{
                func=$curFunc; word=$hex
                op=($v -band 0x7F); f3=(($v -shr 12) -band 7); f7=(($v -shr 25) -band 0x7F)
                rd=(($v -shr 7) -band 0x1F); rs1=(($v -shr 15) -band 0x1F); rs2=(($v -shr 20) -band 0x1F)
                prevLi=$prevLi
            }
        }
        # 记下紧邻的 li（给下一条指令用）
        if ($txt -match "^li\s+([a-z0-9]+),\s*(-?[0-9]+)") { $prevLi = "$($Matches[1])=$($Matches[2])" } else { $prevLi = "" }
    }
}
if ($rows.Count -eq 0) { Write-Output "!! 没找到 custom-0 指令"; exit 2 }
$rows | ForEach-Object { "  {0,-16} 0x{1} f3={2} f7={3} rs1=x{4}({5}) rd=x{6}" -f $_.func,$_.word,$_.f3,$_.f7,$_.rs1,$_.prevLi,$_.rd }

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
Chk "cfg0 rs1 运行值=0"     ($c0.prevLi -replace '.*=','') 0

Chk "cfg1 存在"            ([bool]$c1) $true
Chk "cfg1 func3=1"         $c1.f3 1
Chk "cfg1 func7=0"         $c1.f7 0
Chk "cfg1 rs1 运行值=1"     ($c1.prevLi -replace '.*=','') 1

Chk "param 存在"           ([bool]$cp) $true
Chk "param func3=3"        $cp.f3 3
Chk "param func7=2 (参数bank)" $cp.f7 2

Write-Output ""
if ($fail -eq 0) { Write-Output "=== 编码自测: PASS $pass / FAIL 0 ==="; exit 0 }
else             { Write-Output "=== 编码自测: PASS $pass / FAIL $fail ==="; exit 1 }
