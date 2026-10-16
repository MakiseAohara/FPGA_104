# ============================================================================
#  check_expected.ps1 —— 薄包装，调用 tools\check_expected.py
#  （指挥官 #15 第二条：改成一遍流式读入，2 分钟内扫完；实测 1 秒）
#
#  退出码：0 全过 / 1 有不过项 / 2 参数或文件错误
#  注意：本脚本【没有任何跳过开关】。要放行必须由指挥官批示，改 expected_ffs.txt
#        或 victim_whitelist.txt（两者都要写在证据文件里）。
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Netlist,
    [string]$Baseline = 'D:\FPGA\mmt\out\mmt.map.ice0.postsyn.v',
    [string]$Expected = 'D:\FPGA\mmt\tools\expected_ffs.txt',
    [string]$Whitelist = 'D:\FPGA\mmt\tools\victim_whitelist.txt'
)
& python -I (Join-Path $PSScriptRoot 'check_expected.py') $Netlist `
    --baseline $Baseline --expected $Expected --whitelist $Whitelist
exit $LASTEXITCODE
