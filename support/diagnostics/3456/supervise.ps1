param([Parameter(Mandatory)] [string]$Evidence, [Parameter(Mandatory)] [DateTime]$StartedUtc)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Evidence | Out-Null
$deadline = $StartedUtc.ToUniversalTime().AddMinutes(19)
Start-Transcript (Join-Path $Evidence supervisor-original.txt)
try {
    # Tool setup is inside the same 20-minute task budget. No app rebuilds or alternate image.
    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
        $tools = Start-Process choco.exe -ArgumentList "install ffmpeg --version=7.1.1 --yes --no-progress --limit-output" -PassThru -RedirectStandardOutput (Join-Path $Evidence ffmpeg-setup-stdout.txt) -RedirectStandardError (Join-Path $Evidence ffmpeg-setup-stderr.txt)
        @{ Id = $tools.Id; StartUtc = $tools.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence owned-tools.json)
        if (-not $tools.WaitForExit(90000)) { $tools.Kill(); throw "ENV_BLOCK: capture tool setup deadline" }
        if ($tools.ExitCode -ne 0) { throw "ENV_BLOCK: capture tool setup failed" }
        $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
    }
    & ffmpeg.exe -version 2>&1 | Out-File (Join-Path $Evidence ffmpeg-version.txt)
    $args = "-NoProfile -MTA -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot scenario.ps1)`" -Evidence `"$Evidence`" -Deadline `"$($deadline.ToString("o"))`""
    $worker = Start-Process powershell.exe -ArgumentList $args -PassThru -RedirectStandardOutput (Join-Path $Evidence worker-stdout-original.txt) -RedirectStandardError (Join-Path $Evidence worker-stderr-original.txt)
    Set-Content (Join-Path $Evidence worker-pid.txt) $worker.Id
    @{ Id = $worker.Id; StartUtc = $worker.StartTime.ToUniversalTime().ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $Evidence owned-worker.json)
    while (-not $worker.WaitForExit(500)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            $worker.Kill()
            [ordered]@{ Status = "ENV_BLOCK"; Error = "19-minute absolute task budget exhausted; at least five minutes of cleanup/upload reserve retained"; ProductVerdict = "NONE" } |
                ConvertTo-Json | Set-Content (Join-Path $Evidence supervisor-timeout.json)
            exit 2
        }
    }
    exit $worker.ExitCode
} catch {
    $_ | Format-List * -Force | Out-File (Join-Path $Evidence supervisor-original-error.txt)
    [ordered]@{ Status = "ENV_BLOCK"; Error = "$_"; ProductVerdict = "NONE" } | ConvertTo-Json | Set-Content (Join-Path $Evidence supervisor-result.json)
    exit 2
} finally { Stop-Transcript }
