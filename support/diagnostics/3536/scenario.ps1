param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline,[string]$PrelaunchPhase,[string]$PhaseContext,[string]$PhaseTag)
$ErrorActionPreference="Stop"
$script:Stage="environment";$script:Owned=@();$script:Results=@();$script:QualifiedFailure=$false
if(-not $PrelaunchPhase){Start-Transcript (Join-Path $Evidence scenario-original.txt)}
function Json($Data,$Name){$Data|ConvertTo-Json -Depth 16|Set-Content (Join-Path $Evidence "$Name.json") -Encoding UTF8}
function Profile-Receipt($App,$Name){
 $p=Get-Content $App.Profile -Raw -Encoding UTF8|ConvertFrom-Json
 $identity=$p."flutter.ls_security_context"
 if(-not $identity){throw "ENV_BLOCK: app-generated certificate identity absent"}
 $public=$identity|ConvertFrom-Json
 # StoredSecurityContext contains certificate and privateKey. Retain only the certificate.
 $receipt=@{Config=$p;ProfileSha256=(Get-FileHash $App.Profile).Hash;Certificate=$public.certificate;SecurityContextSha256=$null;CertificateHash=$public.certificateHash}
 $sha=[Security.Cryptography.SHA256]::Create();try{$receipt.SecurityContextSha256=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace("-","")}finally{$sha.Dispose()}
 $p."flutter.ls_security_context"="<REDACTED: private key; certificate retained separately>"
 if($p."flutter.ls_show_token"){$p."flutter.ls_show_token"="<REDACTED: local show token>"}
 Json $receipt $Name;return $receipt
}
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
function Invoke-PrelaunchPhase($Phase,$Context,$Tag,[int]$Seconds,[DateTime]$End){
 Check-Budget
 $remaining=[int][Math]::Floor(($End-[DateTime]::UtcNow).TotalMilliseconds)-5000
 if($remaining -le 0){throw "ENV_BLOCK: shared 120-second prelaunch budget exhausted"}
 $phaseEnd=[DateTime]::UtcNow.AddSeconds($Seconds);if($phaseEnd -gt $End.AddSeconds(-5)){$phaseEnd=$End.AddSeconds(-5)}
 $path=(Get-Command powershell.exe -ErrorAction Stop).Source
 $args="-NoProfile -MTA -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Evidence `"$Evidence`" -Deadline `"$($Deadline.ToString("o"))`" -PrelaunchPhase $Phase -PhaseContext `"$Context`" -PhaseTag $Tag"
 $p=Start-Process $path -ArgumentList $args -PassThru -RedirectStandardOutput (Join-Path $Evidence "$Tag-stdout-original.txt") -RedirectStandardError (Join-Path $Evidence "$Tag-stderr-original.txt")
 $receipt=New-ExitReceipt $p $Tag $path
 $receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Evidence "$Tag-owned-process.json") -Encoding UTF8
 if(-not $receipt.HandleAcquired){throw "ENV_BLOCK: prelaunch phase original handle unavailable"}
 $waitMs=[int][Math]::Max(0,($phaseEnd-[DateTime]::UtcNow).TotalMilliseconds)
 $wait=$p.WaitForExit($waitMs);Complete-ExitReceipt $p $receipt $wait
 if(-not $wait){
  $receipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Evidence "$Tag-timeout-before-kill.json") -Encoding UTF8
  if($p.Path -ne $receipt.ActualPath -or $p.StartTime.ToUniversalTime().ToString("o") -ne $receipt.StartUtc){throw "ENV_BLOCK: prelaunch cleanup identity changed"}
  $p.Kill();$post=$p.WaitForExit([int][Math]::Max(0,[Math]::Min(5000,($End-[DateTime]::UtcNow).TotalMilliseconds)));Complete-ExitReceipt $p $receipt $post
  $live=Get-Process -Id $receipt.Pid -ErrorAction SilentlyContinue
  $same=$live -and $live.Path -eq $receipt.ActualPath -and $live.StartTime.ToUniversalTime().ToString("o") -eq $receipt.StartUtc
  @{Process=$receipt;ObservedUtc=[DateTime]::UtcNow.ToString("o");SameIdentityPresent=[bool]$same;FinalIdentity=if($live){$live|Select-Object Id,Path,StartTime}else{$null}}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $Evidence "$Tag-cleanup-final.json") -Encoding UTF8
  $confirmed=$receipt.WaitBoolean -eq $true -and $receipt.HasExited -eq $true -and $receipt.ExitCodeType -eq "System.Int32" -and -not $receipt.ExitCodeIsNull -and -not $same
  if(-not $confirmed){throw "ENV_BLOCK: prelaunch phase cleanup UNKNOWN; no next phase permitted"}
  if($Phase -eq "signature"){return @{Status="SUPPLEMENTARY_UNKNOWN";Reason="15-second signature metadata deadline; exact child exit confirmed";NoTrustClaim=$true}}
  throw "ENV_BLOCK: required prelaunch phase $Phase timed out"
 }
 if($receipt.Status -ne "EXIT_ZERO"){throw "ENV_BLOCK: required prelaunch phase $Phase result $($receipt.Status)"}
 $result=Get-Content (Join-Path $Evidence "$Tag-output.json") -Raw -Encoding UTF8|ConvertFrom-Json
 if($result.Status -ne "COMPLETED"){throw "ENV_BLOCK: prelaunch phase output incomplete"}
 return $result.Result
}
function Run-PrelaunchPhase{
 $phaseReceipt=@{Phase=$PrelaunchPhase;Tag=$PhaseTag;StartedUtc=[DateTime]::UtcNow.ToString("o");CompletedUtc=$null;Status="STARTED";Error=$null}
 $receiptPath=Join-Path $Evidence "$PhaseTag-phase.json"
 $phaseReceipt|ConvertTo-Json|Set-Content $receiptPath -Encoding UTF8
 try{
  $c=Get-Content $PhaseContext -Raw -Encoding UTF8|ConvertFrom-Json;$result=@{}
  switch($PrelaunchPhase){
   "absence"{foreach($owned in @($c.Owned)|Where-Object Role -eq $c.Role){Assert-OwnedAbsent $owned};$result=@{OwnedAbsent=$true}}
   "extract"{if(-not (Test-Path $c.Directory)){Expand-Archive -LiteralPath $c.Archive -DestinationPath $c.Directory};$result=@{Directory=$c.Directory}}
   "discover"{$exe=@(Get-ChildItem $c.Directory -Filter localsend_app.exe -Recurse|Select-Object -ExpandProperty FullName);if($exe.Count -ne 1){throw "ENV_BLOCK: portable executable ambiguous"};$result=@{Exe=$exe[0];Profile=Join-Path (Split-Path $exe[0]) settings.json}}
   "profile"{
    $settings=@{"flutter.ls_alias"="3536-$($c.Role)";"flutter.ls_port"=[int]$c.Port;"flutter.ls_locale"="en";"flutter.ls_quick_save"="off";"flutter.ls_destination"=$c.Destination;"flutter.ls_save_to_gallery"=$false;"flutter.ls_https"=$true;"flutter.ls_auto_finish"=$false;"flutter.ls_whats_new"="1.18.2";"flutter.ls_version"=3}
    if(Test-Path $c.Profile){$old=Get-Content $c.Profile -Raw -Encoding UTF8|ConvertFrom-Json;if($old."flutter.ls_security_context"){$settings["flutter.ls_security_context"]=$old."flutter.ls_security_context"}}
    [IO.File]::WriteAllText($c.Profile,($settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$result=@{ProfilePath=$c.Profile;Utf8WithoutBom=$true}
   }
   "pe"{
    $v=(Get-Item $c.Exe).VersionInfo;$stream=[IO.File]::OpenRead($c.Exe);try{$reader=[IO.BinaryReader]::new($stream);$stream.Position=0x3c;$pe=$reader.ReadInt32();$stream.Position=$pe+4;$machine=$reader.ReadUInt16()}finally{$stream.Dispose()}
    if($machine -ne 0x8664 -or $v.ProductVersion -notmatch "^1\.18\.2(?:\D|$)"){throw "ENV_BLOCK: release PE/version qualification failed"}
    $result=@{Machine=$machine;FileVersion=$v.FileVersion;ProductVersion=$v.ProductVersion}
   }
   "hash"{$result=@{Hash=(Get-FileHash -LiteralPath $c.Exe -Algorithm SHA256).Hash}}
   "signature"{$sig=Get-AuthenticodeSignature -LiteralPath $c.Exe;$result=@{Status="$($sig.Status)";StatusMessage=$sig.StatusMessage;SignerSubject=$sig.SignerCertificate.Subject;SignerThumbprint=$sig.SignerCertificate.Thumbprint;Supplementary=$true}}
   "artifact"{
    if(-not $c.Exe -or -not $c.Pe -or -not $c.Hash){throw "ENV_BLOCK: mandatory prelaunch metadata absent"}
    Json @{Path=$c.Exe;Hash=$c.Hash;Version=@{FileVersion=$c.Pe.FileVersion;ProductVersion=$c.Pe.ProductVersion};Machine=$c.Pe.Machine;Signature=$c.Signature} "$($c.Role)-artifact";$result=@{MandatoryArtifactReceiptWritten=$true}
   }
   default{throw "ENV_BLOCK: unsupported prelaunch phase"}
  }
  $phaseReceipt.Status="COMPLETED";@{Status="COMPLETED";Result=$result}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $Evidence "$PhaseTag-output.json") -Encoding UTF8
 }catch{$phaseReceipt.Status="ENV_BLOCK";$phaseReceipt.Error="$_";$_|Format-List * -Force|Out-File (Join-Path $Evidence "$PhaseTag-error-original.txt");exit 2}
 finally{$phaseReceipt.CompletedUtc=[DateTime]::UtcNow.ToString("o");$phaseReceipt|ConvertTo-Json -Depth 8|Set-Content $receiptPath -Encoding UTF8}
 exit 0
}
function Launch-App($Role,$Port,$Destination){
 $prelaunchDeadline=[DateTime]::UtcNow.AddSeconds(120);if($prelaunchDeadline -gt $Deadline){$prelaunchDeadline=$Deadline}
 $context=[ordered]@{Role=$Role;Port=$Port;Destination=$Destination;Directory="C:\s3536\$Role";Archive=$script:Archive;Owned=$script:Owned;Exe=$null;Profile=$null;Pe=$null;Hash=$null;Signature=$null}
 foreach($entry in @(@("absence",5),@("extract",45),@("discover",5),@("profile",10),@("pe",10),@("hash",10),@("signature",15),@("artifact",5))){
  $phase=$entry[0];$tag="$script:Stage-$Role-$phase";$contextPath=Join-Path $Evidence "$tag-context.json"
  $context|ConvertTo-Json -Depth 12|Set-Content $contextPath -Encoding UTF8
  $output=Invoke-PrelaunchPhase $phase $contextPath $tag ([int]$entry[1]) $prelaunchDeadline
  switch($phase){"discover"{$context.Exe=$output.Exe;$context.Profile=$output.Profile};"pe"{$context.Pe=$output};"hash"{$context.Hash=$output.Hash};"signature"{$context.Signature=$output}}
 }
 $exe=$context.Exe;$profile=$context.Profile
 $p=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru;$null=$p.Handle
 $a=[pscustomobject]@{Id=$p.Id;Path=$exe;StartUtc=$p.StartTime.ToUniversalTime().ToString("o");Hwnd=0L;Profile=$profile;Port=$Port;Role=$Role}
 $script:Owned+=$a;Json $script:Owned owned-apps
 $end=[DateTime]::UtcNow.AddSeconds(25)
 do{Check-Budget;$p.Refresh();if($p.HasExited){throw "ENV_BLOCK: app exited during launch"};if($p.MainWindowHandle -ne 0){break};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow -lt $end)
 if($p.MainWindowHandle -eq 0){throw "ENV_BLOCK: owned app HWND absent"}
 if($p.Path -ne $exe){throw "ENV_BLOCK: actual executable path differs from launch receipt"}
 $a.Hwnd=$p.MainWindowHandle.ToInt64();Json $script:Owned owned-apps;Focus-App $a|Out-Null;Save-Desktop "$Role-launched"
 Find-Control $a Receive|Out-Null
 $end=[DateTime]::UtcNow.AddSeconds(20)
 do{$listen=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $a.Id);if($listen){break};Check-Budget;Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow -lt $end)
 Json $listen "$Role-listening";if(-not $listen){throw "ENV_BLOCK: assigned port not owned by actual app"}
 return $a
}
function Add-Favorite($App){
 Click-Name $App Send;Click-Name $App Favorites;Click-Name $App Add
 Find-Control $App "Add to favorites"|Out-Null
 $tree=@(Snapshot $App);$fields=@($tree|Where-Object Type -eq 50004|Sort-Object Top)
 $labels=@("Device name","IP Address","Port")
 if($fields.Count -ne 3){throw "ENV_BLOCK: Favorites requires exactly three provider Edit controls"}
 for($i=0;$i -lt 3;$i++){$label=@($tree|Where-Object Name -eq $labels[$i]);if($label.Count -ne 1 -or $fields[$i].Top -lt $label[0].Bottom -or ($i -lt 2 -and $fields[$i].Bottom -gt $fields[$i+1].Top)){throw "ENV_BLOCK: field/label bounds do not qualify Favorites controls"}}
 Type-Control $App $fields[1] "127.0.0.1";Type-Control $App $fields[2] "53318"
 $read=@(Snapshot $App|Where-Object Type -eq 50004|Sort-Object Top);Json @{Labels=$labels;Before=$fields;After=$read} favorites-field-readback;Save-Desktop favorites-before-confirm
 if($read.Count -ne 3 -or $read[1].Value -ne "127.0.0.1" -or $read[2].Value -ne "53318"){throw "ENV_BLOCK: actual Favorites IP/Port provider readback missing or wrong"}
 Click-Name $App Confirm
 Find-Control $App "3536-receiver`n(127.0.0.1)"|Out-Null
 $receipt=Profile-Receipt $App sender-after-real-favorite
 $favorites=@($receipt.Config."flutter.ls_favorites"|ForEach-Object {$_|ConvertFrom-Json})
 Json $favorites actual-favorites
 if($favorites.Count -ne 1 -or $favorites[0].ip -ne "127.0.0.1" -or $favorites[0].port -ne 53318 -or $favorites[0].fingerprint -ne $script:ReceiverCertificate){throw "ENV_BLOCK: persisted real favorite endpoint mismatch"}
 Click-Name $App Cancel
}
function Pick-File($App,$Path){
 Click-Name $App File
 $end=[DateTime]::UtcNow.AddSeconds(10);do{$dialogs=@([Controls3536]::Dialogs($App.Id));if($dialogs.Count -eq 1){break};Check-Budget;Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 if($dialogs.Count -ne 1){throw "ENV_BLOCK: unique owned native file picker absent"};$h=$dialogs[0]
 $field=Find-Control $App "File name:" 50004 $h
 Type-Control $App $field $Path $h
 $after=Find-Control $App "File name:" 50004 $h;Json @{Hwnd=$h;Field=$after;Expected=$Path} "$script:Stage-picker-readback"
 if($after.Value -ne $Path){throw "ENV_BLOCK: native picker exact Unicode path readback mismatch"}
 Click-Control $App (Find-Control $App Open 50000 $h) $h
 Find-Control $App ([IO.Path]::GetFileName($Path))|Out-Null;Save-Desktop "$script:Stage-selected"
}
function Transfer($Kind,$Destination){
 $script:Stage=$Kind;New-Item -ItemType Directory -Path $Destination|Out-Null
 # Each arm restarts the receiver with its own existing certificate and a fresh destination.
 $script:Receiver=Launch-App receiver 53318 $Destination
 $r=Profile-Receipt $script:Receiver "$Kind-receiver-profile"
 if(-not $r.Certificate -or -not $r.CertificateHash){throw "ENV_BLOCK: receiver public certificate identity missing"}
 if($script:ReceiverCertificate -and $r.CertificateHash -ne $script:ReceiverCertificate){throw "ENV_BLOCK: receiver certificate changed across arms"};$script:ReceiverCertificate=$r.CertificateHash
 if($r.CertificateHash -eq $script:SenderIdentity){throw "ENV_BLOCK: independent app identities not established"}
 if($Kind -eq "english"){Add-Favorite $script:Sender}
 $name=if($Kind -eq "english"){$script:Fixture.english}else{$script:Fixture.japanese}
 Click-Name $script:Sender Send
 Pick-File $script:Sender (Join-Path "C:\s3536\s" $name)
 Click-Name $script:Sender Favorites
 Start-Clip "$Kind-send-accept"
 try{Click-Name $script:Sender "3536-receiver`n(127.0.0.1)";Find-Control $script:Receiver Accept|Out-Null;Save-Desktop "$Kind-request";Click-Name $script:Receiver Accept;Start-Sleep -Seconds 5}finally{Stop-Clip}
 $end=[DateTime]::UtcNow.AddSeconds(45);$finished=$false;$senderFinished=$false;$explicitError=$false
 do{
  Check-Budget;$tree=@(Snapshot $script:Receiver);$senderTree=@(Snapshot $script:Sender)
  $finished=@($tree|Where-Object Name -eq Finished).Count -eq 1
  $senderFinished=@($senderTree|Where-Object Name -eq Finished).Count -eq 1
  $receiverError=@($tree|Where-Object Name -eq "Finished with error").Count -gt 0
  $senderError=@($senderTree|Where-Object Name -eq "Finished with error").Count -gt 0
  $explicitError=$receiverError -or $senderError
  Write-Event terminalObservation @{ObservedUtc=[DateTime]::UtcNow.ToString("o");Receiver=$tree;Sender=$senderTree;ReceiverFinished=$finished;SenderFinished=$senderFinished;ReceiverError=$receiverError;SenderError=$senderError}
  if(($finished -or $receiverError) -and ($senderFinished -or $senderError)){break}
  Start-Sleep -Milliseconds 500
 }while([DateTime]::UtcNow -lt $end)
 Save-Desktop "$Kind-result";Json @{ObservedUtc=[DateTime]::UtcNow.ToString("o");Sender=$senderTree;Receiver=$tree} "$Kind-final-uia"
 $files=@(Get-ChildItem -LiteralPath $Destination -File);$inventory=@($files|ForEach-Object{@{Name=$_.Name;Length=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
 Json $inventory "$Kind-destination"
 $copyIndex=0;foreach($f in $files){$copyIndex++;Retain-Bytes $f.FullName ("$Kind-destination-{0:D3}.bin" -f $copyIndex) "$Kind-destination-$copyIndex"}
 if(-not $finished -and -not $explicitError){throw "ENV_BLOCK: no observable terminal transfer outcome before bounded wait"}
 $contentOk=$files.Count -eq 1 -and $inventory[0].Length -eq 65536 -and $inventory[0].Sha256 -eq $script:Fixture.payloadSha256
 $complete=$finished -and $senderFinished -and -not $explicitError
 $ok=$complete -and $contentOk -and $files[0].Name -ceq $name
 $exactReported=$complete -and $contentOk -and $files[0].Name -ceq $script:Fixture.expectedReportedFailure
 $tailExtensionLoss=$complete -and $contentOk -and $files[0].Name.Length -lt $name.Length -and $name.StartsWith($files[0].Name,[StringComparison]::Ordinal) -and -not $files[0].Name.EndsWith(".mp4",[StringComparison]::Ordinal)
 $reportedSymptom=$Kind -ne "english" -and ($exactReported -or $tailExtensionLoss)
 $classification=if($ok){"EXACT_TRANSFER_PASS"}elseif($reportedSymptom -and $exactReported){"REPORTED_EXACT_TRUNCATION"}elseif($reportedSymptom){"SUCCESSFUL_TRANSFER_TAIL_AND_EXTENSION_LOSS"}elseif($explicitError){"APP_TERMINAL_TRANSFER_ERROR_CAUSE_UNRESOLVED"}elseif(-not $complete){"TERMINAL_STATES_DISAGREE"}elseif($files.Count -ne 1){"MISSING_OR_MULTIPLE_DESTINATION_FILES"}elseif(-not $contentOk){"CONTENT_LENGTH_OR_HASH_MISMATCH"}else{"OTHER_FILENAME_MISMATCH"}
 $result=@{Arm=$Kind;ProductWorkflowReached=$true;ReceiverCompletedUi=$finished;SenderCompletedUi=$senderFinished;ExactNameAndHash=$ok;ReportedSymptom=$reportedSymptom;ExactReportedName=$exactReported;TailAndExtensionLoss=$tailExtensionLoss;ExpectedReportedFailure=$script:Fixture.expectedReportedFailure;Files=$inventory;Classification=$classification;Cause="No transport/TLS/save attribution established";Status=if($ok){"PASS"}elseif($reportedSymptom){"REPORTED_SYMPTOM_REPRODUCED"}else{"OTHER_OBSERVED_OUTCOME"}}
 $script:Results+=$result;Json $script:Results results
 if($Kind -eq "english" -and -not $ok){$result.Status="CONTROL_FAILURE";Json $script:Results results;throw "ENV_BLOCK: English transfer control failed; Japanese arm not qualified"}
 if($reportedSymptom){$script:QualifiedFailure=$true}

 Stop-Owned $script:Receiver;$script:Receiver=$null
 Click-Name $script:Sender Done
}
function Retain-Bytes($Original,$RetainedName,$ReceiptName){
 $target=Join-Path $Evidence $RetainedName;Copy-Item -LiteralPath $Original -Destination $target
 $item=Get-Item -LiteralPath $Original;$hash=(Get-FileHash -LiteralPath $Original).Hash;$copyHash=(Get-FileHash -LiteralPath $target).Hash
 Json @{OriginalWindowsPath=$Original;OriginalBasename=$item.Name;Utf16Units=$item.Name.Length;Utf8Bytes=[Text.Encoding]::UTF8.GetByteCount($item.Name);RetainedAsciiPath=$target;Bytes=$item.Length;Sha256=$hash;RetainedSha256=$copyHash} "$ReceiptName-byte-map"
 if($hash -ne $copyHash){throw "ENV_BLOCK: retained original byte copy hash mismatch"}
}
function Assert-OwnedAbsent($App){
 $live=Get-Process -Id $App.Id -ErrorAction SilentlyContinue
 if($live -and $live.Path -eq $App.Path -and $live.StartTime.ToUniversalTime().ToString("o") -eq $App.StartUtc){throw "ENV_BLOCK: exact owned process survives; profile reuse prohibited"}
}
function Stop-Owned($App){
 if(-not $App){return};$receipt=@{App=$App;GraceWait=$null;ForceWait=$null;HasExited=$null;OwnedAbsent=$false;Status="UNKNOWN";Errors=@()}
 try{
  $p=Get-Process -Id $App.Id -ErrorAction SilentlyContinue
  if($p -and $p.Path -eq $App.Path -and $p.StartTime.ToUniversalTime().ToString("o") -eq $App.StartUtc){
   $null=$p.Handle;$p.CloseMainWindow()|Out-Null;$receipt.GraceWait=$p.WaitForExit(3000)
   if(-not $receipt.GraceWait){$p.Kill();$receipt.ForceWait=$p.WaitForExit(3000)}
   $receipt.HasExited=$p.HasExited
  }
  Assert-OwnedAbsent $App;$receipt.OwnedAbsent=$true;$receipt.Status="OWNED_ABSENT"
 }catch{$receipt.Errors+="$_";throw}finally{Json $receipt "cleanup-$($App.Id)"}
}

if($PrelaunchPhase){Run-PrelaunchPhase}
try{
 . (Join-Path $PSScriptRoot ui.ps1)
 $os=Get-CimInstance Win32_OperatingSystem;Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Architecture=$env:PROCESSOR_ARCHITECTURE;Desktop=[System.Windows.Forms.SystemInformation]::VirtualScreen;Differences="Two real portable apps on one Windows Server 2022 runner; investigator-created bytes, loopback; reported payload unavailable"} environment
 if($os.Caption -notmatch "Windows Server 2022" -or $env:PROCESSOR_ARCHITECTURE -ne "AMD64"){throw "ENV_BLOCK: selected native Windows Server 2022 x64 environment missing"}
 $desktop=[Issue3456Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw "ENV_BLOCK: interactive desktop unavailable"};[Issue3456Native]::CloseDesktop($desktop)|Out-Null
 $script:Fixture=Get-Content (Join-Path $PSScriptRoot inputs/fixtures.json) -Raw -Encoding UTF8|ConvertFrom-Json
 $payload=Join-Path $PSScriptRoot inputs/fixture-content.bin
 if((Get-Item $payload).Length -ne 65536 -or (Get-FileHash $payload).Hash -ne $script:Fixture.payloadSha256){throw "ENV_BLOCK: input payload mismatch"}
 if(Test-Path C:\s3536){throw "ENV_BLOCK: pre-existing task root is unowned; official fresh extraction required"}
 New-Item -ItemType Directory -Path C:\s3536\s,C:\s3536\d|Out-Null
 Json ([Volume3536]::Info()) native-volume-component
 $volume=Get-Volume -DriveLetter C;Json $volume ntfs-volume;if($volume.FileSystem -ne "NTFS"){throw "ENV_BLOCK: NTFS prerequisite missing"}
 foreach($name in @($script:Fixture.english,$script:Fixture.japanese)){
  if($name.Length -ne 116){throw "ENV_BLOCK: filename length mismatch"};$path=Join-Path C:\s3536\s $name;Copy-Item -LiteralPath $payload -Destination $path
  $native=Join-Path C:\s3536\d $name;Copy-Item -LiteralPath $path -Destination $native
  $hash=(Get-FileHash -LiteralPath $native).Hash;if($hash -ne $script:Fixture.payloadSha256){throw "ENV_BLOCK: native NTFS create/read/hash failed"}
  Write-Event nativeFixture @{Name=$name;Utf16=$name.Length;Utf8=[Text.Encoding]::UTF8.GetByteCount($name);SourcePath=$path;DestPath=$native;Hash=$hash};Remove-Item -LiteralPath $native
  $sourceKind=if($name -ceq $script:Fixture.english){"english"}else{"japanese"};Retain-Bytes $path "source-$sourceKind.bin" "source-$sourceKind"
 }
 $script:Archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip
 Invoke-WebRequest "https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip" -UseBasicParsing -OutFile $script:Archive -TimeoutSec 90
 $hash=(Get-FileHash $script:Archive).Hash;Json @{File=$script:Archive;Sha256=$hash} archive
 if($hash -ne "737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a"){throw "ENV_BLOCK: untouched official archive SHA mismatch"}
 $script:Sender=Launch-App sender 53317 C:\s3536\d
 $script:SenderIdentity=(Profile-Receipt $script:Sender sender-profile).CertificateHash
 if(-not $script:SenderIdentity){throw "ENV_BLOCK: sender public certificate hash absent"}
 Transfer english C:\s3536\d\e
 Transfer japanese C:\s3536\d\j
 if($script:QualifiedFailure -and [DateTime]::UtcNow.AddMinutes(2) -lt $Deadline){Transfer japanese-repeat C:\s3536\d\r}
 Json @{Status="COMPLETED";ProductVerdict=if($script:QualifiedFailure){"REPORTED_SYMPTOM_REPRODUCED"}elseif(@($script:Results|Where-Object {$_.Arm -ne "english" -and $_.Status -ne "PASS"}).Count -gt 0){"OTHER_OBSERVED_OUTCOME"}else{"NON_REPRODUCTION"};Results=$script:Results;ProductExperiments=1;Repeat="At most one; only after exact reported truncation or verified successful-transfer tail/extension loss and two-minute remaining budget"} final-result
}catch{
 if(Get-Command Save-Desktop -ErrorAction SilentlyContinue){try{Save-Desktop "$script:Stage-exception"}catch{}}
 $_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt)
 Json @{Status=if($script:QualifiedFailure){"REPORTED_SYMPTOM_REPRODUCED_WITH_LATER_BLOCKER"}else{"ENV_BLOCK"};Error="$_";Results=$script:Results;ProductExperiments=if(@($script:Results|Where-Object Arm -ne "english").Count -gt 0){1}else{0};Repeat="Bounded by real Done control availability and remaining deadline"} final-result
 exit 2
}finally{try{Stop-Clip}catch{};foreach($a in $script:Owned){try{Stop-Owned $a}catch{}};Stop-Transcript}
