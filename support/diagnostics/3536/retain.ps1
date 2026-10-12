param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference="Continue"
$env:PATH=[Environment]::GetEnvironmentVariable("PATH","Machine")+";"+[Environment]::GetEnvironmentVariable("PATH","User")+";"+$env:PATH
New-Item -ItemType Directory -Force $Evidence|Out-Null
Start-Transcript (Join-Path $Evidence retention-original.txt)
$retentionDeadline=[DateTime]::UtcNow.AddSeconds(105)
function Check-Retention {if([DateTime]::UtcNow -ge $retentionDeadline){throw "ENV_BLOCK: retention absolute deadline"}}
function Save-Retention($Value,$Path){$Value|ConvertTo-Json -Depth 12|Set-Content $Path -Encoding UTF8}
Check-Retention
Get-Process|Select-Object Id,ProcessName,Path,StartTime,MainWindowHandle|ConvertTo-Json -Depth 4|Set-Content (Join-Path $Evidence final-processes.json)
Check-Retention
$ownedPath=Join-Path $Evidence owned-apps.json
if(Test-Path $ownedPath){foreach($a in @(Get-Content $ownedPath -Raw -Encoding UTF8|ConvertFrom-Json)){
 Check-Retention;$receipt=@{App=$a;GraceWait=$null;ForceWait=$null;HasExited=$null;OwnedAbsent=$false;Status="UNKNOWN";Errors=@()}
 try{
  $p=Get-Process -Id $a.Id -ErrorAction SilentlyContinue
  if($p -and $p.Path -eq $a.Path -and $p.StartTime.ToUniversalTime().ToString("o") -eq $a.StartUtc){
   $null=$p.Handle;$p.CloseMainWindow()|Out-Null;$receipt.GraceWait=$p.WaitForExit(3000)
   if(-not $receipt.GraceWait){$p.Kill();$receipt.ForceWait=$p.WaitForExit(3000)};$receipt.HasExited=$p.HasExited
  }
  $live=Get-Process -Id $a.Id -ErrorAction SilentlyContinue
  $receipt.OwnedAbsent=-not ($live -and $live.Path -eq $a.Path -and $live.StartTime.ToUniversalTime().ToString("o") -eq $a.StartUtc)
  $receipt.Status=if($receipt.OwnedAbsent){"OWNED_ABSENT"}else{"SURVIVING_OWNED_PROCESS"}
 }catch{$receipt.Errors+="$_"}finally{Save-Retention $receipt (Join-Path $Evidence "retention-cleanup-$($a.Id).json")}
}}
# Recover only exact phase workers if the outer supervisor interrupted their owner.
foreach($recordFile in Get-ChildItem $Evidence -Filter "*-owned-process.json"){
 Check-Retention;$r=Get-Content $recordFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json
 $receipt=@{Original=$r;Status="UNKNOWN";HandleAcquired=$false;WaitBoolean=$null;HasExited=$null;ExitCodeType=$null;ExitCodeValue=$null;Errors=@()}
 try{
  $p=Get-Process -Id $r.Pid -ErrorAction SilentlyContinue
  if(-not $p){$receipt.Status="PID_ABSENT_AT_RETENTION"}
  elseif($p.Path -eq $r.ActualPath -and $p.StartTime.ToUniversalTime().ToString("o") -eq $r.StartUtc){
   $h=$p.Handle;$receipt.HandleAcquired=$h -ne [IntPtr]::Zero
   if($receipt.HandleAcquired){$p.Kill();$receipt.WaitBoolean=$p.WaitForExit([int][Math]::Max(0,[Math]::Min(5000,($retentionDeadline-[DateTime]::UtcNow).TotalMilliseconds)))}
   $receipt.HasExited=$p.HasExited
   if($receipt.HasExited){$code=$p.ExitCode;if($null -ne $code){$receipt.ExitCodeType=$code.GetType().FullName;$receipt.ExitCodeValue=$code}}
   if($receipt.HandleAcquired -and $receipt.WaitBoolean -eq $true -and $receipt.HasExited -eq $true -and $receipt.ExitCodeType -eq "System.Int32"){$receipt.Status="EXACT_PHASE_WORKER_EXIT_CONFIRMED"}
  }else{$receipt.Status="IDENTITY_DIFFERENT_OR_UNAVAILABLE_NO_KILL"}
 }catch{$receipt.Errors+="$_"}finally{Save-Retention $receipt (Join-Path $Evidence "$($recordFile.BaseName)-retention-cleanup.json")}
}
$finalizedClips=@()
foreach($recordFile in Get-ChildItem $Evidence -Filter "recorder-*.json"){
 Check-Retention;$r=Get-Content $recordFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json
 $receipt=@{Original=$r;WaitBoolean=$null;HandleAcquired=$false;HasExited=$null;ExitCodeValue=$null;ExitCodeType=$null;Finalized=$false;Status="UNKNOWN";Errors=@()}
 try{
  $p=Get-Process -Id $r.Pid -ErrorAction SilentlyContinue
  $same=$p -and $p.Path -eq $r.Path -and $p.StartTime.ToUniversalTime().ToString("o") -eq $r.StartUtc
  if($r.Finalized -eq $true -and $r.Status -eq "EXIT_ZERO" -and -not $same){$receipt.Finalized=$true;$receipt.Status="ORIGINAL_EXIT_ZERO_RECEIPT"}
  elseif($same){
   $h=$p.Handle;$receipt.HandleAcquired=$h -ne [IntPtr]::Zero
   $remaining=[int][Math]::Max(0,[Math]::Min(16000,($retentionDeadline-[DateTime]::UtcNow).TotalMilliseconds))
   if($receipt.HandleAcquired){$receipt.WaitBoolean=$p.WaitForExit($remaining)}
   $receipt.HasExited=$p.HasExited
   if($receipt.WaitBoolean -eq $true){$code=$p.ExitCode;if($null -ne $code){$receipt.ExitCodeValue=$code;$receipt.ExitCodeType=$code.GetType().FullName}}
   if($receipt.HandleAcquired -and $receipt.WaitBoolean -eq $true -and $receipt.HasExited -eq $true -and $receipt.ExitCodeType -eq "System.Int32" -and $receipt.ExitCodeValue -eq 0){$receipt.Finalized=$true;$receipt.Status="RECOVERED_EXIT_ZERO"}
   elseif($receipt.HasExited -eq $false){$receipt.Status="TIMED_OUT";$p.Kill();$receipt.CleanupWait=$p.WaitForExit(3000)}
  }
 }catch{$receipt.Errors+="$_"}finally{Save-Retention $receipt (Join-Path $Evidence "$($recordFile.BaseName)-retention.json")}
 if($receipt.Finalized -and (Test-Path -LiteralPath $r.ClipPath)){$finalizedClips+=Get-Item -LiteralPath $r.ClipPath}
}
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
    foreach ($clip in $finalizedClips) {
        Invoke-RetainedMediaTool ffmpeg.exe "-threads 2 -v error -i `"$($clip.FullName)`" -f null -" "$($clip.FullName)-decode" 5
        Invoke-RetainedMediaTool ffprobe.exe "-v error -show_format -show_streams -of json `"$($clip.FullName)`"" "$($clip.FullName)-probe" 2
        Invoke-RetainedMediaTool ffmpeg.exe "-y -threads 2 -v error -i `"$($clip.FullName)`" -frames:v 1 `"$($clip.FullName)-first-frame.png`"" "$($clip.FullName)-frame" 2
    }
} else {
    "ENV_BLOCK: media tools unavailable in retention process; no clip has qualified decoding validation." |
        Set-Content (Join-Path $Evidence media-validation-unavailable.txt)
}

Check-Retention
Stop-Transcript
$hashes=@()
foreach($file in Get-ChildItem $Evidence -File -Recurse | Where-Object Name -ne "evidence-hashes.json"){
 Check-Retention;$hashes+=Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256|Select-Object Path,Hash
}
Save-Retention $hashes (Join-Path $Evidence evidence-hashes.json)
