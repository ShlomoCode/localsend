param([Parameter(Mandatory)] [string]$Evidence)
$ErrorActionPreference = "Continue"
$env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User") + ";" + $env:PATH
New-Item -ItemType Directory -Force $Evidence | Out-Null
Start-Transcript (Join-Path $Evidence retention-original.txt)
$retentionDeadline = [DateTime]::UtcNow.AddSeconds(105)
Get-Process | Select-Object Id, ProcessName, Path, StartTime, MainWindowHandle |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Evidence final-processes.json)
Get-AppxPackage LocalSend.App | Format-List * | Out-File (Join-Path $Evidence final-package-raw.txt)
$allProcesses = @(Get-CimInstance Win32_Process)
$allProcesses | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Evidence precleanup-process-tree.json)
# Freeze only this scenario's tracked descendant tree before media validation.
$ownedIds = [System.Collections.Generic.HashSet[int]]::new()
$oldestOwnedStart = [DateTime]::UtcNow
foreach ($recordFile in @("owned-worker.json", "owned-installer.json", "owned-tools.json")) {
    $recordPath = Join-Path $Evidence $recordFile
    if (-not (Test-Path $recordPath)) { continue }
    $record = Get-Content $recordPath -Raw | ConvertFrom-Json
    $start = ([DateTime]$record.StartUtc).ToUniversalTime()
    $current = Get-Process -Id $record.Id -ErrorAction SilentlyContinue
    # Refuse a reused PID. If the original parent has exited, its captured child links remain useful.
    if ($current -and [Math]::Abs(($current.StartTime.ToUniversalTime() - $start).TotalSeconds) -gt 1) { continue }
    $null = $ownedIds.Add([int]$record.Id)
    if ($start -lt $oldestOwnedStart) { $oldestOwnedStart = $start }
}
for ($generation = 0; $generation -lt 8; $generation++) {
    foreach ($p in $allProcesses) {
        if ($ownedIds.Contains([int]$p.ParentProcessId) -and $p.CreationDate.ToUniversalTime() -ge $oldestOwnedStart.AddSeconds(-1)) { $null = $ownedIds.Add([int]$p.ProcessId) }
    }
}
foreach ($p in $allProcesses) {
    if ($ownedIds.Contains([int]$p.ProcessId) -and $p.Name -ne "explorer.exe" -and $p.ProcessId -ne $PID) {
        $current = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($current -and [Math]::Abs(($current.StartTime.ToUniversalTime() - $p.CreationDate.ToUniversalTime()).TotalSeconds) -le 1) {
            $p | Format-List * | Out-File (Join-Path $Evidence cleanup-owned-descendants.txt) -Append
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Continue
        }
    }
}
# Finalize surviving recorders by their 120-second capture limit where possible.
# Fragmented MP4 preserves completed original frames if a hard deadline killed the driver.
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ffmpeg.exe" -and $_.CommandLine.Contains($Evidence) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Continue }
function Invoke-RetainedMediaTool($Tool, $Arguments, $Prefix, $Timeout = 5) {
    if ([DateTime]::UtcNow.AddSeconds($Timeout) -ge $retentionDeadline) {
        "NOT_RUN: retention deadline" | Set-Content "$Prefix-status.txt"
        return
    }
    $p = Start-Process $Tool -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardError "$Prefix-stderr-original.txt" -RedirectStandardOutput "$Prefix-stdout-original.txt"
    if (-not $p.WaitForExit($Timeout * 1000)) { $p.Kill(); "TIMEOUT" | Set-Content "$Prefix-status.txt" }
    else { "ExitCode=$($p.ExitCode)" | Set-Content "$Prefix-status.txt" }
}
# Capture decode errors verbatim and one original frame. No edited/accelerated videos.
if ((Get-Command ffmpeg.exe -ErrorAction SilentlyContinue) -and (Get-Command ffprobe.exe -ErrorAction SilentlyContinue)) {
    foreach ($clip in Get-ChildItem $Evidence -Filter *.mp4) {
        Invoke-RetainedMediaTool ffmpeg.exe "-threads 2 -v error -i `"$($clip.FullName)`" -f null -" "$($clip.FullName)-decode" 5
        Invoke-RetainedMediaTool ffprobe.exe "-v error -show_format -show_streams -of json `"$($clip.FullName)`"" "$($clip.FullName)-probe" 2
        Invoke-RetainedMediaTool ffmpeg.exe "-y -threads 2 -v error -i `"$($clip.FullName)`" -frames:v 1 `"$($clip.FullName)-first-frame.png`"" "$($clip.FullName)-frame" 2
    }
} else {
    "ENV_BLOCK: media tools unavailable in retention process; no clip has qualified decoding validation." |
        Set-Content (Join-Path $Evidence media-validation-unavailable.txt)
}
if (Test-Path (Join-Path $Evidence owned-install.txt)) {
    $owned = (Get-Content (Join-Path $Evidence owned-install.txt) -Raw).Trim()
    Get-Process localsend_app -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $owned localsend_app.exe) -or $_.Path -like "$env:USERPROFILE\Issue3456Portable\*" } |
        Stop-Process -Force -ErrorAction Continue
    # Hosted runner is disposable. Preserve installation/package bytes and identity; no package edits or synthetic registration.
    "Owned process cleanup only; disposable hosted machine retains registration until runner disposal." | Set-Content (Join-Path $Evidence cleanup-scope.txt)
}
Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-AppXDeploymentServer/Operational"; StartTime = (Get-Date).AddMinutes(-25) } -MaxEvents 100 -ErrorAction Continue |
    Format-List * | Out-File (Join-Path $Evidence AppXDeployment-original.txt)
Stop-Transcript
Get-ChildItem $Evidence -File -Recurse | Where-Object Name -ne "evidence-hashes.json" | Get-FileHash -Algorithm SHA256 | Select-Object Path, Hash |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Evidence evidence-hashes.json)
