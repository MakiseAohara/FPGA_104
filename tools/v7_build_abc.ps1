# ============================================================================
#  v7_build_abc.ps1 —— 以 v7_work 为底，编出 基线 + A + B + C 四个版本
#  指挥官指令 #27。只在 v7_work 里改，补丁留痕到 patches\。
#  复用 tools\efinity\build.ps1（已含正确的 efx_pnr/efx_pgm 参数）。
#  不烧录、不改原目录、不推 GitHub。
# ============================================================================
$ErrorActionPreference = 'Continue'
$W   = 'D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work'
$TOP = "$W\rtl\ti60f225_oob_top.v"
$BUILD = 'D:\FPGA\mmt\tools\efinity\build.ps1'
$outRoot = 'D:\FPGA\mmt\out\evidence\v7_abc'
New-Item -ItemType Directory -Force -Path $outRoot,"$W\patches" | Out-Null

$orig = Get-Content $TOP -Raw
Set-Content "$outRoot\ti60f225_oob_top.orig.v" $orig -NoNewline   # 原始快照

function Build($tag) {
    Write-Host "`n########## 构建 $tag  $(Get-Date -Format 'HH:mm:ss') ##########"
    $t0 = Get-Date
    & powershell -NoProfile -ExecutionPolicy Bypass -File $BUILD `
        -Xml "$W\ti60f225_oob.xml" -Top ti60f225_oob_top -Bitstream 2>&1 |
        Where-Object { $_ -match 'efx_map 退出码|efx_pnr 退出码|efx_pgm 退出码|XLRs|Memory Blocks|DSP Blocks|EFX_LUT4|EFX_FF|ERROR|失败|位流|place.rpt' } |
        ForEach-Object { "  $_" }
    Write-Host ("  耗时 {0:N0}s" -f ((Get-Date)-$t0).TotalSeconds)
    # 收集产物
    $o = Join-Path $outRoot $tag
    New-Item -ItemType Directory -Force -Path $o | Out-Null
    foreach($f in @("$W\out\ti60f225_oob.bit","$W\out2\ti60f225_oob.bit")){ if(Test-Path $f){ Copy-Item $f "$o\v7_$tag.bit" -Force } }
    Get-ChildItem "$W\out" -Filter '*.bit' -EA 0 | ForEach-Object { Copy-Item $_.FullName "$o\v7_$tag.bit" -Force }
    $b = Get-Item "$o\v7_$tag.bit" -EA 0
    if($b){
        Write-Host ("  ✅ 位流: {0}  {1:N0} B  {2}" -f $b.FullName,$b.Length,$b.LastWriteTime)
        Write-Host ("     SHA256 {0}" -f (Get-FileHash $b.FullName -Algorithm SHA256).Hash)
    } else { Write-Host "  ⚠️ 未找到位流产物（检查 work_pnr\*.lbf）" }
    Copy-Item "$W\rtl\ti60f225_oob_top.v" "$outRoot\$tag`_ti60f225_oob_top.v" -Force
}

function Patch($tag) {
    $a = Get-Content "$outRoot\ti60f225_oob_top.orig.v"
    $b = Get-Content $TOP
    $d = Compare-Object $a $b
    $lines = @("# v7_$tag patch  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "# 相对 ti60f225_oob_top 原始版本：$(($d|Where-Object{$_.SideIndicator -eq '=>'}).Count) 行新增 / $(($d|Where-Object{$_.SideIndicator -eq '<='}).Count) 行删除")
    $d | ForEach-Object { $lines += ("{0} {1}" -f $(if($_.SideIndicator -eq '=>'){'+'}else{'-'}), $_.InputObject.TrimEnd()) }
    Set-Content "$W\patches\v7_$tag.patch" $lines -Encoding UTF8
    Write-Host ("  补丁: patches\v7_$tag.patch  ({0} 行差异)" -f $d.Count)
}

# ---------- 基线（不改）----------
Build 'base'

# ---------- A：增益固定 255 ----------
Write-Host "`n=== 应用 A：增益固定 r=g=b=255 ==="
Set-Content $TOP ($orig `
  -replace '(?m)^(\s*)\.r_gain\s+\(\|r_gain\?\s*r_gain:255\s*\),', '$1.r_gain       (16''d255),' `
  -replace '(?m)^(\s*)\.g_gain\s+\(\|g_gain\?\s*g_gain:255\s*\),', '$1.g_gain       (16''d255),' `
  -replace '(?m)^(\s*)\.b_gain\s+\(\|b_gain\?\s*b_gain:255\s*\),', '$1.b_gain       (16''d255),') -NoNewline
Select-String -Path $TOP -Pattern '\.r_gain|\.g_gain|\.b_gain' | Select-Object -First 3 | ForEach-Object { "  → " + $_.Line.Trim() }
Build 'A'
Patch 'A'

# ---------- B：A + R/B 直连 ----------
Write-Host "`n=== 应用 B：A + R/B 直连 ==="
$curA = Get-Content $TOP -Raw
Set-Content $TOP ($curA `
  -replace ': hdmi_tx_rdata \s*\),//\(hdmi_tx_rdata \),', ': hdmi_tx_bdata 	),//(hdmi_tx_rdata ),' `
  -replace ': hdmi_tx_bdata \s*\),//\(hdmi_tx_bdata \),', ': hdmi_tx_rdata 	),//(hdmi_tx_bdata ),') -NoNewline
Select-String -Path $TOP -Pattern '\.i_bdata|\.i_rdata' | Select-Object -First 2 | ForEach-Object { "  → " + $_.Line.Trim() }
Build 'B'
Patch 'B'

# ---------- C：原增益 + R/B 直连 ----------
Write-Host "`n=== 应用 C：原增益 + R/B 直连 ==="
Set-Content $TOP ($orig `
  -replace ': hdmi_tx_rdata \s*\),//\(hdmi_tx_rdata \),', ': hdmi_tx_bdata 	),//(hdmi_tx_rdata ),' `
  -replace ': hdmi_tx_bdata \s*\),//\(hdmi_tx_bdata \),', ': hdmi_tx_rdata 	),//(hdmi_tx_bdata ),') -NoNewline
Select-String -Path $TOP -Pattern '\.i_bdata|\.i_rdata' | Select-Object -First 2 | ForEach-Object { "  → " + $_.Line.Trim() }
Build 'C'
Patch 'C'

# ---------- 恢复 ----------
Set-Content $TOP $orig -NoNewline
Write-Host "`n=== v7_work 已恢复原文件；全部构建结束 $(Get-Date -Format 'HH:mm:ss') ==="
Write-Host "产物目录: $outRoot"
Get-ChildItem $outRoot -Recurse -File -Include *.bit | ForEach-Object { "  {0}  {1:N0} B  {2}" -f $_.Name,$_.Length,(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
