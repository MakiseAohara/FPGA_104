# ==========================================================================
#  run_ddr_wr_buf.ps1 -- ddr_wr_buffer stand-alone RTL simulation
#  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sim\ddr_wr_buf\run_ddr_wr_buf.ps1
#
#  Sources are copied to %TEMP%\ddr_wr_buf_sim\src (rtl\ is never modified) with:
#   - ALWAYS: {(ddr_awlen+1),...} -> {(ddr_awlen+9'd1),...}  (iverilog syntax only; same value)
#   - GRAY=1 only: GrayDecode `always @(GrayIn)` -> continuous assign (see run_frame_wr.ps1)
#  Builds A "NOGRAY" (concat shim only) and B "GRAY" (both shims).
# ==========================================================================
$ErrorActionPreference = 'Continue'
$ivBin = 'D:\iverilog\Library\bin'
$ivMg  = 'D:\iverilog\Library\mingw-w64\bin'
$env:PATH = "$ivBin;$ivMg;" + $env:PATH

$sim  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $sim)
$RTLD = Join-Path $root 'rtl\frame_buffer'
$out  = Join-Path $env:TEMP 'ddr_wr_buf_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Build-Src($name, $gray) {
    $d = Join-Path $out ("src_" + $name)
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    foreach ($f in 'ddr_wr_buffer.v','DC_FIFO.v') {
        $t = [System.IO.File]::ReadAllText((Join-Path $RTLD $f))
        $t = $t -replace '\(ddr_awlen\+1\)', "(ddr_awlen+9'd1)"
        if ($gray) {
            $g = "  wire [DW_C-1:0] sh1 = GrayIn ^ (GrayIn >> 1);`r`n  wire [DW_C-1:0] sh2 = sh1 ^ (sh1 >> 2);`r`n  wire [DW_C-1:0] sh4 = sh2 ^ (sh2 >> 4);`r`n  wire [DW_C-1:0] sh8 = sh4 ^ (sh4 >> 8);`r`n  assign HexOut = sh8;"
            $t = [regex]::Replace($t, '(?s)\s*reg \[DW_C-1:0\] Hex;.*?assign HexOut = Hex;', $g)
        }
        [System.IO.File]::WriteAllText((Join-Path $d $f), $t, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $d
}

$scen = @(
  @{ N='pulse1';  H=1;  P=1 },
  @{ N='pulse2';  H=2;  P=1 },
  @{ N='hold40';  H=40; P=1 },
  @{ N='holdFOREVER'; H=0; P=1 }
)
foreach ($variant in @(@{V='NOGRAY'; G=$false}, @{V='GRAY'; G=$true})) {
    $d = Build-Src $variant.V $variant.G
    foreach ($s in $scen) {
        $tag = $variant.V + "_" + $s.N
        $vvp = Join-Path $out ($tag + ".vvp")
        $log = Join-Path $out ($tag + ".log")
        & "$ivBin\iverilog.exe" -g2012 -s tb_ddr_wr_buf -o $vvp "-DHOLD=$($s.H)" "-DPRE_FILL=$($s.P)" "-DTAG=`"$tag`"" `
            (Join-Path $d 'ddr_wr_buffer.v') (Join-Path $d 'DC_FIFO.v') (Join-Path $sim 'tb_ddr_wr_buf.v') 2>&1 | Select-String 'error'
        & "$ivBin\vvp.exe" $vvp 2>&1 | Set-Content -Path $log -Encoding UTF8
        Write-Output ("##### " + $tag + "  (log: " + $log + ")")
        Get-Content $log | Select-String -Pattern '^(\[AW\]|\[TB\]|====|max_state|ever_|pos_sync cyc|cycles with|final:)' | ForEach-Object { $_.Line }
    }
}
