param([Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:taskState = $null
$script:taskEvidence = $Evidence
$taskForm = New-Object System.Windows.Forms.Form
$taskForm.Text = 'v26 MANUAL annotations - actual actions only'
$taskForm.Size = New-Object System.Drawing.Size(590,380)
$taskForm.StartPosition = 'CenterScreen'
$taskForm.TopMost = $true
$taskForm.ShowInTaskbar = $true
$taskForm.WindowState = 'Normal'
$taskInfo = New-Object System.Windows.Forms.Label
$taskInfo.Location = New-Object System.Drawing.Point(15,10)
$taskInfo.Size = New-Object System.Drawing.Size(550,95)
$taskInfo.Font = New-Object System.Drawing.Font('Segoe UI',11)
$taskInfo.Text = 'Waiting for firmware / protocol T0. Buttons record HUMAN actions.'
$taskForm.Controls.Add($taskInfo)
$taskLast = New-Object System.Windows.Forms.Label
$taskLast.Location = New-Object System.Drawing.Point(15,280)
$taskLast.Size = New-Object System.Drawing.Size(550,55)
$taskForm.Controls.Add($taskLast)
function Read-TaskState {
    try { $script:taskState = Get-Content -LiteralPath (Join-Path $script:taskEvidence 'live_state.json') -Raw | ConvertFrom-Json } catch {}
}
function Write-TaskLabel([string]$EventName) {
    Read-TaskState
    if (-not $script:taskState.t0) {
        $taskLast.Text = 'Not started yet. Wait for PROTOCOL T0.'
        return
    }
    $taskNow = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8))
    $taskT0 = [DateTimeOffset]::Parse($script:taskState.t0)
    $taskElapsed = ($taskNow-$taskT0).TotalSeconds.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)
    $taskFields = @($EventName,$taskNow.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'),$taskElapsed,[string]$script:taskState.device_ms,[string]$script:taskState.phase,'human_button')
    [IO.File]::AppendAllText((Join-Path $script:taskEvidence 'manual_events_raw.csv'),([string]::Join(',',$taskFields)+"`n"),(New-Object Text.UTF8Encoding($false)))
    $taskLast.Text = 'Recorded: '+$EventName+' at T+'+$taskElapsed+' s'
}
$taskButtons = @(
    @('ENTER - person enters', 'ENTER',15,115),
    @('LEAVE - person leaves', 'LEAVE',295,115),
    @('CHAIR starts', 'CHAIR_START',15,170),
    @('CHAIR ends', 'CHAIR_END',295,170),
    @('Confirm EMPTY now', 'EMPTY_CONFIRMED',15,225),
    @('Finish annotations', 'ANNOTATIONS_FINISHED',295,225)
)
foreach ($taskDefinition in $taskButtons) {
    $taskButton = New-Object System.Windows.Forms.Button
    $taskButton.Text = $taskDefinition[0]
    $taskButton.Tag = $taskDefinition[1]
    $taskButton.Location = New-Object System.Drawing.Point($taskDefinition[2],$taskDefinition[3])
    $taskButton.Size = New-Object System.Drawing.Size(265,43)
    $taskButton.Add_Click({param($sender,$eventArgs) Write-TaskLabel ([string]$sender.Tag)})
    $taskForm.Controls.Add($taskButton)
}
$taskTimer = New-Object System.Windows.Forms.Timer
$taskTimer.Interval = 250
$taskTimer.Add_Tick({
    Read-TaskState
    if ($script:taskState.t0) {
        $taskElapsed = ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($script:taskState.t0)).TotalSeconds
        $taskInfo.Text = ('T+{0:0.0}s  |  phase: {1}' -f $taskElapsed,$script:taskState.phase)+"`n"+'T0: '+$script:taskState.t0+"`n"+'Device ms (latest): '+$script:taskState.device_ms
    }
})
$taskTimer.Start()
$taskForm.Add_Shown({
    $taskForm.Activate()
    [IO.File]::WriteAllText((Join-Path $script:taskEvidence 'manual_panel_ready.json'),('{"shown":true,"pid":'+$PID+'}'))
})
$taskForm.Add_FormClosed({$taskTimer.Stop();$taskTimer.Dispose()})
[void]$taskForm.ShowDialog()
