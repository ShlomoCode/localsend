$ErrorActionPreference="Stop"
$script:Stage="environment";$script:Owned=@();$script:Results=@();$script:QualifiedFailure=$false

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
function Invoke-PrelaunchPhase($Phase,$Context,$Tag,[int]$Seconds,[DateTime]$End,[string]$ScenarioEntryPath){
 Check-Budget
 $remaining=[int][Math]::Floor(($End-[DateTime]::UtcNow).TotalMilliseconds)-5000
 if($remaining -le 0){throw "ENV_BLOCK: shared 120-second prelaunch budget exhausted"}
 $phaseEnd=[DateTime]::UtcNow.AddSeconds($Seconds);if($phaseEnd -gt $End.AddSeconds(-5)){$phaseEnd=$End.AddSeconds(-5)}
 $path=(Get-Command powershell.exe -ErrorAction Stop).Source
 if(-not $ScenarioEntryPath -or -not (Test-Path -LiteralPath $ScenarioEntryPath -PathType Leaf)){throw "ENV_BLOCK: explicit scenario phase entry path absent"}
 $entry=[IO.Path]::GetFullPath($ScenarioEntryPath)
 $args="-NoProfile -MTA -ExecutionPolicy Bypass -File `"$entry`" -Evidence `"$Evidence`" -Deadline `"$($Deadline.ToString("o"))`" -PrelaunchPhase $Phase -PhaseContext `"$Context`" -PhaseTag $Tag"
 Json @{Phase=$Phase;Tag=$Tag;Executable=$path;EntryPath=$entry;EntrySha256=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash;FrozenHead=$env:GITHUB_SHA;ArgumentString=$args;ArgumentTokens=@("-NoProfile","-MTA","-ExecutionPolicy","Bypass","-File",$entry,"-Evidence",$Evidence,"-Deadline",$Deadline.ToString("o"),"-PrelaunchPhase",$Phase,"-PhaseContext",$Context,"-PhaseTag",$Tag);PreparedUtc=[DateTime]::UtcNow.ToString("o")} "$Tag-invocation"
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
    $settings=@{"flutter.ls_alias"="3317-$($c.Role)";"flutter.ls_port"=[int]$c.Port;"flutter.ls_locale"="en";"flutter.ls_quick_save"="off";"flutter.ls_destination"=$c.Destination;"flutter.ls_save_to_gallery"=$false;"flutter.ls_https"=$true;"flutter.ls_auto_finish"=$false;"flutter.ls_whats_new"="1.18.2";"flutter.ls_version"=3}
    if(Test-Path $c.Profile){$old=Get-Content $c.Profile -Raw -Encoding UTF8|ConvertFrom-Json;if($old."flutter.ls_security_context"){$settings["flutter.ls_security_context"]=$old."flutter.ls_security_context"}}
    [IO.File]::WriteAllText($c.Profile,($settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$result=@{ProfilePath=$c.Profile;Utf8WithoutBom=$true}
   }
   "pe"{
    $v=(Get-Item $c.Exe).VersionInfo;$stream=[IO.File]::OpenRead($c.Exe);try{$reader=[IO.BinaryReader]::new($stream);$stream.Position=0x3c;$pe=$reader.ReadInt32();$stream.Position=$pe+4;$machine=$reader.ReadUInt16()}finally{$stream.Dispose()}
    if($machine -ne 0x8664 -or $v.ProductVersion -notmatch "^1\.18\.2(?:\D|$)"){throw "ENV_BLOCK: release PE/version qualification failed"}
    $result=@{Machine=$machine;FileVersion=$v.FileVersion;ProductVersion=$v.ProductVersion}
   }
   "hash"{$hash=(Get-FileHash -LiteralPath $c.Exe -Algorithm SHA256).Hash;$tray=(Get-FileHash -LiteralPath (Join-Path (Split-Path $c.Exe) tray_manager_plugin.dll) -Algorithm SHA256).Hash;if($hash -ne "3e5fcc7a955049d3586b9ed5f6bb5e7cb970b882de9eaf0924d1903250b70cd5" -or $tray -ne "160ee62aa675fb6d62d03c74b45ee7a44982072a2ae41a7e22d4f1b6d8dbb373"){throw "ENV_BLOCK: exact release executable/tray hash mismatch"};$result=@{Hash=$hash;TrayHash=$tray}}
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
function Launch-App($Role,$Port,$Destination,[string]$ScenarioEntryPath){
 $prelaunchDeadline=[DateTime]::UtcNow.AddSeconds(120);if($prelaunchDeadline -gt $Deadline){$prelaunchDeadline=$Deadline}
 $context=[ordered]@{Role=$Role;Port=$Port;Destination=$Destination;Directory="C:\s3317\$Role";Archive=$script:Archive;Owned=$script:Owned;Exe=$null;Profile=$null;Pe=$null;Hash=$null;Signature=$null}
 foreach($entry in @(@("absence",5),@("extract",45),@("discover",5),@("profile",10),@("pe",10),@("hash",10),@("signature",15),@("artifact",5))){
  $phase=$entry[0];$tag="$script:Stage-$Role-$phase";$contextPath=Join-Path $Evidence "$tag-context.json"
  $context|ConvertTo-Json -Depth 12|Set-Content $contextPath -Encoding UTF8
  $output=Invoke-PrelaunchPhase $phase $contextPath $tag ([int]$entry[1]) $prelaunchDeadline $ScenarioEntryPath
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
 Find-Control $a "Receive`nTab 1 of 3" 50000|Out-Null
 $end=[DateTime]::UtcNow.AddSeconds(20)
 do{$listen=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue|Where-Object OwningProcess -eq $a.Id);if($listen){break};Check-Budget;Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow -lt $end)
 Json $listen "$Role-listening";if(-not $listen){throw "ENV_BLOCK: assigned port not owned by actual app"}
 return $a
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
