<#
用途：每次 Efinity 构建后运行，自动核对 HDMI 输出时序是否为目标值（标准 1080p60）
读取文件：
  - D:\FPGA\mmt\mmt.peri.xml （USER_PLL 时钟参数）
  - D:\FPGA\mmt\rtl\mmt\mmt_top.v （时序参数 localparam 及 frame_buffer 端口接法）
VCO 公式出处：厂商报告 ...oob.pt.rpt：VCO = ref_clock_freq × (multiplier × 反馈分频) / pre_divider
每次构建后运行此脚本以验证时序是否符合预期。
#>

# =============================================================================
# 期望值（可修改变量）
# =============================================================================
$Expected_vid_clk_dvi2_MHz = 75.0
$Expected_hdmi_tx_slow_clk_MHz = 150.0
$Expected_i_mipi_rx_pclk_MHz = 50.0
$Expected_pixels_per_line = 2200
$Expected_lines_per_frame = 1125
$Expected_frame_rate_Hz = 60.61
$Expected_tmds_bitrate_Gbps = 1.50
$FrameRate_tolerance = 0.01  # ±1%

Write-Host "=== 期望值 ==="
Write-Host "vid_clk_dvi2 目标: $Expected_vid_clk_dvi2_MHz MHz"
Write-Host "hdmi_tx_slow_clk 目标: $Expected_hdmi_tx_slow_clk_MHz MHz"
Write-Host "i_mipi_rx_pclk 目标: $Expected_i_mipi_rx_pclk_MHz MHz"
Write-Host "每行总像素数 目标: $Expected_pixels_per_line"
Write-Host "每帧总行数 目标: $Expected_lines_per_frame"
$tolerance_pct_text = "{0:N2}" -f ($FrameRate_tolerance * 100)
Write-Host "帧率 目标: $Expected_frame_rate_Hz Hz (容差 ±$tolerance_pct_text%)"
Write-Host "TMDS 码率 目标: $Expected_tmds_bitrate_Gbps Gbps"
Write-Host ""

# =============================================================================
# 函数：比较浮点数是否在容差内
# =============================================================================
function Test-FloatEqual {
    param($actual, $expected, $tolerance)
    $diff = if ($actual -gt $expected) { $actual - $expected } else { $expected - $actual }
    $threshold = $expected * $tolerance
    return $diff -le $threshold
}

# =============================================================================
# 函数：格式化双精度数为字符串
# =============================================================================
function Format-Double {
    param($value, $decimals=4)
    $str = "{0:N$decimals}" -f $value
    return $str
}

# =============================================================================
# 一、提取值
# =============================================================================
Write-Host "`n========================================"
Write-Host "一、提取值"
Write-Host "========================================`n"

$all_pass = $true

# -----------------------------------------------------------------------------
# A. 从 mmt.peri.xml 提取 USER_PLL 参数
# -----------------------------------------------------------------------------
Write-Host "A. 从 mmt.peri.xml 提取 USER_PLL 参数:"

$peri_xml_path = "D:\FPGA\mmt\mmt.peri.xml"
if (-not (Test-Path $peri_xml_path)) {
    Write-Host "  [FAIL] 文件不存在: $peri_xml_path"
    $all_pass = $false
} else {
    $peri_content = Get-Content $peri_xml_path -Raw
    
    # 提取 USER_PLL 的属性
    $pll_match = $peri_content -match '<efxpt:pll name="USER_PLL"[^>]*ref_clock_freq="([^"]+)"[^>]*multiplier="([^"]+)"[^>]*pre_divider="([^"]+)"'
    
    if ($pll_match) {
        $ref_clock_freq = [double]$pll_match[1]
        $multiplier = [double]$pll_match[2]
        $pre_divider = [double]$pll_match[3]
        Write-Host "  ref_clock_freq = $ref_clock_freq MHz [PASS]"
        Write-Host "  multiplier = $multiplier [PASS]"
        Write-Host "  pre_divider = $pre_divider [PASS]"
    } else {
        Write-Host "  [FAIL] 未找到 USER_PLL 的 ref_clock_freq/multiplier/pre_divider"
        $all_pass = $false
    }
    
    # 提取反馈分频时钟名
    $feedback_match = $peri_content -match '<efxpt:pll name="USER_PLL"[^>]*feedback_clock_name="([^"]+)"'
    if ($feedback_match) {
        $feedback_clock_name = $feedback_match[1]
        Write-Host "  feedback_clock_name = $feedback_clock_name [PASS]"
    } else {
        Write-Host "  [FAIL] 未找到 USER_PLL 的 feedback_clock_name"
        $all_pass = $false
    }
    
    # 提取各输出时钟的 out_divider
    $clocks = @("vid_clk_dvi2", "hdmi_tx_slow_clk", "i_mipi_rx_pclk", "hdmi_tx_fast_clk")
    $out_dividers = @{}
    
    foreach ($clock_name in $clocks) {
        $pattern = '<efxpt:comp_output_clock name="' + $clock_name + '"[^>]*out_divider="([^"]+)"'
        $div_match = $peri_content -match $pattern
        if ($div_match) {
            $out_dividers[$clock_name] = [double]$div_match[1]
            Write-Host "  $clock_name out_divider = $($out_dividers[$clock_name]) [PASS]"
        } else {
            Write-Host "  [FAIL] 未找到 $clock_name 的 out_divider"
            $all_pass = $false
        }
    }
}

Write-Host ""

# -----------------------------------------------------------------------------
# B. 从 mmt_top.v 提取 localparam 值
# -----------------------------------------------------------------------------
Write-Host "B. 从 mmt_top.v 提取 localparam 值:"

$top_v_path = "D:\FPGA\mmt\rtl\mmt\mmt_top.v"
if (-not (Test-Path $top_v_path)) {
    Write-Host "  [FAIL] 文件不存在: $top_v_path"
    $all_pass = $false
} else {
    $top_content = Get-Content $top_v_path -Raw
    
    $params = @("MAX_HRES", "MAX_VRES", "HSP", "HBP", "HFP", "VSP", "VBP", "VFP")
    $param_values = @{}
    
    foreach ($param_name in $params) {
        $pattern = 'localparam\s+' + $param_name + '\s*=\s*[^;]+;'
        $match = $top_content -match $pattern
        if ($match) {
            # 提取数字值
            $value_match = $match[0] -match (\d+)
            if ($value_match) {
                $param_values[$param_name] = [double]$value_match[0]
                Write-Host "  $param_name = $($param_values[$param_name]) [PASS]"
            } else {
                Write-Host "  [FAIL] 未找到 $param_name 的数字值"
                $all_pass = $false
            }
        } else {
            Write-Host "  [FAIL] 未找到 $param_name"
            $all_pass = $false
        }
    }
}

Write-Host ""

# -----------------------------------------------------------------------------
# C. 提取 frame_buffer 端口接法
# -----------------------------------------------------------------------------
Write-Host "C. 从 mmt_top.v 提取 frame_buffer 时序端口接法:"

$port_patterns = @{
    "H_FRONT_PORCH" = '\.H_FRONT_PORCH\s*\(\s*([^)]+)\s*\)'
    "H_SYNC" = '\.H_SYNC\s*\(\s*([^)]+)\s*\)'
    "H_VALID" = '\.H_VALID\s*\(\s*([^)]+)\s*\)'
    "H_BACK_PORCH" = '\.H_BACK_PORCH\s*\(\s*([^)]+)\s*\)'
    "V_FRONT_PORCH" = '\.V_FRONT_PORCH\s*\(\s*([^)]+)\s*\)'
    "V_SYNC" = '\.V_SYNC\s*\(\s*([^)]+)\s*\)'
    "V_VALID" = '\.V_VALID\s*\(\s*([^)]+)\s*\)'
    "V_BACK_PORCH" = '\.V_BACK_PORCH\s*\(\s*([^)]+)\s*\)'
}

$port_expressions = @{}
foreach ($key in $port_patterns.Keys) {
    $match = $top_content -match $port_patterns[$key]
    if ($match) {
        $port_expressions[$key] = $match[1].Trim()
        Write-Host "  .$key ($($port_expressions[$key])) [PASS]"
    } else {
        Write-Host "  [FAIL] 未找到 .$key 的表达式"
        $all_pass = $false
    }
}

Write-Host ""

# =============================================================================
# 二、计算过程
# =============================================================================
Write-Host "`n========================================"
Write-Host "二、计算过程"
Write-Host "========================================`n"

if (-not $all_pass) {
    Write-Host "前面有 FAIL，跳过计算。`n"
} else {
    # -----------------------------------------------------------------------------
    # 计算 VCO 和各输出频率
    # -----------------------------------------------------------------------------
    Write-Host "--- VCO 和各输出频率计算 ---"
    
    # 反馈分频 = feedback_clock_name 对应的 out_divider
    $feedback_out_divider = $out_dividers[$feedback_clock_name]
    Write-Host "  反馈分频 = i_mipi_rx_pclk 的 out_divider = $feedback_out_divider"
    
    # VCO = ref_clock_freq × (multiplier × 反馈分频) / pre_divider
    $VCO_MHz = $ref_clock_freq * ($multiplier * $feedback_out_divider) / $pre_divider
    Write-Host "  VCO = $ref_clock_freq × ($multiplier × $feedback_out_divider) / $pre_divider = $(Format-Double $VCO_MHz 4) MHz"
    
    # 各输出频率
    $vid_clk_dvi2_freq = $VCO_MHz / $out_dividers["vid_clk_dvi2"]
    $hdmi_tx_slow_clk_freq = $VCO_MHz / $out_dividers["hdmi_tx_slow_clk"]
    $i_mipi_rx_pclk_freq = $VCO_MHz / $out_dividers["i_mipi_rx_pclk"]
    $hdmi_tx_fast_clk_freq = $VCO_MHz / $out_dividers["hdmi_tx_fast_clk"]
    
    Write-Host "  vid_clk_dvi2 = VCO / $($out_dividers['vid_clk_dvi2']) = $(Format-Double $vid_clk_dvi2_freq 4) MHz"
    Write-Host "  hdmi_tx_slow_clk = VCO / $($out_dividers['hdmi_tx_slow_clk']) = $(Format-Double $hdmi_tx_slow_clk_freq 4) MHz"
    Write-Host "  i_mipi_rx_pclk = VCO / $($out_dividers['i_mipi_rx_pclk']) = $(Format-Double $i_mipi_rx_pclk_freq 4) MHz"
    Write-Host "  hdmi_tx_fast_clk = VCO / $($out_dividers['hdmi_tx_fast_clk']) = $(Format-Double $hdmi_tx_fast_clk_freq 4) MHz"
    
    Write-Host ""
    
    # -----------------------------------------------------------------------------
    # 计算时序参数（根据 frame_buffer 端口接法）
    # -----------------------------------------------------------------------------
    Write-Host "--- 时序参数计算 ---"
    Write-Host "  端口接法来自 mmt_top.v 的 frame_buffer 例化处"
    Write-Host "  读侧在 vid_clk_dvi2 域，每拍输出 2 像素"
    Write-Host ""
    
    # 计算各部分的值
    # H_FRONT_PORCH = HFP/2, H_SYNC = HSP, H_VALID = MAX_HRES/2, H_BACK_PORCH = HBP/2
    # V_FRONT_PORCH = VFP, V_SYNC = VSP, V_VALID = MAX_VRES, V_BACK_PORCH = VBP
    
    Write-Host "  根据表达式计算实际连接值:"
    
    # 计算各部分的值
    $h_front_porch_val = $param_values["HFP"] / 2  # HFP/2
    $h_sync_val = $param_values["HSP"]             # HSP
    $h_valid_val = $param_values["MAX_HRES"] / 2   # MAX_HRES/2
    $h_back_porch_val = $param_values["HBP"] / 2  # HBP/2
    
    $v_front_porch_val = $param_values["VFP"]     # VFP
    $v_sync_val = $param_values["VSP"]             # VSP
    $v_valid_val = $param_values["MAX_VRES"]       # MAX_VRES
    $v_back_porch_val = $param_values["VBP"]       # VBP
    
    Write-Host "    H_FRONT_PORCH = HFP/2 = $($param_values['HFP'])/2 = $h_front_porch_val (拍)"
    Write-Host "    H_SYNC = HSP = $($param_values['HSP']) (拍)"
    Write-Host "    H_VALID = MAX_HRES/2 = $($param_values['MAX_HRES'])/2 = $h_valid_val (拍)"
    Write-Host "    H_BACK_PORCH = HBP/2 = $($param_values['HBP'])/2 = $h_back_porch_val (拍)"
    Write-Host "    V_FRONT_PORCH = VFP = $($param_values['VFP']) (行)"
    Write-Host "    V_SYNC = VSP = $($param_values['VSP']) (行)"
    Write-Host "    V_VALID = MAX_VRES = $($param_values['MAX_VRES']) (行)"
    Write-Host "    V_BACK_PORCH = VBP = $($param_values['VBP']) (行)"
    
    Write-Host ""
    
    # 计算每行总拍数
    $total_clocks_per_line = $h_front_porch_val + $h_sync_val + $h_valid_val + $h_back_porch_val
    Write-Host "  每行总拍数 = $h_front_porch_val + $h_sync_val + $h_valid_val + $h_back_porch_val = $total_clocks_per_line"
    
    # 每行总像素数（每拍输出 2 像素）
    $pixels_per_line = $total_clocks_per_line * 2
    Write-Host "  每行总像素数 = 每行总拍数 × 2 = $total_clocks_per_line × 2 = $pixels_per_line"
    
    # 每帧总行数
    $total_lines_per_frame = $v_front_porch_val + $v_sync_val + $v_valid_val + $v_back_porch_val
    Write-Host "  每帧总行数 = $v_front_porch_val + $v_sync_val + $v_valid_val + $v_back_porch_val = $total_lines_per_frame"
    
    Write-Host ""
    
    # -----------------------------------------------------------------------------
    # 计算帧率和码率
    # -----------------------------------------------------------------------------
    Write-Host "--- 帧率和码率计算 ---"
    
    # 帧率 = vid_clk_dvi2 频率 / (每行总拍数 × 每帧总行数)
    $frame_rate = $vid_clk_dvi2_freq * 1e6 / ($total_clocks_per_line * $total_lines_per_frame)
    Write-Host "  帧率 = $vid_clk_dvi2_freq MHz / ($total_clocks_per_line × $total_lines_per_frame) = $(Format-Double $frame_rate 4) Hz"
    
    # TMDS 码率（每条 lane）= hdmi_tx_slow_clk 频率 × 10
    $tmds_bitrate_Mbps = $hdmi_tx_slow_clk_freq * 10
    $tmds_bitrate_Gbps = $tmds_bitrate_Mbps / 1000
    Write-Host "  TMDS 码率 = $hdmi_tx_slow_clk_freq MHz × 10 = $tmds_bitrate_Mbps Mbps = $(Format-Double $tmds_bitrate_Gbps 4) Gbps"
}

Write-Host ""

# =============================================================================
# 三、比对结果
# =============================================================================
Write-Host "`n========================================"
Write-Host "三、比对结果"
Write-Host "========================================`n"

if (-not $all_pass) {
    Write-Host "[FAIL] 前面有提取失败，无法比对。`n"
    exit 1
}

$any_fail = $false

# 比对各输出频率
Write-Host "--- 时钟频率比对 ---"

# 浮点比较用容差
$vid_clk_diff = if ($vid_clk_dvi2_freq -gt $Expected_vid_clk_dvi2_MHz) { $vid_clk_dvi2_freq - $Expected_vid_clk_dvi2_MHz } else { $Expected_vid_clk_dvi2_MHz - $vid_clk_dvi2_freq }
$vid_clk_result = if ($vid_clk_diff -lt 0.001) { "PASS" } else { "FAIL" }
Write-Host "  vid_clk_dvi2: $(Format-Double $vid_clk_dvi2_freq 4) MHz (期望 $Expected_vid_clk_dvi2_MHz MHz) [$vid_clk_result]"
if ($vid_clk_result -eq "FAIL") { $any_fail = $true }

$slow_clk_diff = if ($hdmi_tx_slow_clk_freq -gt $Expected_hdmi_tx_slow_clk_MHz) { $hdmi_tx_slow_clk_freq - $Expected_hdmi_tx_slow_clk_MHz } else { $Expected_hdmi_tx_slow_clk_MHz - $hdmi_tx_slow_clk_freq }
$slow_clk_result = if ($slow_clk_diff -lt 0.001) { "PASS" } else { "FAIL" }
Write-Host "  hdmi_tx_slow_clk: $(Format-Double $hdmi_tx_slow_clk_freq 4) MHz (期望 $Expected_hdmi_tx_slow_clk_MHz MHz) [$slow_clk_result]"
if ($slow_clk_result -eq "FAIL") { $any_fail = $true }

$mipi_clk_diff = if ($i_mipi_rx_pclk_freq -gt $Expected_i_mipi_rx_pclk_MHz) { $i_mipi_rx_pclk_freq - $Expected_i_mipi_rx_pclk_MHz } else { $Expected_i_mipi_rx_pclk_MHz - $i_mipi_rx_pclk_freq }
$mipi_clk_result = if ($mipi_clk_diff -lt 0.001) { "PASS" } else { "FAIL" }
Write-Host "  i_mipi_rx_pclk: $(Format-Double $i_mipi_rx_pclk_freq 4) MHz (期望 $Expected_i_mipi_rx_pclk_MHz MHz) [$mipi_clk_result]"
if ($mipi_clk_result -eq "FAIL") { $any_fail = $true }

Write-Host ""

# 比对时序参数
Write-Host "--- 时序参数比对 ---"

$pixels_result = if ($pixels_per_line -eq $Expected_pixels_per_line) { "PASS" } else { "FAIL" }
Write-Host "  每行总像素数: $pixels_per_line (期望 $Expected_pixels_per_line) [$pixels_result]"
if ($pixels_result -eq "FAIL") { $any_fail = $true }

$lines_result = if ($total_lines_per_frame -eq $Expected_lines_per_frame) { "PASS" } else { "FAIL" }
Write-Host "  每帧总行数: $total_lines_per_frame (期望 $Expected_lines_per_frame) [$lines_result]"
if ($lines_result -eq "FAIL") { $any_fail = $true }

Write-Host ""

# 比对帧率（使用容差）
Write-Host "--- 帧率比对 ---"

$frame_rate_result = if (Test-FloatEqual $frame_rate $Expected_frame_rate_Hz $FrameRate_tolerance) { "PASS" } else { "FAIL" }
$fr_str = Format-Double $frame_rate 2
Write-Host "  帧率: $fr_str Hz (期望 $Expected_frame_rate_Hz Hz ±$tolerance_pct_text%) [$frame_rate_result]"
if ($frame_rate_result -eq "FAIL") { $any_fail = $true }

Write-Host ""

# 比对 TMDS 码率
Write-Host "--- TMDS 码率比对 ---"

$tmds_diff = if ($tmds_bitrate_Gbps -gt $Expected_tmds_bitrate_Gbps) { $tmds_bitrate_Gbps - $Expected_tmds_bitrate_Gbps } else { $Expected_tmds_bitrate_Gbps - $tmds_bitrate_Gbps }
$tmds_result = if ($tmds_diff -lt 0.001) { "PASS" } else { "FAIL" }
$tb_str = Format-Double $tmds_bitrate_Gbps 2
Write-Host "  TMDS 码率: $tb_str Gbps (期望 $Expected_tmds_bitrate_Gbps Gbps) [$tmds_result]"
if ($tmds_result -eq "FAIL") { $any_fail = $true }

Write-Host ""

# =============================================================================
# 最终结果
# =============================================================================
if ($any_fail) {
    Write-Host "========================================"
    Write-Host "结果: FAIL"
    Write-Host "========================================`n"
    exit 1
} else {
    Write-Host "========================================"
    Write-Host "结果: PASS"
    Write-Host "========================================`n"
    exit 0
}
