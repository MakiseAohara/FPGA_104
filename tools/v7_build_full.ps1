# ============================================================================
#  v7_build_full.ps1 —— 用【正确的整流程】重编 v7 base（v7_work2）
#  整流程（见 06_Efinity验证\run_full_flow.ps1 头部注释）：
#    [1] efx_map + 无约束 PnR  →  out\<d>.vdb
#    [2] efx_run.bat <d> --prj -f interface  →  outflow\<d>.interface.csv
#    [3] filter_interface.ps1  →  out\<d>.interface.csv
#    [4] efx_pnr --sync_file out\<d>.interface.csv（带引脚+时钟约束）→ lbf
#    [5] efx_pgm --dest *.hex → bit
# ============================================================================
$ErrorActionPreference = 'Continue'
$V7SRC = 'D:\FPGA\易灵思\工作区\07_官方demo工程\Ti60f225_sc431hai2hdmi_v7\Ti60f225_sc431hai2hdmi_v7'
$W     = 'D:\FPGA\易灵思\工作区\07_官方demo工程\v7_work2'
$TOP   = 'ti60f225_oob_top'
$NAME  = 'ti60f225_oob'
$efi   = 'D:/Efinity/2026.1'
$OUTROOT = 'D:\FPGA\mmt\out\evidence\v7_full'

New-Item -ItemType Directory -Force -Path $OUTROOT | Out-Null
if(Test-Path $W){ Remove-Item $W -Recurse -Force }
New-Item -ItemType Directory -Force -Path $W | Out-Null
Copy-Item "$V7SRC\*" $W -Recurse -Force
Write-Host "=== v7_work2 已建立（$((Get-ChildItem $W -Recurse -File | Measure-Object).Count) 文件，未加任何补丁）==="

$env:EFINITY_HOME=$efi
$env:EFINITY_USER_DIR_INI=($env:LOCALAPPDATA -replace '\\','/')+'/efinity/user_dir.ini'
$env:EFINITY_USER_DIR=($env:LOCALAPPDATA -replace '\\','/')+'/efinity'
$env:EFXPT_HOME="$efi/pt"; $env:EFXPGM_HOME="$efi/pgm"; $env:EFXDBG_HOME="$efi/debugger"; $env:EFXIPM_HOME="$efi/ipm"
$env:PYTHONHOME="$efi/python311"
$env:QT_PLUGIN_PATH="$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH="$efi/python311/platforms"
$env:PATH="$efi/python311/bin;$efi/bin;$efi/scripts;"+$env:PATH

$out = Join-Path $W 'out'; $wsyn = Join-Path $W 'work_syn'; $wpnr = Join-Path $W 'work_pnr'
New-Item -ItemType Directory -Force -Path $out,$wsyn,$wpnr | Out-Null
$xml = Join-Path $W "$NAME.xml"
$sdc = Join-Path $W "$NAME.sdc"
$log = Join-Path $OUTROOT 'build_full.log'
Set-Content $log '' -Encoding UTF8
function Log($s){ Write-Host $s; Add-Content $log $s }

# ---------- [1] map ----------
Log "`n########## [1/5] efx_map ##########"
$a=@('--prj',$xml,'--project',$NAME,'--root',$TOP,'--device','Ti60F225','--family','Titanium',
     '--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008','--work-dir',$wsyn,'--output-dir',$out,'--I',$W)
foreach($mm in [regex]::Matches((Get-Content $xml -Raw),'<efx:param\s+name="include"\s+value="([^"]+)"')){
    $d=Join-Path $W ($mm.Groups[1].Value -replace '/','\'); if(Test-Path $d){ $a+=@('--I',$d) } }
$p=Start-Process -FilePath "$efi/bin/efx_map.exe" -ArgumentList $a -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
   -RedirectStandardOutput (Join-Path $OUTROOT 'map.log') -RedirectStandardError (Join-Path $OUTROOT 'map.err.log')
Log "  efx_map 退出码=$($p.ExitCode)"
if($p.ExitCode -ne 0){ Log "  !! map 失败"; exit 1 }

# ---------- [2] 无约束 PnR（产 vdb + lbf 初版）----------
Log "`n########## [2/5] efx_pnr（无 sync_file，产 vdb）##########"
$pnr=@('--prj',$xml,'--circuit',$NAME,'--family','Titanium','--device','Ti60F225',
       '--operating_conditions','I3','--pack','--place','--route',
       '--vdb_file',(Join-Path $out "$NAME.vdb"),'--use_vdb_file','on',
       '--place_file',(Join-Path $out "$NAME.place"),'--route_file',(Join-Path $out "$NAME.troutingtraces"),
       '--optimization_level','TIMING_3','--seed','0','--placer_effort_level','2',
       '--max_threads','-1','--beneficial_skew','on','--print_critical_path','10',
       '--work_dir',$wpnr,'--output_dir',$out,'--timing_analysis','on')
if(Test-Path $sdc){ $pnr += @('--sdc_file',$sdc) }
$p=Start-Process -FilePath "$efi/bin/efx_pnr.exe" -ArgumentList $pnr -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
   -RedirectStandardOutput (Join-Path $OUTROOT 'pnr1.log') -RedirectStandardError (Join-Path $OUTROOT 'pnr1.err.log')
Log "  efx_pnr#1 退出码=$($p.ExitCode)"
if(-not (Test-Path (Join-Path $out "$NAME.vdb"))){ Log "  !! 无 vdb"; exit 1 }

# ---------- [3] Interface Designer（efx_run -f interface）----------
Log "`n########## [3/5] efx_run -f interface ##########"
$flow = Join-Path $W 'outflow'
Remove-Item $flow -Recurse -Force -EA 0
Push-Location $W
& "$efi/bin/efx_run.bat" $NAME --prj -f interface 2>&1 | ForEach-Object { Log "  $_" }
Pop-Location
$rawCsv = Join-Path $flow "$NAME.interface.csv"
if(Test-Path $rawCsv){ Log "  ✅ interface.csv 生成: $rawCsv" } else { Log "  !! interface.csv 未生成"; exit 2 }

# ---------- [4] 剪枝 ----------
Log "`n########## [4/5] filter_interface ##########"
& powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\FPGA\易灵思\工作区\06_Efinity验证\filter_interface.ps1' `
   -Top (Join-Path $W "rtl\$TOP.v") -In $rawCsv -Out (Join-Path $out "$NAME.interface.csv") 2>&1 | ForEach-Object { Log "  $_" }

# ---------- [5] 带 sync_file 的 PnR ----------
Log "`n########## [5/5] efx_pnr --sync_file（带引脚+时钟约束）##########"
$pnr2 = @('--prj',$xml,'--circuit',$NAME,'--family','Titanium','--device','Ti60F225',
       '--operating_conditions','I3','--pack','--place','--route',
       '--vdb_file',(Join-Path $out "$NAME.vdb"),'--use_vdb_file','on',
       '--place_file',(Join-Path $out "$NAME.place"),'--route_file',(Join-Path $out "$NAME.troutingtraces"),
       '--optimization_level','TIMING_3','--seed','0','--placer_effort_level','2',
       '--max_threads','-1','--beneficial_skew','on','--print_critical_path','10',
       '--work_dir',$wpnr,'--output_dir',$out,'--timing_analysis','on',
       '--sync_file',(Join-Path $out "$NAME.interface.csv"))
if(Test-Path $sdc){ $pnr2 += @('--sdc_file',$sdc) }
$p=Start-Process -FilePath "$efi/bin/efx_pnr.exe" -ArgumentList $pnr2 -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
   -RedirectStandardOutput (Join-Path $OUTROOT 'pnr2.log') -RedirectStandardError (Join-Path $OUTROOT 'pnr2.err.log')
Log "  efx_pnr#2 退出码=$($p.ExitCode)"
$r2 = Get-Content (Join-Path $OUTROOT 'pnr2.log') -EA 0
Log "  --- SDC 警告统计 ---"
$n1 = ($r2 | Select-String 'No valid pin\(s\) found for clock').Count
$n2 = ($r2 | Select-String 'No clocks matched').Count
Log "    'No valid pin(s) found for clock' = $n1"
Log "    'No clocks matched'              = $n2"
Log "  --- 资源 ---"
$r2 | Select-String 'XLRs:|Memory Blocks:|DSP Blocks:' | Select-Object -First 3 | ForEach-Object { Log ("    " + $_.Line.Trim()) }
Log "  --- 时序 ---"
$r2 | Select-String 'Slack|WNS|TNS|negative' | Select-Object -Last 6 | ForEach-Object { Log ("    " + $_.Line.Trim()) }

# ---------- bitgen ----------
Log "`n########## bitgen ##########"
$lbf = Get-ChildItem $wpnr -Filter '*.lbf' -EA 0 | Select-Object -First 1
if($lbf){
    $hexBit = Join-Path $OUTROOT 'v7_full.hex'
    $p=Start-Process -FilePath "$efi/bin/efx_pgm.exe" -ArgumentList @('--project-xml',$xml,'--source',$lbf.FullName,'--dest',$hexBit,
        '--family','Titanium','--device','Ti60F225','--mode','active','--width','1') `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $W `
        -RedirectStandardOutput (Join-Path $OUTROOT 'pgm.log') -RedirectStandardError (Join-Path $OUTROOT 'pgm.err.log')
    Log "  efx_pgm 退出码=$($p.ExitCode)"
    $bit = Join-Path $OUTROOT 'v7_full.bit'
    if(Test-Path $bit){
        Log ("  ✅ {0:N0} B  SHA256 {1}" -f (Get-Item $bit).Length,(Get-FileHash $bit -Algorithm SHA256).Hash)
    } else { Log "  !! 位流未生成"; Get-Content (Join-Path $OUTROOT 'pgm.log') -EA 0 | Select-String 'ERROR|Missing' | Select-Object -First 3 | ForEach-Object { Log ("    " + $_.Line.Trim()) } }
} else { Log "  !! 无 lbf" }
Log "`n=== 完成 $(Get-Date -Format 'HH:mm:ss') ==="
