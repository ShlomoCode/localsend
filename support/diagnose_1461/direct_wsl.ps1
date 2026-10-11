# Source-only draft. Dispatch requires parent review of the independent audit.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=$PWD.Path
$evidence=Join-Path $root 'evidence/issue1461'
$windows=Join-Path $evidence 'windows'
[void][IO.Directory]::CreateDirectory($evidence)
function Json($path,$value){$value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding utf8}
function Wsl([string[]]$Arguments,[int]$Seconds=30){
 $info=[Diagnostics.ProcessStartInfo]::new('wsl.exe');$info.UseShellExecute=$false
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($arg in @('-d','Ubuntu-24.04','-u','root','--')+$Arguments){[void]$info.ArgumentList.Add($arg)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start()
 $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit($Seconds*1000)){ $p.Kill();throw 'Out-of-band WSL command deadline; infrastructure failure.' }
 $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
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
 $guestIp=Wsl @('bash','-c','ip -4 -o addr show dev eth0 scope global | awk ''{split($4,a,"/");print a[1]}''')
 if($guestIp -notmatch '^172\.[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Expected exactly one WSL NAT guest IPv4.'}
 $env:RECEIVER_HOST=$guestIp;$env:RECEIVER_PORT='41631';$env:FAILED_FIXTURE_BYTES='4294967296'
 $fixtureBytes=[long]$env:FAILED_FIXTURE_BYTES
 $sourceDrive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($windows))
 $guestBackingDrive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:USERPROFILE))
 $sharedDrive=$sourceDrive.Name -eq $guestBackingDrive.Name
 $backingRequired=if($sharedDrive){3*$fixtureBytes+1073741824}else{$fixtureBytes+1073741824}
 $guestFree=[long](Wsl @('bash','-c','df --output=avail -B1 /home/tester | tail -n 1'))
 Json (Join-Path $evidence 'storage-admission.json') @{sourceDrive=$sourceDrive.Name;sourceAvailable=$sourceDrive.AvailableFreeSpace;wslBackingDrive=$guestBackingDrive.Name;backingAvailable=$guestBackingDrive.AvailableFreeSpace;backingRequired=$backingRequired;guestAvailable=$guestFree;scope='Source, ordinary probe backup, received bytes and recorder reserve; WSL backing assumed on default user profile drive'}
 if($guestBackingDrive.AvailableFreeSpace -lt $backingRequired -or $guestFree -lt ($fixtureBytes+1073741824)){throw 'Measured storage cannot preserve the source, backup and guest receive; infrastructure admission failed.'}
 $sender=Start-Process pwsh -ArgumentList @('-NoProfile','-File',"$PSScriptRoot/windows_sender.ps1",'-OutputDirectory',$windows,'-TimeoutSeconds','1800','-ReceiverName','WSL1461') -PassThru -RedirectStandardOutput (Join-Path $evidence 'sender.stdout.txt') -RedirectStandardError (Join-Path $evidence 'sender.stderr.txt')
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
