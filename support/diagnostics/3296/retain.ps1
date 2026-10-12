param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference="Continue"
$env:PATH=[Environment]::GetEnvironmentVariable("PATH","Machine")+";"+[Environment]::GetEnvironmentVariable("PATH","User")+";"+$env:PATH
New-Item -ItemType Directory -Force $Evidence|Out-Null
Start-Transcript (Join-Path $Evidence retention-original.txt)
$retentionDeadline=[DateTime]::UtcNow.AddSeconds(105)
Get-Process|Select-Object Id,ProcessName,Path,StartTime,MainWindowHandle|ConvertTo-Json -Depth 4|Set-Content (Join-Path $Evidence final-processes.json)
# The scenario may have been killed at its absolute deadline. Match all three identities.
$owned=@()
$ownedPath=Join-Path $Evidence owned-apps.json
if(Test-Path $ownedPath){$owned+=@(Get-Content $ownedPath -Raw|ConvertFrom-Json)}
foreach($file in Get-ChildItem $Evidence -Filter 'owned-*.json'|Where-Object Name -ne 'owned-apps.json'){
 try{$owned+=@(Get-Content $file.FullName -Raw|ConvertFrom-Json)}catch{"Owned receipt read failure $($file.Name): $_"|Add-Content (Join-Path $Evidence cleanup-errors.txt)}
}
foreach($a in $owned){
 $receipt=[ordered]@{Owned=$a;Utc=[DateTime]::UtcNow.ToString('o');IdentityMatched=$false;CloseRequested=$null;GraceWait=$null;KillRequested=$false;FinalWait=$null;HasExited=$null;ExitCode=$null;Status='ABSENT';Error=$null}
 try{
  $p=Get-Process -Id $a.Id -ErrorAction SilentlyContinue
  if($p){
   if(-not $a.Path -or $p.Path -ne $a.Path -or $p.StartTime.ToUniversalTime().ToString('o') -ne $a.StartUtc){$receipt.Status='IDENTITY_MISMATCH_UNTOUCHED'}
   else{
    $receipt.IdentityMatched=$true;$null=$p.Handle
    $receipt.CloseRequested=$p.CloseMainWindow();$receipt.GraceWait=$p.WaitForExit(2000)
    if(-not $receipt.GraceWait){$receipt.KillRequested=$true;$p.Kill();$receipt.FinalWait=$p.WaitForExit(2000)}else{$receipt.FinalWait=$true}
    $receipt.HasExited=$p.HasExited;if($receipt.FinalWait){$receipt.ExitCode=$p.ExitCode}
    $receipt.Status=if($receipt.FinalWait -and $receipt.HasExited){'EXIT_OBSERVED'}else{'CLEANUP_UNCONFIRMED'}
   }
  }
 }catch{$receipt.Status='CLEANUP_ERROR';$receipt.Error="$_"}
 $receipt|ConvertTo-Json -Depth 8 -Compress|Add-Content (Join-Path $Evidence cleanup-original.jsonl)
}
# Recorders are intrinsically capped at 10 seconds; wait briefly for normal finalization.
Start-Sleep -Seconds 1
function Invoke-RetainedMediaTool($Tool, $Arguments, $Prefix, $Timeout = 5) {
    if ([DateTime]::UtcNow.AddSeconds($Timeout) -ge $retentionDeadline) {
        "NOT_RUN: retention deadline" | Set-Content "$Prefix-status.txt"
        return
    }
    $receipt = [ordered]@{ ExpectedPath = $null; ActualPath = $null; Pid = $null; StartUtc = $null;
        HandleAcquired = $false; HandleValue = $null; WaitBoolean = $null; HasExited = $null;
        ExitCodeIsNull = $true; ExitCodeType = $null; ExitCodeValue = $null; Status = "UNKNOWN"; Errors = @() }
    $p = $null
    try {
        $receipt.ExpectedPath = (Get-Command $Tool -ErrorAction Stop).Source
        $p = Start-Process $receipt.ExpectedPath -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardError "$Prefix-stderr-original.txt" -RedirectStandardOutput "$Prefix-stdout-original.txt" -ErrorAction Stop
        # Cache the original Process handle immediately, before identity queries or waiting.
        $cachedHandle = $p.Handle
        $receipt.HandleValue = $cachedHandle.ToInt64()
        $receipt.HandleAcquired = $cachedHandle -ne [IntPtr]::Zero
        $receipt.Pid = $p.Id; $receipt.StartUtc = $p.StartTime.ToUniversalTime().ToString("o"); $receipt.ActualPath = $p.Path
        $receipt | ConvertTo-Json -Depth 5 | Set-Content "$Prefix-process-exit.json"
        if ($receipt.HandleAcquired) { $receipt.WaitBoolean = $p.WaitForExit($Timeout * 1000) }
        else { $receipt.Errors += "Process handle unavailable; exit status unknown" }
    } catch { $receipt.Errors += "Launch/handle/identity/wait: $_" }
    if ($p) {
        try { $receipt.HasExited = $p.HasExited } catch { $receipt.Errors += "HasExited: $_" }
        try {
            $code = $p.ExitCode
            $receipt.ExitCodeIsNull = $null -eq $code
            if ($null -ne $code) { $receipt.ExitCodeType = $code.GetType().FullName; $receipt.ExitCodeValue = $code }
        } catch { $receipt.Errors += "ExitCode: $_" }
    }
    if ($receipt.HandleAcquired -and $receipt.WaitBoolean -eq $true -and $receipt.HasExited -eq $true -and
        -not $receipt.ExitCodeIsNull -and $receipt.ExitCodeType -eq "System.Int32") {
        $receipt.Status = if ($receipt.ExitCodeValue -eq 0) { "EXIT_ZERO" } else { "EXIT_NONZERO" }
    } elseif ($receipt.WaitBoolean -eq $false -and $receipt.HasExited -eq $false) { $receipt.Status = "TIMED_OUT" }
    $receipt | ConvertTo-Json -Depth 5 | Set-Content "$Prefix-process-exit.json"
    switch ($receipt.Status) {
        "EXIT_ZERO" { "ExitCode=0" | Set-Content "$Prefix-status.txt" }
        "EXIT_NONZERO" { "ExitCode=$($receipt.ExitCodeValue)" | Set-Content "$Prefix-status.txt" }
        "TIMED_OUT" { "TIMEOUT" | Set-Content "$Prefix-status.txt"; $p.Kill() }
        default {
            "ENV_BLOCK: process exit status unknown" | Set-Content "$Prefix-status.txt"
            if ($p -and $receipt.HasExited -eq $false) {
                try { $p.Kill() } catch { "Unknown observer cleanup: $_" | Add-Content "$Prefix-status.txt" }
            }
        }
    }
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

Stop-Transcript
Get-ChildItem $Evidence -File -Recurse | Where-Object Name -ne "evidence-hashes.json" | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Evidence evidence-hashes.json)
# Source manifests above hash retained evidence; no private app security context is uploaded.
