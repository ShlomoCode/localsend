# Source-only draft. Dispatch requires parent review of the independent audit.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=$PWD.Path
$evidence=Join-Path $root 'evidence/issue1461'
$windows=Join-Path $evidence 'windows'
[void][IO.Directory]::CreateDirectory($evidence)
function Json($path,$value){$value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding utf8}
function Wsl([string[]]$Arguments,[int]$Seconds=30,[string]$ReceiptPath=''){
 $info=[Diagnostics.ProcessStartInfo]::new('wsl.exe');$info.UseShellExecute=$false
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $actualArguments=@('-d','Ubuntu-24.04','-u','root','--exec')+$Arguments
 foreach($arg in $actualArguments){[void]$info.ArgumentList.Add($arg)}
 $receipt=@{executable='wsl.exe';arguments=$actualArguments;startedUtc=[DateTime]::UtcNow.ToString('o');status='starting';stdout=$null;stderr=$null;exitCode=$null}
 if($ReceiptPath){Json $ReceiptPath $receipt}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start()
 $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit($Seconds*1000)){ $p.Kill();if($ReceiptPath){$receipt.status='deadline-exceeded';$receipt['finishedUtc']=[DateTime]::UtcNow.ToString('o');Json $ReceiptPath $receipt};throw 'Out-of-band WSL command deadline; infrastructure failure.' }
 $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
 if($ReceiptPath){$receipt.status='exited';$receipt.stdout=$text;$receipt.stderr=$errorText;$receipt.exitCode=$p.ExitCode;$receipt['finishedUtc']=[DateTime]::UtcNow.ToString('o');Json $ReceiptPath $receipt}
 if($p.ExitCode -ne 0){throw "WSL command failed: $($Arguments -join ' '); $text $errorText"}
 return $text.Trim()
}
$linuxRoot=Wsl @('wslpath','-a',$root.Replace('\','/'))
$linuxEvidence="$linuxRoot/evidence/issue1461"
$linuxScript="$linuxRoot/support/diagnose_1461/wsl_control.sh"
function Guest([string[]]$Arguments,[int]$Seconds=30){Wsl (@('bash',$linuxScript,$linuxEvidence)+$Arguments) $Seconds}
$counter=0
function Command($Fields,[int]$Seconds=60){
 $script:counter++;$id=('{0:D4}' -f $script:counter);$Fields.id=$id
 $tmp=Join-Path $windows ('commands/'+$id+'.tmp');$target=Join-Path $windows ('commands/'+$id+'.json')
 Json $tmp $Fields;Move-Item -LiteralPath $tmp -Destination $target
 $result=Join-Path $windows ('results/'+$id+'.json');$until=[DateTime]::UtcNow.AddSeconds($Seconds)
 do{
  if(Test-Path $result){$r=Get-Content $result -Raw|ConvertFrom-Json;if($r.status -eq 'failed'){throw $r.error};if($r.status -eq 'passed'){return $r.result}}
  if($sender.HasExited){throw 'Sender controller exited before command result.'};Start-Sleep -Milliseconds 100
 }while([DateTime]::UtcNow -lt $until)
 throw "Sender command deadline: $id; not a native network failure."
}
function WaitFile([string]$Path,[int]$Seconds){
 $until=[DateTime]::UtcNow.AddSeconds($Seconds)
 do{if(Test-Path $Path){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until)
 throw "Infrastructure receipt missing: $Path"
}
function WorkingProbe([string]$Fixture,[string]$Phase,[int]$Seconds=240){
 $probe=Command @{action='probe';fixture=$Fixture;phase=$Phase} $Seconds
 if(-not $probe.rename.success -or -not $probe.delete.success -or -not $probe.restored){throw "Ordinary source operation control failed: $Fixture $Phase"}
 foreach($receipt in @($probe.handlesBefore,$probe.handlesAfter)){
  if($receipt.exitCode -notin @(0,1) -or -not (Test-Path -LiteralPath $receipt.raw)){throw 'Working control handle evidence missing.'}
  $raw=Get-Content -LiteralPath $receipt.raw -Raw
  if($raw -notmatch 'No matching handles found\.' -or $receipt.ownedHandleConfirmed){throw "Working control retained a source handle: $Fixture $Phase"}
 }
 return $probe
}
$sender=$null;$down=$false;$native=$null
try{
 Guest @('prepare','9a823f990eab24d33c0d3c27698a15812f08a266f342462ed4755afa52d703ca') 900|Set-Content (Join-Path $evidence 'guest-prepare-output.txt')
 $ipOutput=Wsl @('ip','-j','-4','address','show','dev','eth0','scope','global') 30 (Join-Path $evidence 'guest-ip-command.json')
 $ipInterfaces=@($ipOutput|ConvertFrom-Json)
 if($ipInterfaces.Count -ne 1 -or $ipInterfaces[0].ifname -cne 'eth0'){throw 'Actual IP JSON must identify exactly one eth0 interface.'}
 $globalAddresses=@($ipInterfaces[0].addr_info|Where-Object {$_.family -ceq 'inet' -and $_.scope -ceq 'global'})
 if($globalAddresses.Count -ne 1){throw 'Actual eth0 must have exactly one global IPv4 address.'}
 $guestIp=[string]$globalAddresses[0].local;$parsedGuestIp=$null
 if(-not [Net.IPAddress]::TryParse($guestIp,[ref]$parsedGuestIp) -or $parsedGuestIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsedGuestIp.ToString() -cne $guestIp -or $parsedGuestIp.GetAddressBytes()[0] -ne 172 -or $parsedGuestIp.GetAddressBytes()[1] -lt 16 -or $parsedGuestIp.GetAddressBytes()[1] -gt 31){throw 'Expected one canonical actual WSL NAT guest IPv4 in 172.16.0.0/12.'}
 $env:RECEIVER_HOST=$guestIp;$env:RECEIVER_PORT='41631';$env:FAILED_FIXTURE_BYTES='4294967296'
 $fixtureBytes=[long]$env:FAILED_FIXTURE_BYTES
 $sourceDrive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($windows))
 $guestBackingDrive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:USERPROFILE))
 $sharedDrive=$sourceDrive.Name -eq $guestBackingDrive.Name
 $backingRequired=if($sharedDrive){3*$fixtureBytes+1073741824}else{$fixtureBytes+1073741824}
 $dfOutput=Wsl @('df','--output=avail','-B1','/home/tester') 30 (Join-Path $evidence 'guest-storage-command.json')
 $dfLines=@($dfOutput -split '\r?\n'|Where-Object {$_.Trim().Length -gt 0})
 $guestFree=[long]0
 if($dfLines.Count -ne 2 -or $dfLines[0] -match '[0-9]' -or $dfLines[1] -notmatch '^\s*[0-9]+\s*$' -or -not [long]::TryParse($dfLines[1].Trim(),[ref]$guestFree) -or $guestFree -lt 0){throw 'Actual df output must contain one header and one valid nonnegative Int64 free-byte number.'}
 Json (Join-Path $evidence 'storage-admission.json') @{sourceDrive=$sourceDrive.Name;sourceAvailable=$sourceDrive.AvailableFreeSpace;wslBackingDrive=$guestBackingDrive.Name;backingAvailable=$guestBackingDrive.AvailableFreeSpace;backingRequired=$backingRequired;guestAvailable=$guestFree;scope='Source, ordinary probe backup, received bytes and recorder reserve; WSL backing assumed on default user profile drive'}
 if($guestBackingDrive.AvailableFreeSpace -lt $backingRequired -or $guestFree -lt ($fixtureBytes+1073741824)){throw 'Measured storage cannot preserve the source, backup and guest receive; infrastructure admission failed.'}
 $senderScript=Join-Path $PSScriptRoot 'windows_sender.ps1'
 if($senderScript.Contains('"') -or $windows.Contains('"')){throw 'Sender launch paths must not contain embedded double quotes.'}
 # Start-Process joins ArgumentList entries. Its documented single-string
 # form needs explicit double quotes around these complete Windows paths.
 $senderArguments='-NoProfile -File "'+$senderScript+'" -OutputDirectory "'+$windows+'" -TimeoutSeconds 1800 -ReceiverName WSL1461'
 $sender=Start-Process pwsh -ArgumentList $senderArguments -PassThru -RedirectStandardOutput (Join-Path $evidence 'sender.stdout.txt') -RedirectStandardError (Join-Path $evidence 'sender.stderr.txt')
 WaitFile (Join-Path $windows 'ready.json') 360
 $ready=Get-Content (Join-Path $windows 'ready.json') -Raw|ConvertFrom-Json
 Json (Join-Path $evidence 'topology-plan.json') @{scope='Windows Server 2025 -> official Linux 1.14 WSL2 NAT; peer TCP diagnostic only; not reported Android or Windows11 equivalence';guestIp=$guestIp;port=41631;failedBytes=$ready.fixtures.failed.bytes;nativeHoldSeconds=300;restoreGuardianSeconds=360;release='1.14.0'}
 Command @{action='record-start'}|Out-Null
 WorkingProbe 'control' 'before-selection'|Out-Null
 WorkingProbe 'failed' 'before-selection'|Out-Null
 Command @{action='add-favorite'}|Out-Null
 foreach($case in @('control','failed')){
  $f=$ready.fixtures.$case;$basename=[IO.Path]::GetFileName($f.path)
  Guest @('arm',$case,[string]$f.bytes,$f.sha256,$basename)|Out-Null
  WaitFile (Join-Path $evidence "cases/$case/receiver/armed.tsv") 30
  Command @{action='select';fixture=$case}|Out-Null
  Command @{action='send';receiverName='WSL1461'}|Out-Null
  if($case -eq 'control'){
   WaitFile (Join-Path $evidence 'cases/control/receiver/complete.tsv') 150
   Guest @('control-result')|Set-Content (Join-Path $evidence 'control-result.txt')
   WorkingProbe 'control' 'after-success'|Out-Null
   Command @{action='click';label='Done'}|Out-Null
   continue
  }
  WaitFile (Join-Path $evidence 'cases/failed/receiver/accepted.tsv') 90
  Guest @('accept','failed')|Set-Content (Join-Path $evidence 'partial-before-proof.txt')
  $proof=Command @{action='network-proof'}
  Json (Join-Path $evidence 'windows-network-proof.json') $proof
  if(-not $proof.qualifiesDirectPeer){throw 'Actual owned direct peer socket gate failed.'}
  $localAddresses=@($proof.connections|ForEach-Object {$_.LocalAddress}|Select-Object -Unique)
  if($localAddresses.Count -ne 1){throw 'Unique actual sender source IPv4 required.'};$peer=[string]$localAddresses[0]
  Guest @('network-proof','failed',$peer)|Out-Null
  $handles=Command @{action='probe';fixture='failed';phase='during-upload'}
  Json (Join-Path $evidence 'source-during-upload.json') $handles
  if($handles.exclusiveOpen.success -or -not $handles.ownedHandleConfirmed){throw 'Actual LocalSend-owned source handle was not confirmed; no held-source case admitted.'}
  # Down repeats current partial/socket/identity gates immediately before input.
  $down=$true
  Guest @('down','failed',$peer,'360')|Set-Content (Join-Path $evidence 'down-output.txt')
  Command @{action='record-interruption';kind='normal-network-interruption';evidence='cases/failed/receiver/down.tsv'}|Out-Null
  $until=[DateTime]::UtcNow.AddSeconds(300)
  do{
   $view=Command @{action='screenshot'} 30
   $text=$view.ocr.text+' '+(($view.uia.tree.name)-join ' ')
   if($text -match 'Finished with error'){
    $native=Command @{action='error-details'} 30
    $nativeText=$native|ConvertTo-Json -Depth 20
    if($nativeText -notmatch '(?i)SocketException|Socket Error|errno\s*[=:]?\s*1005[04]|connection.{0,20}(reset|timed out)|write failed|network.{0,20}(unreachable|error)'){throw 'Terminal details did not establish an actual socket/network error.'}
    Guest @('down-state','failed')|Out-Null
    Json (Join-Path $evidence 'native-terminal.json') @{observedUtc=[DateTime]::UtcNow.ToString('o');sender=$ready.processId;ui=$view;details=$native;source='Actual LocalSend terminal UI while guest eth0 remains down'}
    Command @{action='click';label='Close'}|Out-Null
    break
   }
   Start-Sleep -Milliseconds 500
  }while([DateTime]::UtcNow -lt $until)
  if(-not $native){throw 'No native terminal within bounded observation; infrastructure outcome, no synthetic error credited.'}
  Guest @('up','failed')|Out-Null;$down=$false
  Guest @('terminal','failed',"$linuxEvidence/native-terminal.json")|Out-Null
  WaitFile (Join-Path $evidence 'cases/failed/receiver/complete.tsv') 30
  Command @{action='probe';fixture='failed';phase='after-terminal-error'} 240|Out-Null
  Command @{action='quit'}|Out-Null
  WorkingProbe 'failed' 'after-quit'|Out-Null
  Guest @('collect','failed')|Out-Null
  Guest @('quit')|Out-Null
  Command @{action='record-stop'}|Out-Null
  Command @{action='stop'}|Out-Null
 }
 Json (Join-Path $evidence 'controller-result.json') @{status='native-error-sequence-completed';productVerdict='Requires raw/video independent review; no claim of Android equivalence or causal fix'}
}catch{
 Json (Join-Path $evidence 'controller-result.json') @{status='infrastructure-or-admission-failure';error=$_.Exception.ToString();nativeTerminalObserved=(Test-Path (Join-Path $evidence 'native-terminal.json'))}
 throw
}finally{
 if($down){try{Guest @('up','failed')|Out-Null}catch{$_|Out-String|Set-Content (Join-Path $evidence 'restoration-error.txt')}}
 if($sender -and -not $sender.HasExited){try{Command @{action='record-stop'} 30|Out-Null}catch{$_|Out-String|Set-Content (Join-Path $evidence 'recorder-stop-error.txt')}}
}
