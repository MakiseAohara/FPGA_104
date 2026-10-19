# ============================================================================
#  v7_flow.ps1 <工作目录> <输出名> —— v7 的 5 步正确整流程（指挥官 #29/#30 验证过）
#  步骤：[1] efx_map → [2] efx_pnr(无 sync_file,产 vdb) → [3] efx_run -f interface
#        → [4] filter_interface → [5] efx_pnr --sync_file → bitgen
#  验收：No valid pin(s) 警告 0 条；打印 timing hold 违例；bit 的 sha256/大小
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [Parameter(Mandatory=$true)][string]$Tag
)
$ErrorActionPreference = 'Continue'
$NAME = 'ti60f225_oob'; $TOP = 'ti60f225_oob_top'
$efi  = 'D:/Efinity/2026.1'
$OUT  = "D:\FPGA\mmt\out\evidence\v7_abc2\$Tag"
New-Item -ItemType Directory -Force -Path $OUT | Out-Null

$env:EFINITY_HOME=$efi
$env:EFINITY_USER_DIR_INI=($env:LOCALAPPDATA -replace '\\','/')+'/efinity/user_dir.ini'
$env:EFINITY_USER_DIR=($env:LOCALAPPDATA -replace '\\','/')+'/efinity'
$env:EFXPT_HOME="$efi/pt"; $env:EFXPGM_HOME="$efi/pgm"; $env:EFXDBG_HOME="$efi/debugger"; $env:EFXIPM_HOME="$efi/ipm"
$env:PYTHONHOME="$efi/python311"
$env:QT_PLUGIN_PATH="$efi/bin"; $env:QT_QPA_PLATFORM_PLUGIN_PATH="$efi/python311/platforms"
$env:PATH="$efi/python311/bin;$efi/bin;$efi/scripts;"+$env:PATH

$xml = Join-Path $Work "$NAME.xml"; $sdc = Join-Path $Work "$NAME.sdc"
$out = Join-Path $Work 'out'; $wsyn = Join-Path $Work 'work_syn'; $wpnr = Join-Path $Work 'work_pnr'
New-Item -ItemType Directory -Force -Path $out,$wsyn,$wpnr | Out-Null
$log = Join-Path $OUT 'build.log'; Set-Content $log '' -Encoding UTF8
function Log($s){ Write-Host $s; Add-Content $log $s }

Log "===== [$Tag] 5 步整流程  $(Get-Date -Format 'HH:mm:ss') ====="

# [1] map
$a=@('--prj',$xml,'--project',$NAME,'--root',$TOP,'--device','Ti60F225','--family','Titanium',
     '--veri_option','verilog_mode=sv_09,vhdl_mode=vhdl_2008','--work-dir',$wsyn,'--output-dir',$out,'--I',$Work)
foreach($mm in [regex]::Matches((Get-Content $xml -Raw),'<efx:param\s+name="include"\s+value="([^"]+)"')){
    $d=Join-Path $Work ($mm.Groups[1].Value -replace '/','\'); if(Test-Path $d){ $a+=@('--I',$d) } }
$p=Start-Process -FilePath "$efi/bin/efx_map.exe" -ArgumentList $a -NoNewWindow -Wait -PassThru -WorkingDirectory $Work `
   -RedirectStandardOutput (Join-Path $OUT 'map.log') -RedirectStandardError (Join-Path $OUT 'map.err.log')
Log "[1] efx_map 退出码=$($p.ExitCode)"; if($p.ExitCode -ne 0){ exit 1 }

# [2] pnr 无 sync_file
$pnr=@('--prj',$xml,'--circuit',$NAME,'--family','Titanium','--device','Ti60F225',
       '--operating_conditions','I3','--pack','--place','--route',
       '--vdb_file',(Join-Path $out "$NAME.vdb"),'--use_vdb_file','on',
       '--place_file',(Join-Path $out "$NAME.place"),'--route_file',(Join-Path $out "$NAME.troutingtraces"),
       '--optimization_level','TIMING_3','--seed','0','--placer_effort_level','2',
       '--max_threads','-1','--beneficial_skew','on','--print_critical_path','10',
       '--work_dir',$wpnr,'--output_dir',$out,'--timing_analysis','on')
if(Test-Path $sdc){ $pnr += @('--sdc_file',$sdc) }
$p=Start-Process -FilePath "$efi/bin/efx_pnr.exe" -ArgumentList $pnr -NoNewWindow -Wait -PassThru -WorkingDirectory $Work `
   -RedirectStandardOutput (Join-Path $OUT 'pnr1.log') -RedirectStandardError (Join-Path $OUT 'pnr1.err.log')
Log "[2] efx_pnr#1 退出码=$($p.ExitCode)"
if(-not (Test-Path (Join-Path $out "$NAME.vdb"))){ Log "  !! 无 vdb"; exit 1 }

# [3] interface
Log "[3] efx_run -f interface"
Remove-Item (Join-Path $Work 'outflow') -Recurse -Force -EA 0
Push-Location $Work
& "$efi/bin/efx_run.bat" $NAME --prj -f interface 2>&1 | Select-Object -Last 3 | ForEach-Object { Log "  $_" }
Pop-Location
$rawCsv = Join-Path $Work "outflow\$NAME.interface.csv"
if(-not (Test-Path $rawCsv)){ Log "  !! interface.csv 未生成"; exit 2 }

# [4] filter
Log "[4] filter_interface"
& powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\FPGA\易灵思\工作区\06_Efinity验证\filter_interface.ps1' `
   -Top (Join-Path $Work "rtl\$TOP.v") -In $rawCsv -Out (Join-Path $out "$NAME.interface.csv") 2>&1 |
   Select-Object -Last 3 | ForEach-Object { Log "  $_" }

# [5] pnr with sync_file
$pnr2 = $pnr + @('--sync_file',(Join-Path $out "$NAME.interface.csv"))
$p=Start-Process -FilePath "$efi/bin/efx_pnr.exe" -ArgumentList $pnr2 -NoNewWindow -Wait -PassThru -WorkingDirectory $Work `
   -RedirectStandardOutput (Join-Path $OUT 'pnr2.log') -RedirectStandardError (Join-Path $OUT 'pnr2.err.log')
Log "[5] efx_pnr#2 --sync_file 退出码=$($p.ExitCode)"
$r2 = Get-Content (Join-Path $OUT 'pnr2.log') -EA 0
Log ("  验收: 'No valid pin(s) found for clock' = " + ($r2 | Select-String 'No valid pin\(s\) found for clock').Count + "  （必须 0）")
Log ("        'No clocks matched'              = " + ($r2 | Select-String 'No clocks matched').Count)
$r2 | Select-String 'XLRs:|Memory Blocks:|DSP Blocks:' | Select-Object -First 3 | ForEach-Object { Log ("  资源: " + $_.Line.Trim()) }
Log "  时序 hold 违约:"
$r2 | Select-String 'hold \(min\)|setup \(max\)' | Select-Object -First 10 | ForEach-Object { Log ("    " + $_.Line.Trim()) }

# bitgen
$lbf = Get-ChildItem $wpnr -Filter '*.lbf' -EA 0 | Select-Object -First 1
if($lbf){
    $hexBit = Join-Path $OUT "v7_$Tag.hex"
    $p=Start-Process -FilePath "$efi/bin/efx_pgm.exe" -ArgumentList @('--project-xml',$xml,'--source',$lbf.FullName,'--dest',$hexBit,
        '--family','Titanium','--device','Ti60F225','--mode','active','--width','1') `
        -NoNewWindow -Wait -PassThru -WorkingDirectory $Work `
        -RedirectStandardOutput (Join-Path $OUT 'pgm.log') -RedirectStandardError (Join-Path $OUT 'pgm.err.log')
    $bit = Join-Path $OUT "v7_$Tag.bit"
    if(Test-Path $bit){ Log ("  ✅ bit: " + $bit + "  {0:N0} B  SHA256 {1}" -f (Get-Item $bit).Length,(Get-FileHash $bit -Algorithm SHA256).Hash) }
    else { Log "  !! 位流未生成" }
} else { Log "  !! 无 lbf" }
Log "===== [$Tag] 完成 ====="
