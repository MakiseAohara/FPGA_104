# ============================================================================
#  v7_build_abc2.ps1 —— 修正版：每个版本 map+pnr 后【立即】用正确的 efx_pgm 参数出位流
#  根因：tools\efinity\build.ps1 里 efx_pgm 用了 --work_dir（efx_pgm 不认）⇒ 位流永远不生成。
#        改用 --project-xml/--source/--dest（我们工程一直有效的写法）。
# ============================================================================
$ErrorActionPreference = 'Continue'
$W   = 'D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work'
$TOP = "$W\rtl\ti60f225_oob_top.v"
$efi = 'D:/Efinity/2026.1'
$outRoot = 'D:\FPGA\mmt\out\evidence\v7_abc'
New-Item -ItemType Directory -Force -Path $outRoot,"$W\patches" | Out-Null

$env:EFINITY_HOME = $efi
$env:EFINITY_USER_DIR_INI = ($env:LOCALAPPDATA -replace '\\','/')+'/efinity/user_dir.ini'
$env:EFINITY_USER_DIR     = ($env:LOCALAPPDATA -replace '\\','/')+'/efinity'
$env:EFXPT_HOME="$efi/pt"; $env:EFXPGM_HOME="$efi/pgm"; $env:EFXDBG_HOME="$efi/debugger"; $env:EFXIPM_HOME="$efi/ipm"
$env:PYTHONHOME="$efi/python311"
$env:QT_PLUGIN_PATH="$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH="$efi/python311/platforms"
$env:PATH="$efi/python311/bin;$efi/bin;$efi/scripts;"+$env:PATH

$orig = Get-Content $TOP -Raw

function Build($tag) {
    Write-Host "`n########## 构建 $tag  $(Get-Date -Format 'HH:mm:ss') ##########"
    $o = Join-Path $outRoot $tag
    New-Item -ItemType Directory -Force -Path $o | Out-Null
    $t0=Get-Date
    # map
    $a=@('--prj',"$W\ti60f225_oob.xml",'--project','ti60f225_oob','--root','ti60f225_oob_top',
         '--device','Ti60F225','--family','Titanium',
         '--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008',
         '--work-dir',"$W\work_syn",'--output-dir',"$W\out",'--I',$W)
    foreach($mm in [regex]::Matches((Get-Content "$W\ti60f225_oob.xml" -Raw),'<efx:param\s+name="include"\s+value="([^"]+)"')){
        $d=Join-Path $W ($mm.Groups[1].Value -replace '/','\'); if(Test-Path $d){ $a+=@('--I',$d) } }
    $p=Start-Process -FilePath "$efi/bin/efx_map.exe" -ArgumentList $a -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
        -RedirectStandardOutput "$o\map.log" -RedirectStandardError "$o\map.err.log"
    Write-Host "  efx_map 退出码=$($p.ExitCode)"
    if($p.ExitCode -ne 0){ Write-Host "  !! map 失败"; return }
    # pnr（照 build.ps1）
    $sdc = Join-Path $W 'ti60f225_oob.sdc'
    $pnr=@('--prj',"$W\ti60f225_oob.xml",'--circuit','ti60f225_oob','--family','Titanium','--device','Ti60F225',
           '--operating_conditions','I3','--pack','--place','--route',
           '--vdb_file',"$W\out\ti60f225_oob.vdb",'--use_vdb_file','on',
           '--place_file',"$W\out\ti60f225_oob.place",
           '--route_file',"$W\out\ti60f225_oob.troutingtraces",
           '--optimization_level','TIMING_3','--seed','0','--placer_effort_level','2',
           '--max_threads','-1','--beneficial_skew','on','--print_critical_path','10',
           '--work_dir',"$W\work_pnr",'--output_dir',"$W\out",'--timing_analysis','on')
    if(Test-Path $sdc){ $pnr += @('--sdc_file',$sdc) }
    $p=Start-Process -FilePath "$efi/bin/efx_pnr.exe" -ArgumentList $pnr -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
        -RedirectStandardOutput "$o\pnr.log" -RedirectStandardError "$o\pnr.err.log"
    Write-Host "  efx_pnr 退出码=$($p.ExitCode)  $([math]::Round(((Get-Date)-$t0).TotalSeconds))s"
    if($p.ExitCode -ne 0){ Write-Host "  !! pnr 失败"; Get-Content "$o\pnr.err.log" -EA 0 | Select-Object -First 5; return }
    Select-String -Path "$o\pnr.log" -Pattern 'XLRs:|Memory Blocks:|DSP Blocks:' | Select-Object -First 3 | ForEach-Object { "    " + $_.Line.Trim() }
    # bitgen（正确参数）
    $lbf = Get-ChildItem "$W\work_pnr" -Filter '*.lbf' -EA 0 | Select-Object -First 1
    if(-not $lbf){ Write-Host "  !! 无 lbf"; return }
    Copy-Item $lbf.FullName "$o\ti60f225_oob.lbf" -Force
    $bitOut = Join-Path $o "v7_$tag.bit"
    $pg=@('--project-xml',"$W\ti60f225_oob.xml",'--source',"$o\ti60f225_oob.lbf",'--dest',$bitOut,
          '--family','Titanium','--device','Ti60F225','--mode','active','--width','1')
    $p=Start-Process -FilePath "$efi/bin/efx_pgm.exe" -ArgumentList $pg -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
        -RedirectStandardOutput "$o\pgm.log" -RedirectStandardError "$o\pgm.err.log"
    Write-Host "  efx_pgm 退出码=$($p.ExitCode)"
    if(Test-Path $bitOut){
        $bi=Get-Item $bitOut
        Write-Host ("  ✅ {0}  {1:N0} B  {2}" -f $bitOut,$bi.Length,$bi.LastWriteTime)
        Write-Host ("     SHA256 {0}" -f (Get-FileHash $bitOut -Algorithm SHA256).Hash)
    } else { Write-Host "  !! 位流未生成"; Get-Content "$o\pgm.log" -EA 0 | Select-String 'ERROR' | Select-Object -First 3 }
    Copy-Item $TOP "$o\ti60f225_oob_top.v" -Force
}

function Patch($tag) {
    $d = Compare-Object (Get-Content "$outRoot\ti60f225_oob_top.orig.v") (Get-Content $TOP)
    $lines = @("# v7_$tag patch  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $d | ForEach-Object { $lines += ("{0} {1}" -f $(if($_.SideIndicator -eq '=>'){'+'}else{'-'}), $_.InputObject.TrimEnd()) }
    Set-Content "$W\patches\v7_$tag.patch" $lines -Encoding UTF8
    Write-Host ("  补丁 patches\v7_$tag.patch ({0} 行)" -f $d.Count)
}

if(-not (Test-Path "$outRoot\ti60f225_oob_top.orig.v")){ Set-Content "$outRoot\ti60f225_oob_top.orig.v" $orig -NoNewline }

# 基线
Build 'base'

# A
Set-Content $TOP ($orig `
  -replace '(?m)^(\s*)\.r_gain\s+\(\|r_gain\?\s*r_gain:255\s*\),', '$1.r_gain       (16''d255),' `
  -replace '(?m)^(\s*)\.g_gain\s+\(\|g_gain\?\s*g_gain:255\s*\),', '$1.g_gain       (16''d255),' `
  -replace '(?m)^(\s*)\.b_gain\s+\(\|b_gain\?\s*b_gain:255\s*\),', '$1.b_gain       (16''d255),') -NoNewline
Build 'A'; Patch 'A'

# B = A + R/B 直连
$curA = Get-Content $TOP -Raw
Set-Content $TOP ($curA `
  -replace ': hdmi_tx_rdata \s*\),//\(hdmi_tx_rdata \),', ': hdmi_tx_bdata 	),//(hdmi_tx_rdata ),' `
  -replace ': hdmi_tx_bdata \s*\),//\(hdmi_tx_bdata \),', ': hdmi_tx_rdata 	),//(hdmi_tx_bdata ),') -NoNewline
Build 'B'; Patch 'B'

# C = 原增益 + R/B 直连
Set-Content $TOP ($orig `
  -replace ': hdmi_tx_rdata \s*\),//\(hdmi_tx_rdata \),', ': hdmi_tx_bdata 	),//(hdmi_tx_rdata ),' `
  -replace ': hdmi_tx_bdata \s*\),//\(hdmi_tx_bdata \),', ': hdmi_tx_rdata 	),//(hdmi_tx_bdata ),') -NoNewline
Build 'C'; Patch 'C'

Set-Content $TOP $orig -NoNewline
Write-Host "`n=== 全部结束 $(Get-Date -Format 'HH:mm:ss')；v7_work 已恢复 ==="
Get-ChildItem $outRoot -Recurse -File -Include *.bit | ForEach-Object { "  {0}  {1:N0} B  {2}" -f $_.Name,$_.Length,(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
