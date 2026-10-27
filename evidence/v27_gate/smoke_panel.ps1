param([Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:taskOut=$Evidence
$script:taskState=$null
$script:taskSeen=@{}
$script:taskHeld=New-Object 'System.Collections.Generic.HashSet[string]'
$taskForm=New-Object Windows.Forms.Form
$taskForm.Text='MERGE15 冒烟现场记录 — Kevin'
$taskForm.StartPosition='CenterScreen'
$taskForm.Size=New-Object Drawing.Size(1050,800)
$taskForm.Font=New-Object Drawing.Font('Microsoft YaHei UI',14)
$taskForm.KeyPreview=$true
$taskForm.TopMost=$true
$taskHeader=New-Object Windows.Forms.Label
$taskHeader.Location=New-Object Drawing.Point(16,15)
$taskHeader.Size=New-Object Drawing.Size(1000,76)
$taskHeader.Font=New-Object Drawing.Font('Microsoft YaHei UI',26,[Drawing.FontStyle]::Bold)
$taskHeader.BackColor=[Drawing.Color]::DarkOrange
$taskHeader.ForeColor=[Drawing.Color]::White
$taskHeader.Text='正在加载 MERGE15 + v26，请稍候'
$taskForm.Controls.Add($taskHeader)
$taskHint=New-Object Windows.Forms.Label
$taskHint.Location=New-Object Drawing.Point(16,105)
$taskHint.Size=New-Object Drawing.Size(1000,124)
$taskHint.Text='加载完成后：确认 HDMI/OSD → 人真正离开并按 Space，空场至少30秒 → 按E实际入画 → 报警后按L完全离开 → 看到释放后确认。'+"`n"+
    '站在镜头前1.5–2米，上半身到腰部入画。按键只记录实际事实；有任何异常按F，立即回退。'+"`n"+
    '四项齐备才进入正式操作者面板；没有现场确认不会自动写为通过。'
$taskForm.Controls.Add($taskHint)
$taskDefinitions=@(
    @('确认 HDMI 有画面、OSD 正常','HDMI_OK',16,240),
    @('人进入画面 [E]','ENTER',525,240),
    @('人完全离开画面 [L]','LEAVE',16,312),
    @('确认当前画面是空的 [Space]','EMPTY_CONFIRMED',525,312),
    @('已看到入画报警、离开释放','VISUAL_ALARM_RELEASE_OK',16,384),
    @('出现异常，立即回退 [F]','FAIL',525,384),
    @('结束冒烟；未全部确认则回退','STOP',16,456)
)
$script:taskButtons=@{}
function Write-TaskObservation([string]$EventName,[string]$Source) {
    if (-not $script:taskState -or $script:taskState.phase -ne 'SMOKE') { return }
    $taskWall=[DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $taskLine=[string]::Join(',',@($EventName,$taskWall,[string]$script:taskState.device_ms,$Source))+"`n"
    [IO.File]::AppendAllText((Join-Path $script:taskOut 'operator_events_raw.csv'),$taskLine,(New-Object Text.UTF8Encoding($false)))
    [Media.SystemSounds]::Asterisk.Play()
    $script:taskButtons[$EventName].BackColor=[Drawing.Color]::Gold
    $script:taskSeen[$EventName]=[DateTime]::UtcNow.AddMilliseconds(200)
}
foreach ($taskDefinition in $taskDefinitions) {
    $taskButton=New-Object Windows.Forms.Button
    $taskButton.Text=$taskDefinition[0]
    $taskButton.Tag=$taskDefinition[1]
    $taskButton.Location=New-Object Drawing.Point($taskDefinition[2],$taskDefinition[3])
    $taskButton.Size=New-Object Drawing.Size(490,62)
    $taskButton.Enabled=$false
    $taskButton.Add_Click({param($sender,$eventArgs) Write-TaskObservation ([string]$sender.Tag) 'human_button'})
    $taskForm.Controls.Add($taskButton)
    $script:taskButtons[$taskDefinition[1]]=$taskButton
}
$taskStatus=New-Object Windows.Forms.Label
$taskStatus.Location=New-Object Drawing.Point(16,535)
$taskStatus.Size=New-Object Drawing.Size(1000,168)
$taskForm.Controls.Add($taskStatus)
$taskKeys=@{E='ENTER';L='LEAVE';Space='EMPTY_CONFIRMED';F='FAIL'}
$taskForm.Add_KeyDown({param($sender,$eventArgs)
    $taskKey=$eventArgs.KeyCode.ToString()
    if ($taskKeys.ContainsKey($taskKey)) {
        if ($script:taskHeld.Add($taskKey)) { Write-TaskObservation $taskKeys[$taskKey] 'human_key' }
        $eventArgs.Handled=$true
    }
})
$taskForm.Add_KeyUp({param($sender,$eventArgs) [void]$script:taskHeld.Remove($eventArgs.KeyCode.ToString())})
$taskForm.Add_KeyPress({param($sender,$eventArgs) if ('elf '.Contains([string][char]::ToLowerInvariant($eventArgs.KeyChar))) { $eventArgs.Handled=$true }})
$taskForm.Add_Deactivate({$script:taskHeld.Clear()})
$taskTimer=New-Object Windows.Forms.Timer
$taskTimer.Interval=150
$taskTimer.Add_Tick({
    $taskReader=$null
    try {
        $taskShare=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $taskStream=[IO.File]::Open((Join-Path $script:taskOut 'smoke_live.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,$taskShare)
        $taskReader=New-Object IO.StreamReader($taskStream,[Text.Encoding]::UTF8)
        $script:taskState=$taskReader.ReadToEnd() | ConvertFrom-Json
    } catch { return } finally { if ($taskReader) { $taskReader.Dispose() } }
    foreach ($taskButton in $script:taskButtons.Values) { $taskButton.Enabled=($script:taskState.phase -eq 'SMOKE') }
    foreach ($taskName in @($script:taskSeen.Keys)) {
        if ([DateTime]::UtcNow -gt $script:taskSeen[$taskName]) { $script:taskButtons[$taskName].BackColor=[Drawing.SystemColors]::Control; $script:taskSeen.Remove($taskName) }
    }
    if ($script:taskState.phase -eq 'SMOKE') {
        $taskHeader.Text='冒烟记录中 — 请按实际现场操作'
        $taskHeader.BackColor=[Drawing.Color]::Firebrick
    }
    $taskStatus.Text=('a HDMI/OSD: {0}   b 入画报警/离开释放: {1}'+"`n"+'c DEC及相机帧率: {2}   d 真实空场30秒: {3}'+"`n"+'device_ms={4}  camfps={5}  irhot={6}  body10={7}'+"`n"+'最近记录：{8}'+"`n"+'手机视频留给正式重测：HDMI右侧热力图、手靠近MLX前20cm十秒再拿开十秒。') -f
        $script:taskState.checks.hdmi_osd,$script:taskState.checks.enter_alarm_leave_release,
        $script:taskState.checks.dec_and_camera_fps,$script:taskState.checks.empty_30s_no_alarm,
        $script:taskState.device_ms,$script:taskState.camfps,$script:taskState.irhot,$script:taskState.body10,$script:taskState.last_operator_event
    if ($script:taskState.phase -in @('PASSED','ROLLBACK','STOPPED')) { $taskTimer.Stop(); $taskForm.Close() }
})
$taskForm.Add_Shown({
    $taskTimer.Start();$taskForm.Activate()
    [IO.File]::WriteAllText((Join-Path $script:taskOut 'panel_ready.json'),('{"shown":true,"pid":'+$PID+'}'),(New-Object Text.UTF8Encoding($false)))
})
$taskForm.Add_FormClosing({
    if ($script:taskState -and $script:taskState.phase -eq 'SMOKE') { Write-TaskObservation 'STOP' 'human_window_close' }
})
try { [void]$taskForm.ShowDialog() } finally { $taskTimer.Stop();$taskTimer.Dispose();$taskForm.Dispose() }
