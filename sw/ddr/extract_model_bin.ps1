# ==========================================================================
#  extract_model_bin.ps1 — 把厂商 TinyML demo 里的「C 数组格式模型」还原成 .bin
# --------------------------------------------------------------------------
#  背景：Efinix 官方 TinyML 参考设计（mobilenetv1 person detect）的模型是
#        tensorflow.lite.util.convert_bytes_to_c_source() 生成的 C 数组：
#            D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\
#                embedded_sw\SapphireSoc\software\standalone\evsoc_tinyml_pdti8\
#                src\model\mobilenetv1_person_detect_model_data.cc
#        里面是一堆 0xNN 字节。DDR 里要放的是**纯数据流**（不是 ELF/hex），
#        所以本脚本把 0xNN 逐个还原成字节写成 .bin。
#
#  ⚠️ 这是**可复现的转换步骤**，不是"某天手工搞出来的二进制"。任何人重跑
#     本脚本都得到同样的 .bin（脚本末尾会自动复核字节数）。
#
#  用法：
#     powershell -File extract_model_bin.ps1                 # 用默认路径
#     powershell -File extract_model_bin.ps1 -Src <model.cc> -Out <x.bin>
#     powershell -File extract_model_bin.ps1 -Array mobilenetv1_person_detect_model_data
# ==========================================================================
param(
    [string]$Src = 'D:\FPGA\tinyml\tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\embedded_sw\SapphireSoc\software\standalone\evsoc_tinyml_pdti8\src\model\mobilenetv1_person_detect_model_data.cc',
    [string]$Out = '',
    [string]$Array = 'mobilenetv1_person_detect_model_data'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Out) {
    $dir = Join-Path $here 'weights'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Out = Join-Path $dir ($Array + '.bin')
}

if (-not (Test-Path $Src)) { throw "找不到模型源文件：$Src" }

Write-Output "=== extract_model_bin.ps1 ==="
Write-Output ("源      : {0}  ({1} bytes)" -f $Src, (Get-Item $Src).Length)
Write-Output ("数组名  : {0}" -f $Array)

$lines = [System.IO.File]::ReadAllLines($Src)

# 1) 找到数组声明的起点
$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match [regex]::Escape($Array) -and $lines[$i] -match '=' -and $lines[$i] -match '\{') { $startIdx = $i; break }
}
if ($startIdx -lt 0) { throw ("在源文件里找不到数组 '{0}' 的声明（形如 name[] = {{ ... }}）" -f $Array) }
Write-Output ("声明行  : {0}" -f ($startIdx + 1))

# 2) 找到匹配的 "};"
$endIdx = -1
for ($i = $startIdx; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\};') { $endIdx = $i; break }
}
if ($endIdx -lt 0) { throw "找不到数组结尾 '};'（文件格式与预期不符）" }
Write-Output ("结束行  : {0}" -f ($endIdx + 1))

# 3) 只在这个区间里抽 0xNN —— 避免把注释/别的数组里的十六进制误收进来
$bytes = New-Object 'System.Collections.Generic.List[byte]'
for ($i = $startIdx; $i -le $endIdx; $i++) {
    foreach ($m in [regex]::Matches($lines[$i], '0x([0-9a-fA-F]{2})')) {
        $bytes.Add([Convert]::ToByte($m.Groups[1].Value, 16))
    }
}
if ($bytes.Count -eq 0) { throw "区间内没抽到任何 0xNN 字节" }

$arr = $bytes.ToArray()
[System.IO.File]::WriteAllBytes($Out, $arr)

# 4) 复核：读回来比长度 + 抽样比对
$chk = [System.IO.File]::ReadAllBytes($Out)
$bad = 0
if ($chk.Length -ne $arr.Length) { $bad++ }
for ($k = 0; $k -lt $arr.Length; $k++) { if ($chk[$k] -ne $arr[$k]) { $bad++; break } }

Write-Output ("写出    : {0}" -f $Out)
Write-Output ("字节数  : {0} = {1:N1} KiB = {2:N3} MiB" -f $arr.Length, ($arr.Length/1KB), ($arr.Length/1MB))
if ($bad -eq 0) { Write-Output "复核    : OK（写出的文件与解析结果逐字节一致）" } else { throw "复核失败" }
Write-Output ""
Write-Output "拿去打包（放进 DDR 权重区，落点 = link_ddr.ld 的 mmt_weights_base = 0x00100000）："
Write-Output ("  powershell -File {0} -Weights {1}" -f (Join-Path $here 'build_ddr.ps1'), $Out)
