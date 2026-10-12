param([Parameter(Mandatory)] [string]$Evidence, [Parameter(Mandatory)] [DateTime]$StartedUtc)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Evidence | Out-Null
$deadline = $StartedUtc.ToUniversalTime().AddMinutes(19)
Start-Transcript (Join-Path $Evidence supervisor-original.txt)
function New-ExitReceipt($Process, $Name, $ExpectedPath) {
    try { $cachedHandle = $Process.Handle; $handleError = $null }
    catch { $cachedHandle = [IntPtr]::Zero; $handleError = "$_" }
    $receipt = [ordered]@{ Name = $Name; Pid = $null; ExpectedPath = $ExpectedPath; ActualPath = $null; StartUtc = $null;
        HandleAcquired = $false; HandleValue = $null; WaitBoolean = $null; HasExited = $null;
        ExitCodeIsNull = $true; ExitCodeType = $null; ExitCodeValue = $null; Status = "UNKNOWN"; Errors = @() }
    # Hold the original Process object's handle before waiting. Windows PowerShell's
    # Start-Process redirection path can otherwise expose a null ExitCode (issue 5421).
    $receipt.HandleValue = $cachedHandle.ToInt64()
    $receipt.HandleAcquired = $cachedHandle -ne [IntPtr]::Zero
    if ($handleError) { $receipt.Errors += "Handle: $handleError" }
    try { $receipt.Pid = $Process.Id; $receipt.StartUtc = $Process.StartTime.ToUniversalTime().ToString("o"); $receipt.ActualPath = $Process.Path }
    catch { $receipt.Errors += "Identity: $_" }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence "$Name-process-exit.json")
    return $receipt
}
function Complete-ExitReceipt($Process, $Receipt, $WaitBoolean) {
    $Receipt.WaitBoolean = $WaitBoolean
    try { $Receipt.HasExited = $Process.HasExited } catch { $Receipt.Errors += "HasExited: $_" }
    try {
        $code = $Process.ExitCode
        $Receipt.ExitCodeIsNull = $null -eq $code
        if ($null -ne $code) { $Receipt.ExitCodeType = $code.GetType().FullName; $Receipt.ExitCodeValue = $code }
    } catch { $Receipt.Errors += "ExitCode: $_" }
    if ($Receipt.HandleAcquired -and $WaitBoolean -eq $true -and $Receipt.HasExited -eq $true -and
        -not $Receipt.ExitCodeIsNull -and $Receipt.ExitCodeType -eq "System.Int32") {
        $Receipt.Status = if ($Receipt.ExitCodeValue -eq 0) { "EXIT_ZERO" } else { "EXIT_NONZERO" }
    } elseif ($WaitBoolean -eq $false -and $Receipt.HasExited -eq $false) { $Receipt.Status = "TIMED_OUT" }
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence "$($Receipt.Name)-process-exit.json")
}
function Wait-ToolExit($Process, $Receipt, $Milliseconds) {
    $wait = $null
    if (-not $Receipt.HandleAcquired) { throw "ENV_BLOCK: $($Receipt.Name) process handle unknown; exit status unknown" }
    try { $wait = $Process.WaitForExit($Milliseconds) } catch { $Receipt.Errors += "WaitForExit: $_" }
    Complete-ExitReceipt $Process $Receipt $wait
    if ($Receipt.Status -eq "TIMED_OUT") { $Process.Kill(); throw "ENV_BLOCK: $($Receipt.Name) deadline" }
    if ($Receipt.Status -eq "UNKNOWN") { throw "ENV_BLOCK: $($Receipt.Name) process exit status unknown" }
    if ($Receipt.Status -eq "EXIT_NONZERO") { throw "ENV_BLOCK: $($Receipt.Name) exited with exact code $($Receipt.ExitCodeValue)" }
}
try {
    # Tool setup remains inside the 19-minute absolute task budget.
    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
        $chocoPath = (Get-Command choco.exe -ErrorAction Stop).Source
        $tools = Start-Process $chocoPath -ArgumentList "install ffmpeg --version=7.1.1 --yes --no-progress --limit-output" -PassThru -RedirectStandardOutput (Join-Path $Evidence ffmpeg-setup-stdout.txt) -RedirectStandardError (Join-Path $Evidence ffmpeg-setup-stderr.txt)
        $toolsReceipt = New-ExitReceipt $tools "ffmpeg-setup" $chocoPath
        @{ Id = $tools.Id; StartUtc = $tools.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence owned-tools.json)
        Wait-ToolExit $tools $toolsReceipt ([int][Math]::Max(0, [Math]::Min(90000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)))
        $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
    }
    foreach ($toolName in @("ffmpeg", "ffprobe")) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "ENV_BLOCK: task deadline before $toolName version control" }
        $toolPath = (Get-Command "$toolName.exe" -ErrorAction Stop).Source
        $version = Start-Process $toolPath -ArgumentList "-version" -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $Evidence "$toolName-version-stdout-original.txt") -RedirectStandardError (Join-Path $Evidence "$toolName-version-stderr-original.txt")
        $versionReceipt = New-ExitReceipt $version "$toolName-version" $toolPath
        @{ Id = $version.Id; StartUtc = $version.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence "owned-$toolName-version.json")
        Wait-ToolExit $version $versionReceipt ([int][Math]::Max(0, [Math]::Min(5000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)))
    }
    $args = "-NoProfile -MTA -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot scenario.ps1)`" -Evidence `"$Evidence`" -Deadline `"$($deadline.ToString("o"))`""
    $workerPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $worker = Start-Process $workerPath -ArgumentList $args -PassThru -RedirectStandardOutput (Join-Path $Evidence worker-stdout-original.txt) -RedirectStandardError (Join-Path $Evidence worker-stderr-original.txt)
    $workerReceipt = New-ExitReceipt $worker "worker" $workerPath
    Set-Content (Join-Path $Evidence worker-pid.txt) $worker.Id
    @{ Id = $worker.Id; StartUtc = $worker.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence owned-worker.json)
    if (-not $workerReceipt.HandleAcquired) { throw "ENV_BLOCK: worker process handle unknown; exit status unknown" }
    while ($true) {
        try { $workerWait = $worker.WaitForExit(500) } catch {
            $workerReceipt.Errors += "WaitForExit: $_"
            Complete-ExitReceipt $worker $workerReceipt $null
            throw "ENV_BLOCK: worker wait observer failed; exit status unknown"
        }
        if ($workerWait) { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            Complete-ExitReceipt $worker $workerReceipt $workerWait
            $worker.Kill()
            [ordered]@{ Status = "ENV_BLOCK"; Error = "19-minute absolute task budget exhausted; at least five minutes of cleanup/upload reserve retained"; ProductVerdict = "NONE" } |
                ConvertTo-Json | Set-Content (Join-Path $Evidence supervisor-timeout.json)
            exit 2
        }
    }
    Complete-ExitReceipt $worker $workerReceipt $workerWait
    if ($workerReceipt.Status -eq "UNKNOWN") { throw "ENV_BLOCK: worker process exit status unknown" }
    exit ([int]$workerReceipt.ExitCodeValue)
} catch {
    $_ | Format-List * -Force | Out-File (Join-Path $Evidence supervisor-original-error.txt)
    [ordered]@{ Status = "ENV_BLOCK"; Error = "$_"; ProductVerdict = "NONE" } | ConvertTo-Json | Set-Content (Join-Path $Evidence supervisor-result.json)
    exit 2
} finally { Stop-Transcript }
