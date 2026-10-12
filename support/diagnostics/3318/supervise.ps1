param([Parameter(Mandatory)] [string]$Evidence, [Parameter(Mandatory)] [DateTime]$StartedUtc)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Evidence | Out-Null
$deadline = $StartedUtc.ToUniversalTime().AddMinutes(10)
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
    $captureEnd=[DateTime]::UtcNow.AddSeconds(150);if($captureEnd -gt $deadline){$captureEnd=$deadline}
    $tools=$null;$version=$null
    try {
    # Tool setup remains inside the 10-minute absolute task budget.
    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
        $setupDeadline = [DateTime]::UtcNow.AddSeconds(90)
        if ($setupDeadline -gt $deadline) { $setupDeadline = $deadline }
        # Chocolatey CLI 2 installs by package ID from a local source folder.
        # Retain and verify the exact approved package; let its original script install it.
        $localSource = Join-Path $Evidence ffmpeg-local-source
        New-Item -ItemType Directory -Force $localSource | Out-Null
        $packagePath = Join-Path $localSource ffmpeg.7.1.1.nupkg
        $remainingSeconds = [int][Math]::Floor(($setupDeadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remainingSeconds -lt 1) { throw "ENV_BLOCK: task deadline before pinned package download" }
        $downloadReceipt = [ordered]@{
            Source = "https://packages.chocolatey.org/ffmpeg.7.1.1.nupkg"; PackageId = "ffmpeg"; Version = "7.1.1"
            Path = $packagePath; ExpectedBytes = 28167676; ActualBytes = $null
            ExpectedSha256 = "6b0ed2ba5af35ddb41c8a9f25a7ea9e375733a7920c8a7a9167b5c846c61dbc0"; ActualSha256 = $null
            TimeoutSeconds = [Math]::Min(90, $remainingSeconds); Retries = 0
            SetupDeadlineUtc = $setupDeadline.ToString("o")
            StartedUtc = [DateTime]::UtcNow.ToString("o"); CompletedUtc = $null; Status = "DOWNLOADING"; Error = $null
        }
        $receiptPath = Join-Path $Evidence ffmpeg-package-download.json
        $downloadReceipt | ConvertTo-Json | Set-Content $receiptPath
        try {
            Invoke-WebRequest $downloadReceipt.Source -UseBasicParsing -OutFile $packagePath -TimeoutSec $downloadReceipt.TimeoutSeconds
            $downloadReceipt.ActualBytes = (Get-Item $packagePath).Length
            $downloadReceipt.ActualSha256 = (Get-FileHash $packagePath -Algorithm SHA256).Hash
            if ($downloadReceipt.ActualBytes -ne $downloadReceipt.ExpectedBytes -or
                $downloadReceipt.ActualSha256 -ne $downloadReceipt.ExpectedSha256) { throw "Pinned package size or SHA-256 mismatch" }
            if ((Get-ChildItem $Evidence -File -Recurse | Measure-Object Length -Sum).Sum -gt 768MB) { throw "768 MiB evidence budget reached" }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Task deadline reached during pinned package download" }
            if ([DateTime]::UtcNow -ge $setupDeadline) { throw "90-second capture tool setup deadline reached during pinned package download" }
            $downloadReceipt.Status = "VERIFIED_BYTES"
        } catch {
            $downloadReceipt.Status = "ENV_BLOCK"; $downloadReceipt.Error = "$_"
            $_ | Format-List * -Force | Out-File (Join-Path $Evidence ffmpeg-package-download-original-error.txt)
            throw "ENV_BLOCK: pinned ffmpeg package download/verification: $_"
        } finally {
            $downloadReceipt.CompletedUtc = [DateTime]::UtcNow.ToString("o")
            $downloadReceipt | ConvertTo-Json | Set-Content $receiptPath
        }
        $chocoPath = (Get-Command choco.exe -ErrorAction Stop).Source
        $tools = Start-Process $chocoPath -ArgumentList "install ffmpeg --version=7.1.1 --source=`"$localSource`" --yes --no-progress --limit-output" -PassThru -RedirectStandardOutput (Join-Path $Evidence ffmpeg-setup-stdout.txt) -RedirectStandardError (Join-Path $Evidence ffmpeg-setup-stderr.txt)
        $toolsReceipt = New-ExitReceipt $tools "ffmpeg-setup" $chocoPath
        @{ Id = $tools.Id; StartUtc = $tools.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence owned-tools.json)
        Wait-ToolExit $tools $toolsReceipt ([int][Math]::Max(0, [Math]::Min(90000, ($setupDeadline - [DateTime]::UtcNow).TotalMilliseconds)))
        $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
    }
    foreach ($toolName in @("ffmpeg", "ffprobe")) {
        if([DateTime]::UtcNow -ge $captureEnd){throw "RECORDER_BLOCK:150-second capture preflight deadline"}
        if ([DateTime]::UtcNow -ge $deadline) { throw "ENV_BLOCK: task deadline before $toolName version control" }
        $toolPath = (Get-Command "$toolName.exe" -ErrorAction Stop).Source
        $version = Start-Process $toolPath -ArgumentList "-version" -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $Evidence "$toolName-version-stdout-original.txt") -RedirectStandardError (Join-Path $Evidence "$toolName-version-stderr-original.txt")
        $versionReceipt = New-ExitReceipt $version "$toolName-version" $toolPath
        @{ Id = $version.Id; StartUtc = $version.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence "owned-$toolName-version.json")
        Wait-ToolExit $version $versionReceipt ([int][Math]::Max(0, [Math]::Min(5000, ($captureEnd - [DateTime]::UtcNow).TotalMilliseconds)))
        $versionOutput = Get-Content (Join-Path $Evidence "$toolName-version-stdout-original.txt") -Raw
        $bannerPattern = "(?m)^$toolName version 7\.1\.1(?:-essentials_build-www\.gyan\.dev)?(?:[ \t]|$)"
        $banner = [regex]::Match($versionOutput, $bannerPattern)
        @{ Tool = $toolName; ResolvedPath = $toolPath; ExpectedVersion = "7.1.1"; Pattern = $bannerPattern; Matched = $banner.Success; MatchedText = $banner.Value } |
            ConvertTo-Json | Set-Content (Join-Path $Evidence "$toolName-version-banner.json")
        if (-not $banner.Success) { throw "ENV_BLOCK: resolved $toolName lacks the exact anchored 7.1.1 version banner" }
    }
    @{Status="CAPTURE_QUALIFIED"}|ConvertTo-Json|Set-Content (Join-Path $Evidence capture-qualified.json)
    } catch {
        $captureError="$_";$cleanup=@()
        foreach($entry in @(@{Process=$tools;Receipt=$toolsReceipt},@{Process=$version;Receipt=$versionReceipt})){
            $p=$entry.Process;$r=$entry.Receipt;if(-not $p){continue}
            if(-not $r -or -not $r.HandleAcquired){throw "ENV_BLOCK: capture subprocess original handle unknown"}
            if(-not $p.HasExited){if($p.Path -ne $r.ActualPath -or $p.StartTime.ToUniversalTime().ToString("o") -ne $r.StartUtc){throw "ENV_BLOCK: capture subprocess cleanup identity changed"};$p.Kill()}
            $wait=$p.WaitForExit(5000);Complete-ExitReceipt $p $r $wait;$cleanup+=$r
            if(-not $wait -or -not $p.HasExited -or $r.ExitCodeType -ne "System.Int32"){throw "ENV_BLOCK: capture subprocess cleanup UNKNOWN"}
        }
        @{Status="RECORDER_BLOCK";Error=$captureError;Cleanup=$cleanup;NativeScenarioMayContinue=$true}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $Evidence recorder-preflight-block.json)
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
            $workerReceipt | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Evidence worker-timeout-before-kill.json) -Encoding UTF8
            $cleanupErrors = @(); $postKillWait = $null
            try {
                if ($worker.Path -ne $workerReceipt.ActualPath -or $worker.StartTime.ToUniversalTime().ToString("o") -ne $workerReceipt.StartUtc) { throw "Exact worker cleanup identity changed" }
                $worker.Kill(); $postKillWait = $worker.WaitForExit(5000)
            } catch { $cleanupErrors += "$_" }
            Complete-ExitReceipt $worker $workerReceipt $postKillWait
            $liveWorker = Get-Process -Id $workerReceipt.Pid -ErrorAction SilentlyContinue
            $cleanupStatus = if ($workerReceipt.WaitBoolean -eq $true -and $workerReceipt.HasExited -eq $true -and $workerReceipt.ExitCodeType -eq "System.Int32" -and -not $workerReceipt.ExitCodeIsNull) { "ORIGINAL_WORKER_EXIT_CONFIRMED" } else { "UNKNOWN" }
            @{ Status = $cleanupStatus; Process = $workerReceipt; ObservedUtc = [DateTime]::UtcNow.ToString("o"); Errors = $cleanupErrors; FinalIdentity = if ($liveWorker) { $liveWorker | Select-Object Id,Path,StartTime } else { $null } } |
                ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Evidence worker-cleanup-final.json) -Encoding UTF8
            [ordered]@{ Status = "ENV_BLOCK"; Error = "10-minute absolute task budget exhausted; five minutes of cleanup/upload reserve retained"; ProductVerdict = "NONE" } |
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
