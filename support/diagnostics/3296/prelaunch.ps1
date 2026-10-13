function Invoke-PrelaunchPhase($Phase,$Context,$Tag,[int]$Seconds,[DateTime]$End,[string]$ScenarioEntryPath){
 Check-Budget
 $remaining=[int][Math]::Floor(($End-[DateTime]::UtcNow).TotalMilliseconds)-5000
 if($remaining -le 0){throw "ENV_BLOCK: shared 240-second prelaunch budget exhausted"}
 $phaseEnd=[DateTime]::UtcNow.AddSeconds($Seconds);if($phaseEnd -gt $End.AddSeconds(-5)){$phaseEnd=$End.AddSeconds(-5)}
 $path=(Get-Command powershell.exe -ErrorAction Stop).Source
 if(-not $ScenarioEntryPath -or -not (Test-Path -LiteralPath $ScenarioEntryPath -PathType Leaf)){throw "ENV_BLOCK: explicit scenario phase entry path absent"}
 $entry=[IO.Path]::GetFullPath($ScenarioEntryPath)
 $args="-NoProfile -MTA -ExecutionPolicy Bypass -File `"$entry`" -Evidence `"$Evidence`" -Deadline `"$($Deadline.ToString("o"))`" -PrelaunchPhase $Phase -PhaseContext `"$Context`" -PhaseTag $Tag"
 Json @{Phase=$Phase;Tag=$Tag;Executable=$path;EntryPath=$entry;EntrySha256=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash;FrozenHead=$env:GITHUB_SHA;ArgumentString=$args;ArgumentTokens=@("-NoProfile","-MTA","-ExecutionPolicy","Bypass","-File",$entry,"-Evidence",$Evidence,"-Deadline",$Deadline.ToString("o"),"-PrelaunchPhase",$Phase,"-PhaseContext",$Context,"-PhaseTag",$Tag);PreparedUtc=[DateTime]::UtcNow.ToString("o")} "$Tag-invocation"
 $p=Start-Process $path -ArgumentList $args -PassThru -RedirectStandardOutput (Join-Path $Evidence "$Tag-stdout-original.txt") -RedirectStandardError (Join-Path $Evidence "$Tag-stderr-original.txt")
 $receipt=New-ExitReceipt $p $Tag $path
 @{Id=$receipt.Pid;Path=$receipt.ActualPath;StartUtc=$receipt.StartUtc}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Evidence "owned-$Tag.json") -Encoding UTF8
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
 $ErrorActionPreference='Stop'
 $phaseReceipt=@{Phase=$PrelaunchPhase;Tag=$PhaseTag;StartedUtc=[DateTime]::UtcNow.ToString('o');CompletedUtc=$null;Status='STARTED';Error=$null}
 $receiptPath=Join-Path $Evidence "$PhaseTag-phase.json"
 $phaseReceipt|ConvertTo-Json|Set-Content $receiptPath -Encoding UTF8
 try{
  $c=Get-Content $PhaseContext -Raw -Encoding UTF8|ConvertFrom-Json;$result=@{}
  switch($PrelaunchPhase){
   'download'{Invoke-WebRequest -Uri $c.Url -UseBasicParsing -OutFile $c.Path -TimeoutSec 60;$result=@{Path=$c.Path;Bytes=(Get-Item $c.Path).Length;Url=$c.Url}}
   'hash'{$hash=(Get-FileHash -LiteralPath $c.Path -Algorithm SHA256).Hash;if($c.ExpectedHash -and $hash -ne $c.ExpectedHash){throw 'ENV_BLOCK: exact official artifact hash mismatch'};$result=@{Path=$c.Path;Sha256=$hash}}
   'signature'{$sig=Get-AuthenticodeSignature -LiteralPath $c.Path;$result=@{Status="$($sig.Status)";StatusMessage=$sig.StatusMessage;SignerSubject=$sig.SignerCertificate.Subject;SignerThumbprint=$sig.SignerCertificate.Thumbprint;Supplementary=$true}}
   'extract'{Expand-Archive -LiteralPath $c.Path -DestinationPath $c.Directory;$result=@{Directory=$c.Directory}}
   'discover'{$exe=@(Get-ChildItem $c.Directory -Filter localsend_app.exe -Recurse|Select-Object -ExpandProperty FullName);if($exe.Count -ne 1){throw 'ENV_BLOCK: official executable ambiguous'};$result=@{Exe=$exe[0]}}
   'pe'{$v=(Get-Item $c.Path).VersionInfo;$stream=[IO.File]::OpenRead($c.Path);try{$reader=[IO.BinaryReader]::new($stream);$stream.Position=0x3c;$pe=$reader.ReadInt32();$stream.Position=$pe+4;$machine=$reader.ReadUInt16()}finally{$stream.Dispose()};if($machine -ne 0x8664 -or $v.ProductVersion -notmatch '^1\.18\.2(?:\D|$)'){throw 'ENV_BLOCK: selected app PE/version mismatch'};$result=@{Machine=$machine;FileVersion=$v.FileVersion;ProductVersion=$v.ProductVersion}}
   default{throw 'ENV_BLOCK: unsupported prelaunch phase'}
  }
  $phaseReceipt.Status='COMPLETED';@{Status='COMPLETED';Result=$result}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $Evidence "$PhaseTag-output.json") -Encoding UTF8
 }catch{$phaseReceipt.Status='ENV_BLOCK';$phaseReceipt.Error="$_";$_|Format-List * -Force|Out-File (Join-Path $Evidence "$PhaseTag-error-original.txt");exit 2}
 finally{$phaseReceipt.CompletedUtc=[DateTime]::UtcNow.ToString('o');$phaseReceipt|ConvertTo-Json -Depth 8|Set-Content $receiptPath -Encoding UTF8}
 exit 0
}
function Artifact-Phase($Phase,$Context,$Tag,$Seconds){
 $contextPath=Join-Path $Evidence "$Tag-context.json";$Context|ConvertTo-Json -Depth 8|Set-Content $contextPath -Encoding UTF8
 return Invoke-PrelaunchPhase $Phase $contextPath $Tag $Seconds $script:PrelaunchDeadline (Join-Path $PSScriptRoot scenario.ps1)
}
