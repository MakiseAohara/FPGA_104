param(
    [string]$Evidence = $PSScriptRoot,
    [string]$Python = 'C:\Users\Makise Aohara\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    [string]$Port = 'COM15',
    [ValidateSet('formal','smoke')][string]$Mode = 'formal',
    [string]$BoardReceipt = (Join-Path $PSScriptRoot 'board_ready.json'),
    [switch]$SelfTest,
    [string]$SelfTestOut
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
if ($SelfTest) {
    if (-not $SelfTestOut) { throw 'SelfTest requires a separate -SelfTestOut folder' }
    $Evidence = [IO.Path]::GetFullPath($SelfTestOut)
    if (($Evidence -split '[\\/]') -contains 'evidence') { throw 'Simulation must be outside evidence/' }
    [IO.Directory]::CreateDirectory($Evidence) | Out-Null
}
$script:taskEvidence = [IO.Path]::GetFullPath($Evidence)
$script:taskState = 'IDLE'
$script:taskT0 = $null
$script:taskBackendState = $null
$script:taskClosing = $false
$script:taskHeld = New-Object 'System.Collections.Generic.HashSet[string]'
$script:taskButtons = @{}
$script:taskFlashUntil = @{}
$script:taskReady = $false
if ($SelfTest -or $Mode -eq 'smoke') { $script:taskReady = $true }
elseif (Test-Path -LiteralPath $BoardReceipt) {
    $taskReceipt = Get-Content -LiteralPath $BoardReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:taskReady = ($taskReceipt.bitstream_sha256 -eq '74E205F84613F23C1DD8040E2CF31F032BBF524D3ED81022DE551D998613AF40' -and
        $taskReceipt.firmware_crc32 -eq 'B7CCB8D0' -and $taskReceipt.rollback_required -eq $false -and
        $taskReceipt.checks.hdmi_osd -eq $true -and $taskReceipt.checks.enter_alarm_leave_release -eq $true -and
        $taskReceipt.checks.dec_and_camera_fps -eq $true -and $taskReceipt.checks.empty_30s_no_alarm -eq $true)
}

$taskStartInfo = New-Object Diagnostics.ProcessStartInfo
$taskStartInfo.FileName = $Python
$taskStartInfo.Arguments = '-u "'+(Join-Path $PSScriptRoot 'capture_v27.py')+'" --out "'+$script:taskEvidence+'" --port "'+$Port+'" --mode '+$Mode
if ($SelfTest) { $taskStartInfo.Arguments += ' --self-test' }
$taskStartInfo.UseShellExecute = $false
$taskStartInfo.CreateNoWindow = $true
$taskStartInfo.RedirectStandardInput = $true
$taskStartInfo.RedirectStandardOutput = $true
$taskStartInfo.RedirectStandardError = $true
$taskStartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
$taskStartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
$taskStartInfo.EnvironmentVariables.Remove('PYTHONHOME')
$taskStartInfo.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
$taskBackend = New-Object Diagnostics.Process
$taskBackend.StartInfo = $taskStartInfo
[void]$taskBackend.Start()
$script:taskRead = $taskBackend.StandardOutput.ReadLineAsync()
$taskErrorRead = $taskBackend.StandardError.ReadToEndAsync()

function Get-TaskWall {
    return [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
}
function Send-TaskCommand($Packet) {
    $taskBackend.StandardInput.WriteLine(($Packet | ConvertTo-Json -Compress))
    $taskBackend.StandardInput.Flush()
}
function Signal-TaskInput($Button) {
    [Media.SystemSounds]::Asterisk.Play()
    $Button.BackColor = [Drawing.Color]::Gold
    $script:taskFlashUntil[$Button.Name] = [DateTime]::UtcNow.AddMilliseconds(180)
}
function Record-TaskAction([string]$EventName, [string]$Source) {
    if ($script:taskState -ne 'RECORDING') { return }
    Send-TaskCommand @{command='LABEL';event=$EventName;wall=(Get-TaskWall);source=$Source}
    Signal-TaskInput $script:taskButtons[$EventName]
}
function Start-TaskRecording {
    if ($script:taskState -ne 'IDLE' -or -not $script:taskReady) { return }
    $script:taskT0 = Get-TaskWall
    $script:taskState = 'STARTING'
    $taskStart.Enabled = $false
    $taskHeader.BackColor = [Drawing.Color]::Firebrick
    $taskHeader.ForeColor = [Drawing.Color]::White
    $taskHeader.Text = '正在开始采集  T+0.0 秒'
    Send-TaskCommand @{command='START';wall=$script:taskT0;source='human_button'}
    [Media.SystemSounds]::Asterisk.Play()
}
function Stop-TaskRecording([string]$Source = 'human_button') {
    if ($script:taskState -ne 'RECORDING') { return }
    $script:taskState = 'SAVING'
    $taskStop.Enabled = $false
    foreach ($taskButton in $script:taskButtons.Values) { $taskButton.Enabled = $false }
    $taskHeader.Text = '正在保存…'
    Send-TaskCommand @{command='STOP';wall=(Get-TaskWall);source=$Source}
}

$taskForm = New-Object Windows.Forms.Form
$taskForm.Text = 'v27 实际动作标注 — Kevin'
if ($SelfTest) { $taskForm.Text = '离线界面测试 — 模拟数据，不连接板子' }
$taskForm.StartPosition = 'CenterScreen'
$taskForm.Size = New-Object Drawing.Size(1100,910)
$taskForm.MinimumSize = New-Object Drawing.Size(900,700)
$taskForm.KeyPreview = $true
$taskForm.Font = New-Object Drawing.Font('Microsoft YaHei UI',12)
$taskContainer = New-Object Windows.Forms.FlowLayoutPanel
$taskContainer.Dock = 'Fill'
$taskContainer.AutoScroll = $true
$taskContainer.FlowDirection = 'TopDown'
$taskContainer.WrapContents = $false
$taskContainer.Padding = New-Object Windows.Forms.Padding(16)
$taskForm.Controls.Add($taskContainer)
$taskHeader = New-Object Windows.Forms.Label
$taskHeader.Size = New-Object Drawing.Size(1040,85)
$taskHeader.Font = New-Object Drawing.Font('Microsoft YaHei UI',32,[Drawing.FontStyle]::Bold)
$taskHeader.TextAlign = 'MiddleCenter'
$taskHeader.BackColor = [Drawing.Color]::Gainsboro
$taskHeader.Text = '未开始 — 点击绿色按钮开始计时'
$taskContainer.Controls.Add($taskHeader)
$taskControlRow = New-Object Windows.Forms.FlowLayoutPanel
$taskControlRow.Size = New-Object Drawing.Size(1040,78)
$taskStart = New-Object Windows.Forms.Button
$taskStart.Text = '开始采集'
$taskStart.Name = 'StartCapture'
$taskStart.Size = New-Object Drawing.Size(505,72)
$taskStart.Font = New-Object Drawing.Font('Microsoft YaHei UI',25,[Drawing.FontStyle]::Bold)
$taskStart.BackColor = [Drawing.Color]::LimeGreen
$taskStart.UseVisualStyleBackColor = $false
$taskStart.Enabled = $script:taskReady
$taskStart.Add_Click({ Start-TaskRecording })
$taskControlRow.Controls.Add($taskStart)
$taskStop = New-Object Windows.Forms.Button
$taskStop.Text = '结束采集并保存'
$taskStop.Size = New-Object Drawing.Size(505,72)
$taskStop.Font = $taskStart.Font
$taskStop.Enabled = $false
$taskStop.Add_Click({ Stop-TaskRecording })
$taskControlRow.Controls.Add($taskStop)
$taskContainer.Controls.Add($taskControlRow)
$taskStatus = New-Object Windows.Forms.Label
$taskStatus.Size = New-Object Drawing.Size(1040,52)
$taskStatus.Text = '等待操作者点击；点击前不打开串口，不生成标注。快捷键仅在本窗口获得焦点时有效。'
if (-not $script:taskReady) { $taskStatus.Text = '尚无 MERGE15 冒烟四项通过记录，正式采集禁用。面板可查看；未打开串口、未产生标注。' }
if ($Mode -eq 'smoke') { $taskStatus.Text = '冒烟记录模式：单独目录保存。请用实际按键标出进出与确认空场；这不是正式重测。' }
if ($SelfTest) { $taskStatus.Text = '离线界面测试：使用模拟串口，测试数据保存在单独工作目录，不属于上板证据。' }
$taskContainer.Controls.Add($taskStatus)
$taskGrid = New-Object Windows.Forms.FlowLayoutPanel
$taskGrid.Size = New-Object Drawing.Size(1040,290)
$taskDefinitions = @(
    @('人进入画面  [E]','ENTER','E'), @('人完全离开画面  [L]','LEAVE','L'),
    @('椅子开始  [C]','CHAIR_START','C'), @('椅子结束  [V]','CHAIR_END','V'),
    @('低头开始  [H]','HEAD_DOWN_START','H'), @('低头结束  [J]','HEAD_DOWN_END','J'),
    @('侧身开始  [S]','SIDE_START','S'), @('侧身结束  [D]','SIDE_END','D'),
    @('确认当前画面是空的  [Space]','EMPTY_CONFIRMED','Space')
)
$script:taskKeyMap = @{}
foreach ($taskDefinition in $taskDefinitions) {
    $taskButton = New-Object Windows.Forms.Button
    $taskButton.Text = $taskDefinition[0]
    $taskButton.Name = $taskDefinition[1]
    $taskButton.Tag = $taskDefinition[1]
    $taskButton.Size = New-Object Drawing.Size(505,51)
    if ($taskDefinition[1] -eq 'EMPTY_CONFIRMED') { $taskButton.Width = 1016 }
    $taskButton.Font = New-Object Drawing.Font('Microsoft YaHei UI',18,[Drawing.FontStyle]::Bold)
    $taskButton.BackColor = [Drawing.Color]::WhiteSmoke
    $taskButton.UseVisualStyleBackColor = $false
    $taskButton.Enabled = $false
    $taskButton.Add_Click({param($sender,$eventArgs) Record-TaskAction ([string]$sender.Tag) 'human_button'})
    $taskGrid.Controls.Add($taskButton)
    $script:taskButtons[$taskDefinition[1]] = $taskButton
    $script:taskKeyMap[$taskDefinition[2]] = $taskDefinition[1]
}
$taskContainer.Controls.Add($taskGrid)
$taskRecent = New-Object Windows.Forms.ListBox
$taskRecent.Size = New-Object Drawing.Size(1040,112)
$taskRecent.Font = New-Object Drawing.Font('Consolas',11)
$taskContainer.Controls.Add($taskRecent)
$taskHint = New-Object Windows.Forms.Label
$taskHint.Size = New-Object Drawing.Size(1040,112)
$taskHint.Font = New-Object Drawing.Font('Microsoft YaHei UI',11)
$taskHint.BackColor = [Drawing.Color]::LightYellow
$taskHint.Padding = New-Object Windows.Forms.Padding(8)
$taskHint.Text = '建议流程（仅参考，不自动推进、不生成事件）：'+"`n"+
    '空场约60秒 → 人走入站稳约90秒 → 人走出空场约45秒 → 椅子约30秒 →'+"`n"+
    '人走入约60秒（含低头、侧身）→ 人走出空场约60秒 → 再走入约30秒 → 走出空场约30秒。'+"`n"+
    '实际次序时长以按键为准；空场必须真正离开视野。'
$taskContainer.Controls.Add($taskHint)

function Invoke-TaskKey([string]$Key, [bool]$Down) {
    if (-not $script:taskKeyMap.ContainsKey($Key)) { return $false }
    if ($Down) {
        if ($script:taskHeld.Add($Key)) { Record-TaskAction $script:taskKeyMap[$Key] 'human_key' }
    } else { [void]$script:taskHeld.Remove($Key) }
    return $true
}
$taskForm.Add_KeyDown({param($sender,$eventArgs)
    if (Invoke-TaskKey ($eventArgs.KeyCode.ToString()) $true) { $eventArgs.Handled=$true }
})
$taskForm.Add_KeyUp({param($sender,$eventArgs)
    if (Invoke-TaskKey ($eventArgs.KeyCode.ToString()) $false) { $eventArgs.Handled=$true }
})
$taskForm.Add_KeyPress({param($sender,$eventArgs)
    if ('elcvhjsd '.Contains([string][char]::ToLowerInvariant($eventArgs.KeyChar))) { $eventArgs.Handled=$true }
})
$taskForm.Add_Deactivate({ $script:taskHeld.Clear() })

$script:taskTestStage = 0
$script:taskTestStart = [DateTime]::UtcNow
function Save-TaskScreenshot([string]$Name) {
    $taskBitmap = New-Object Drawing.Bitmap($taskForm.ClientSize.Width,$taskForm.ClientSize.Height)
    try {
        $taskForm.DrawToBitmap($taskBitmap,(New-Object Drawing.Rectangle(0,0,$taskForm.ClientSize.Width,$taskForm.ClientSize.Height)))
        $taskBitmap.Save((Join-Path $script:taskEvidence $Name),[Drawing.Imaging.ImageFormat]::Png)
    } finally { $taskBitmap.Dispose() }
}
$taskTimer = New-Object Windows.Forms.Timer
$taskTimer.Interval = 50
$taskTimer.Add_Tick({
    try {
        while ($script:taskRead.IsCompleted) {
            $taskLine = $script:taskRead.GetAwaiter().GetResult()
            if ($null -eq $taskLine) {
                if ($script:taskState -ne 'SAVED') { throw '采集进程已退出；未标记为已保存。' }
                break
            }
            $script:taskBackendState = $taskLine | ConvertFrom-Json
            $script:taskRead = $taskBackend.StandardOutput.ReadLineAsync()
            if ($script:taskBackendState.command_error) { throw $script:taskBackendState.command_error }
            $taskStaleState = ($script:taskState -eq 'STARTING' -and $script:taskBackendState.state -eq 'IDLE') -or
                ($script:taskState -eq 'SAVING' -and $script:taskBackendState.state -in @('IDLE','STARTING','RECORDING'))
            if (-not $taskStaleState) {
                $script:taskState = $script:taskBackendState.state
            }
            if ($script:taskState -eq 'RECORDING') {
                $taskStop.Enabled = $true
                foreach ($taskButton in $script:taskButtons.Values) { $taskButton.Enabled = $true }
            }
            if ($script:taskState -in @('SAVED','ERROR')) {
                $taskStop.Enabled = $false
                foreach ($taskButton in $script:taskButtons.Values) { $taskButton.Enabled = $false }
                if ($script:taskState -eq 'SAVED') {
                    $taskHeader.Text = '已保存'
                    $taskHeader.BackColor = [Drawing.Color]::DarkGreen
                    $taskStatus.Text = '文件已保存至：'+$script:taskEvidence
                    [Media.SystemSounds]::Asterisk.Play()
                } else { throw $script:taskBackendState.error }
                if ($script:taskClosing) { $taskForm.Close() }
            }
            $taskRecent.Items.Clear()
            foreach ($taskRow in $script:taskBackendState.recent) {
                [void]$taskRecent.Items.Add(('T+{0,8}s  {1,-20}  device_ms={2}  {3}' -f $taskRow.elapsed_s,$taskRow.event,$taskRow.device_ms_latest,$taskRow.source))
            }
        }
        if ($script:taskState -eq 'RECORDING') {
            $taskElapsed = ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($script:taskT0)).TotalSeconds
            $taskHeader.Text = ('录制中  T+{0:0.0} 秒' -f $taskElapsed)
            $taskHeader.BackColor = [Drawing.Color]::Firebrick
            $taskStatus.Text = ('T0: {0}   串口最新 device_ms: {1}   GAP: {2}   重连: {3}' -f $script:taskT0,$script:taskBackendState.device_ms,$script:taskBackendState.gaps,$script:taskBackendState.reconnects)
            if ($SelfTest) { $taskStatus.Text = '离线测试 / 模拟串口 — '+$taskStatus.Text }
        }
        foreach ($taskName in @($script:taskFlashUntil.Keys)) {
            if ([DateTime]::UtcNow -ge $script:taskFlashUntil[$taskName]) {
                $script:taskButtons[$taskName].BackColor = [Drawing.Color]::WhiteSmoke
                $script:taskFlashUntil.Remove($taskName)
            }
        }
        if ($SelfTest) {
            if (([DateTime]::UtcNow-$script:taskTestStart).TotalSeconds -gt 20) { throw 'Offline panel test timed out' }
            if ($script:taskTestStage -eq 0 -and $script:taskBackendState) {
                if (@($script:taskButtons.Values | Where-Object Enabled).Count) { throw 'Action buttons enabled before START' }
                if (Test-Path -LiteralPath (Join-Path $script:taskEvidence 'manual_events_raw.csv')) { throw 'Events created before START' }
                Save-TaskScreenshot 'panel_idle.png'
                $taskStart.PerformClick()
                $script:taskTestStage = 1
            } elseif ($script:taskTestStage -eq 1 -and $script:taskState -eq 'RECORDING' -and $script:taskBackendState.device_ms) {
                Save-TaskScreenshot 'panel_recording.png'
                foreach ($taskKey in @('E','L','C','V','H','J','S','D','Space')) {
                    $taskKeyCode = [Windows.Forms.Keys]::$taskKey
                    $taskKeyDown = $taskForm.GetType().GetMethod('OnKeyDown',[Reflection.BindingFlags]'Instance,NonPublic')
                    $taskKeyUp = $taskForm.GetType().GetMethod('OnKeyUp',[Reflection.BindingFlags]'Instance,NonPublic')
                    $taskKeyDown.Invoke($taskForm,[object[]]@(([Windows.Forms.KeyEventArgs]::new($taskKeyCode)).PSObject.BaseObject))
                    $taskKeyDown.Invoke($taskForm,[object[]]@(([Windows.Forms.KeyEventArgs]::new($taskKeyCode)).PSObject.BaseObject))
                    $taskKeyUp.Invoke($taskForm,[object[]]@(([Windows.Forms.KeyEventArgs]::new($taskKeyCode)).PSObject.BaseObject))
                }
                $script:taskTestStage = 2
            } elseif ($script:taskTestStage -eq 2 -and $script:taskBackendState.events -eq 10) {
                if ($script:taskHeld.Count -ne 0) { throw 'KeyUp did not clear held keys' }
                foreach ($taskDefinition in $taskDefinitions) { $script:taskButtons[$taskDefinition[1]].PerformClick() }
                $script:taskTestStage = 3
            } elseif ($script:taskTestStage -eq 3 -and $script:taskBackendState.events -eq 19) {
                $taskStop.PerformClick()
                $script:taskTestStage = 4
            } elseif ($script:taskTestStage -eq 4 -and $script:taskState -eq 'SAVED') {
                if ($script:taskBackendState.events -ne 20) { throw 'Expected START + 9 hotkeys + 9 buttons + END' }
                if ($taskRecent.Items.Count -ne 5) { throw 'Recent list must contain exactly 5 records' }
                Save-TaskScreenshot 'panel_saved.png'
                [IO.File]::WriteAllText((Join-Path $script:taskEvidence 'ui_checks.json'),'{"simulation_only":true,"prestart_buttons_disabled":true,"no_prestart_events":true,"all_nine_hotkeys":true,"all_nine_buttons":true,"held_key_deduplicated":true,"recent_five":true,"operator_stop_saved":true}',(New-Object Text.UTF8Encoding($false)))
                $script:taskTestStage = 5
                $taskForm.Close()
            }
        }
    } catch {
        $taskTimer.Stop()
        $taskHeader.Text = '采集异常 — 请保留现场记录'
        $taskHeader.BackColor = [Drawing.Color]::DarkRed
        $taskHeader.ForeColor = [Drawing.Color]::White
        $taskStatus.Text = $_.Exception.Message
        foreach ($taskButton in $script:taskButtons.Values) { $taskButton.Enabled = $false }
        if ($SelfTest) {
            [IO.File]::WriteAllText((Join-Path $script:taskEvidence 'ui_error.txt'),($_ | Out-String),(New-Object Text.UTF8Encoding($false)))
            $script:taskState = 'ERROR'
            $taskForm.Close()
        }
    }
})
$taskForm.Add_Shown({ $taskTimer.Start(); $taskForm.Activate() })
$taskForm.Add_FormClosing({param($sender,$eventArgs)
    if ($script:taskState -eq 'RECORDING') {
        $eventArgs.Cancel = $true
        $script:taskClosing = $true
        Stop-TaskRecording 'human_window_close'
    } elseif ($script:taskState -in @('STARTING','SAVING')) { $eventArgs.Cancel = $true; $script:taskClosing = $true }
})
try { [void]$taskForm.ShowDialog() }
finally {
    $taskTimer.Stop(); $taskTimer.Dispose()
    if (-not $taskBackend.HasExited) {
        Send-TaskCommand @{command='QUIT'}
        $taskBackend.StandardInput.Close()
        [void]$taskBackend.WaitForExit(5000)
    }
    if ($taskBackend.HasExited -and $taskErrorRead.IsCompleted) {
        $taskErrors = $taskErrorRead.GetAwaiter().GetResult()
        if ($taskErrors) { Write-Error $taskErrors -ErrorAction Continue }
    }
    $taskBackend.Dispose(); $taskForm.Dispose()
}
if ($SelfTest -and $script:taskTestStage -ne 5) { exit 1 }
