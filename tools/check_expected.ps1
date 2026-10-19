# ============================================================================
#  check_expected.ps1 —— 薄包装，调用 tools\check_expected.py
#
#  ★ 2026-10-18 修：本脚本在 build_mmt.ps1 里被调用时，PATH 头部是 Efinity 自带的
#    python311\bin，且 PYTHONHOME 指向 Efinity 安装目录 ⇒ `python -I` 会报
#      Fatal Python error: init_fs_encoding / ModuleNotFoundError: No module named 'encodings'
#    于是门禁"看起来没过"，实际是解释器起不来。
#    修法：调用前把 PATH 里的 Efinity 段剔掉、清掉 PYTHONHOME/PYTHONPATH，
#          用完在 finally 里恢复，不污染调用者的环境。
#
#  退出码：0 全过 / 1 有不过项 / 2 参数或文件错误
#  本脚本没有跳过开关。要放行必须由指挥官批示，改 expected_ffs.txt 或 victim_whitelist.txt。
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Netlist,
    [string]$Baseline  = 'D:\FPGA\mmt\tools\baseline\mmt.map.ice0.frozen.postsyn.v',
    [string]$Expected  = 'D:\FPGA\mmt\tools\expected_ffs.txt',
    [string]$Whitelist = 'D:\FPGA\mmt\tools\victim_whitelist.txt',
    [string]$Scope     = 'D:\FPGA\mmt\tools\gate_scope.txt'
)

$__oldPath = $env:PATH
$__oldHome = $env:PYTHONHOME
$__oldPyPath = $env:PYTHONPATH
try {
    $env:PYTHONHOME = $null
    $env:PYTHONPATH = $null
    $env:PATH = (($__oldPath -split ';' | Where-Object { $_ -and ($_ -notmatch 'Efinity') }) -join ';')

    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { Write-Host "  FAIL 找不到可用的 python（PATH 里已剔除 Efinity）" -ForegroundColor Red; exit 2 }
    Write-Host "  (门禁用 python: $py)"

    & $py -I (Join-Path $PSScriptRoot 'check_expected.py') $Netlist `
        --baseline $Baseline --expected $Expected --whitelist $Whitelist --scope $Scope
    $code = $LASTEXITCODE
}
finally {
    $env:PATH = $__oldPath
    if ($null -ne $__oldHome) { $env:PYTHONHOME = $__oldHome } else { Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue }
    if ($null -ne $__oldPyPath) { $env:PYTHONPATH = $__oldPyPath } else { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
}
exit $code
