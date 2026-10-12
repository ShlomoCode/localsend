param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline)
$ErrorActionPreference='Stop'
$script:Stage='setup';$script:Owned=@();$script:Speech=@();$script:ControlQualified=$false
Start-Transcript (Join-Path $Evidence scenario-original.txt)
function Json($Data,$Name){$Data|ConvertTo-Json -Depth 16|Set-Content (Join-Path $Evidence "$Name.json") -Encoding UTF8}
function Launch-Owned($Path,$Arguments=''){
 Check-Budget
 $launch=@{FilePath=$Path;WorkingDirectory=(Split-Path $Path);PassThru=$true}
 if($Arguments){$launch.ArgumentList=$Arguments}
 $p=Start-Process @launch
 $null=$p.Handle
 $a=[pscustomobject]@{Id=$p.Id;Path=$p.Path;StartUtc=$p.StartTime.ToUniversalTime().ToString('o');Hwnd=0L}
 if($a.Path -ne $Path){throw 'ENV_BLOCK: launch path mismatch'}
 $script:Owned+=$a;Json $script:Owned owned-apps
 return $a
}
function Window-Owned($App){
 $end=[DateTime]::UtcNow.AddSeconds(25)
 do{Check-Budget;$p=Get-Process -Id $App.Id -ErrorAction Stop;$p.Refresh();if($p.MainWindowHandle -ne 0){$App.Hwnd=$p.MainWindowHandle.ToInt64();Json $script:Owned owned-apps;return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 throw 'ENV_BLOCK: owned HWND missing'
}
function Keys($App,$Keys){
 $h=Focus-App $App;Write-Event nativeKeys @{Pid=$App.Id;Hwnd=$h;Keys=$Keys}
 [System.Windows.Forms.SendKeys]::SendWait($Keys);Start-Sleep -Milliseconds 250
}
function Nvda-Gesture($App,[byte]$Key,$Name){
 $h=Focus-App $App;Write-Event nativeNvdaKeys @{Pid=$App.Id;Hwnd=$h;Modifier='Insert';Key=$Name;Mechanism='user32 keybd_event down/up'}
 [NvdaKeys3296]::Gesture($Key)
}
function Speech-Since($Offset,$Name){
 Start-Sleep -Milliseconds 900;Check-Budget
 if(-not(Test-Path $script:NvdaLog)){throw 'ENV_BLOCK: authentic NVDA log missing'}
 $all=[IO.File]::ReadAllText($script:NvdaLog)
 if($all.Length -lt $Offset){throw 'ENV_BLOCK: NVDA log rotated unexpectedly'}
 $chunk=$all.Substring($Offset);$chunk|Set-Content (Join-Path $Evidence "$Name-nvda-original.txt")
 # NVDA input/output logging emits actual speech as a Speaking record following
 # speech.speak/speech.speech.speak. Retain unmatched records; never treat them as speech.
 $records=@([regex]::Matches($chunk,'(?m)^IO - speech(?:\.speech)?\.speak[^\r\n]*\r?\nSpeaking ([^\r\n]+)')|ForEach-Object{$_.Groups[1].Value})
 $receipt=@{Utc=[DateTime]::UtcNow.ToString('o');Offset=$Offset;EndOffset=$all.Length;RawFile="$Name-nvda-original.txt";SpeakingRecords=$records;ParseQualified=$records.Count -gt 0}
 Json $receipt "$Name-speech";$script:Speech+=$receipt
 return ($records -join "`n")
}
function Log-Offset{if(Test-Path $script:NvdaLog){return ([IO.File]::ReadAllText($script:NvdaLog)).Length};return 0}
function Profile-Receipt($Name){
 if(-not(Test-Path $script:Profile)){throw 'ENV_BLOCK: portable runtime profile absent'}
 $raw=[IO.File]::ReadAllText($script:Profile);$data=$raw|ConvertFrom-Json
 if($data.PSObject.Properties.Name -contains 'flutter.ls_security_context'){$data.'flutter.ls_security_context'='<REDACTED: private key>'}
 Json @{Path=$script:Profile;Sha256=(Get-FileHash $script:Profile).Hash;ActualSettings=$data} $Name
 return $data
}
function Quick-Map($App){
 $tree=@(Snapshot $App);$labels=@($tree|Where-Object Name -eq 'Quick Save')
 if($labels.Count -ne 1){throw 'ENV_BLOCK: visible Quick Save label not unique'}
 $label=$labels[0]
 $candidates=@($tree|Where-Object{ $_.Type -eq 50002 -and $_.Left -gt $label.Right -and [Math]::Abs(($_.Top+$_.Bottom)-($label.Top+$label.Bottom)) -lt 35 })
 if($candidates.Count -ne 1){throw 'ENV_BLOCK: Quick Save row/switch bounds ambiguous'}
 Json @{Label=$label;Switch=$candidates[0];Mapping='unique visible checkbox right of exact English label on same row; actual click/state control follows'} quick-save-map
 return $candidates[0]
}
function Dismiss-Notice($App){
 $tree=@(Snapshot $App)
 if(@($tree|Where-Object{$_.Name -like 'File requests are now accepted automatically*'}).Count -gt 0){
  Save-Desktop "$script:Stage-notice";Click-Name $App Close;Write-Event noticeDismissed @{Method='actual named Close click'}
 }
}
function Read-State($App,$Expected,$Name){
 $end=[DateTime]::UtcNow.AddSeconds(4)
 do{
  Profile-Receipt "$Name-profile"|Out-Null
  $current=Quick-Map $App;Save-Desktop $Name
  Json @{ExpectedNativeToggle=$Expected;Observed=$current;ProfileIsSupplemental=$true;StateMeaning='UIA native ToggleState Off=0 On=1; unsupported=-1; inspect original pixels and speech'} "$Name-state"
  if($null -eq $Expected -or $current.Toggle -eq $Expected){return $current}
  Start-Sleep -Milliseconds 200;Check-Budget
 }while([DateTime]::UtcNow -lt $end)
 throw "ENV_BLOCK: mapped actual checkbox transition not observed; inspect raw action/pixels before any product inference"
}
function Stop-Owned($App){
 $p=Get-Process -Id $App.Id -ErrorAction SilentlyContinue
 if($p -and $p.Path -eq $App.Path -and $p.StartTime.ToUniversalTime().ToString('o') -eq $App.StartUtc){
  $null=$p.Handle;$closed=$p.CloseMainWindow();$wait=$p.WaitForExit(3000);if(-not $wait){$p.Kill();$wait=$p.WaitForExit(3000)}
  Write-Event cleanup @{App=$App;CloseRequested=$closed;WaitBoolean=$wait;HasExited=$p.HasExited;ExitCode=$p.ExitCode}
 }
}
try{
 $script:PhaseDeadline=$Deadline.AddMinutes(-11)
 . (Join-Path $PSScriptRoot ui.ps1)
 $os=Get-CimInstance Win32_OperatingSystem
 Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Session=(Get-Process -Id $PID).SessionId;Desktop=[System.Windows.Forms.SystemInformation]::VirtualScreen;Difference='Selected Server 2022 x64 differs from reported Windows 10/11. Original numeric app/NVDA versions unknown. Android not tested.'} environment
 if($os.Caption -notmatch 'Windows Server 2022' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'ENV_BLOCK: selected OS/architecture absent'}
 $desktop=[Issue3456Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw 'ENV_BLOCK: input desktop unavailable'};[Issue3456Native]::CloseDesktop($desktop)|Out-Null
 Save-Desktop input-desktop
 New-Item -ItemType Directory -Force C:\s3296,C:\s3296\nvda-profile|Out-Null
 $archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip
 Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip' -UseBasicParsing -OutFile $archive -TimeoutSec 60
 Json @{Sha256=(Get-FileHash $archive).Hash;Path=$archive} release-archive
 if((Get-FileHash $archive).Hash -ne '737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a'){throw 'ENV_BLOCK: official app archive hash mismatch'}
 $launcher=Join-Path $Evidence nvda_2025.3.3.exe
 Invoke-WebRequest 'https://download.nvaccess.org/releases/2025.3.3/nvda_2025.3.3.exe' -UseBasicParsing -OutFile $launcher -TimeoutSec 60
 Json @{Path=$launcher;Size=(Get-Item $launcher).Length;Sha256=(Get-FileHash $launcher).Hash;Signature=Get-AuthenticodeSignature $launcher|Select-Object Status,StatusMessage,SignerCertificate} nvda-launcher
 if((Get-FileHash $launcher).Hash -ne '15b5e9864032565e7f895e4d80d767f180db0ec264e892240e675c426cfca921'){throw 'ENV_BLOCK: official NVDA launcher hash mismatch'}
 # Documented official portable creation; child exit is observed through cached handle.
 $install=Start-Process $launcher -ArgumentList '--create-portable-silent --portable-path C:\s3296\nvda --log-file C:\e3296\nvda-portable-setup.log' -PassThru
 $setupReceipt=New-ExitReceipt $install 'nvda-portable-setup' $launcher;$start=$install.StartTime.ToUniversalTime().ToString('o');$actual=$install.Path
 Json @{Id=$install.Id;Path=$actual;StartUtc=$start} owned-nvda-setup
 $wait=$install.WaitForExit(60000);$code=$null;if($wait){$code=$install.ExitCode}else{$install.Kill();$cleanupWait=$install.WaitForExit(3000);Json @{WaitAfterKill=$cleanupWait;HasExited=$install.HasExited;ExitCode=if($cleanupWait){$install.ExitCode}else{$null}} nvda-setup-timeout-cleanup}
 Json @{Pid=$install.Id;ActualPath=$actual;StartUtc=$start;WaitBoolean=$wait;HasExited=$install.HasExited;ExitCodeIsNull=$null -eq $code;ExitCodeType=if($null -ne $code){$code.GetType().FullName}else{$null};ExitCodeValue=$code} nvda-portable-setup-exit
 Complete-ExitReceipt $install $setupReceipt $wait
 if($setupReceipt.Status -ne 'EXIT_ZERO'){throw 'ENV_BLOCK: portable setup exact exit not zero'}
 $nvdaExe='C:\s3296\nvda\nvda.exe';$script:NvdaLog=Join-Path $Evidence nvda-runtime-original.log
 Json @{Path=$nvdaExe;Sha256=(Get-FileHash $nvdaExe).Hash;Version=(Get-Item $nvdaExe).VersionInfo|Select-Object FileVersion,ProductVersion;Signature=Get-AuthenticodeSignature $nvdaExe|Select-Object Status,StatusMessage} nvda-runtime-artifact
 $script:Nvda=Launch-Owned $nvdaExe "--config-path C:\s3296\nvda-profile --log-file $script:NvdaLog --log-level 12"
 Start-Sleep -Seconds 4
 if(([IO.File]::ReadAllText($script:NvdaLog)) -notmatch '2025\.3\.3'){throw 'ENV_BLOCK: actual NVDA log version absent'}
 $script:Stage='nvda-control';$script:PhaseDeadline=$Deadline.AddMinutes(-7)
 $notepad=Launch-Owned "$env:WINDIR\System32\notepad.exe";Window-Owned $notepad
 $sentinel='nvda3296actualspokenline'
 Keys $notepad $sentinel;Keys $notepad '{HOME}'
 $tree=@(Snapshot $notepad);Json $tree notepad-typed-control
 if(@($tree|Where-Object{$_.AutomationId -eq '15' -and ($_.Name -ceq $sentinel -or $_.Value -ceq $sentinel)}).Count -ne 1){throw 'ENV_BLOCK: Notepad native typed sentinel readback absent'}
 $offset=Log-Offset;Nvda-Gesture $notepad 0x26 'Up';Save-Desktop notepad-line-read
 $speech=Speech-Since $offset notepad-line
 if($speech -notmatch $sentinel){throw 'ENV_BLOCK: actual NVDA spoken sentinel absent; no product verdict'}
 # Actual standard File menu provides a named control/role control through native Alt+F.
 $offset=Log-Offset;Keys $notepad '%f';Nvda-Gesture $notepad 0x09 'Tab';Save-Desktop notepad-file-menu
 $named=Speech-Since $offset notepad-menu
 if($named -notmatch '(?i)(file|new|open)' -or $named -notmatch '(?i)menu'){throw 'ENV_BLOCK: authentic named menu speech control absent'}
 Keys $notepad '{ESC}';$script:ControlQualified=$true
 $script:Stage='app-sighted-control';$script:PhaseDeadline=$Deadline.AddMinutes(-4)
 Expand-Archive -LiteralPath $archive -DestinationPath C:\s3296\app
 $exe=@(Get-ChildItem C:\s3296\app -Filter localsend_app.exe -Recurse|Select-Object -ExpandProperty FullName)
 if($exe.Count -ne 1){throw 'ENV_BLOCK: official executable ambiguous'};$exe=$exe[0]
 $version=(Get-Item $exe).VersionInfo
 $stream=[IO.File]::OpenRead($exe);try{$reader=[IO.BinaryReader]::new($stream);$stream.Position=0x3c;$pe=$reader.ReadInt32();$stream.Position=$pe+4;$machine=$reader.ReadUInt16()}finally{$stream.Dispose()}
 Json @{Path=$exe;Sha256=(Get-FileHash $exe).Hash;Version=$version|Select-Object FileVersion,ProductVersion;Machine=$machine;Signature=Get-AuthenticodeSignature $exe|Select-Object Status,StatusMessage} app-artifact
 if($machine -ne 0x8664 -or $version.ProductVersion -notmatch '^1\.18\.2(?:\D|$)'){throw 'ENV_BLOCK: selected app PE/version mismatch'}
 $script:Profile=Join-Path (Split-Path $exe) settings.json
 if(Test-Path $script:Profile){Profile-Receipt archive-original-settings|Out-Null}else{Json @{Path=$script:Profile;Exists=$false} archive-original-settings}
 # Ordinary release portable profile, English only, fresh isolated settings; app bytes unchanged.
 $settings=@{'flutter.ls_locale'='en';'flutter.ls_whats_new'='1.18.2'}
 [IO.File]::WriteAllText($script:Profile,($settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 Profile-Receipt profile-source-before-launch|Out-Null
 $app=Launch-Owned $exe;Window-Owned $app;[Issue3456Native]::ShowWindow([IntPtr]$app.Hwnd,3)|Out-Null;Write-Event maximize @{App=$app};Click-Name $app Settings
 Save-Desktop settings-before;Profile-Receipt settings-original|Out-Null
 $map=Quick-Map $app;$originalToggle=$null;$oppositeToggle=$null
 if($map.Toggle -eq 0 -or $map.Toggle -eq 1){$originalToggle=$map.Toggle;$oppositeToggle=1-$originalToggle}
 Json @{MappedControl=$map;OriginalNativeToggle=$originalToggle;OppositeNativeToggle=$oppositeToggle;UnsupportedMeansUnknown=$true;ProfileIsSupplemental=$true} baseline-state
 Click-Control $app $map;Dismiss-Notice $app;Read-State $app $oppositeToggle sighted-opposite|Out-Null
 $map=Quick-Map $app;Click-Control $app $map;Dismiss-Notice $app;Read-State $app $originalToggle sighted-restored|Out-Null
 # Re-enter with real keyboard navigation after native focus of the Settings tab.
 Click-Name $app Receive
 $reentered=$false
 for($navigation=1;$navigation -le 12;$navigation++){
  Keys $app '{TAB}';$navFocus=@(Snapshot $app|Where-Object Focused)
  Write-Event settingsKeyboardReentry @{Step=$navigation;Focus=$navFocus}
  if($navFocus.Count -eq 1 -and $navFocus[0].Name -eq 'Settings'){Keys $app ' ';$reentered=$true;break}
 }
 if(-not $reentered){throw 'ENV_BLOCK: Settings tab not reached by bounded actual keyboard navigation'}
 if(@(Snapshot $app|Where-Object Name -eq 'Quick Save').Count -ne 1){throw 'ENV_BLOCK: bounded keyboard Settings re-entry absent'}
 $script:Stage='keyboard-target';$script:PhaseDeadline=$Deadline;$map=Quick-Map $app;$seen=@{};$firstId=$null;$matched=$false;$cycle=$false;$traversal=@()
 for($i=1;$i -le 40;$i++){
  Check-Budget;$offset=Log-Offset;Keys $app '{TAB}';Nvda-Gesture $app 0x09 'Tab'
  $focused=@(Snapshot $app|Where-Object Focused);$speech=Speech-Since $offset "tab-$i";Save-Desktop "tab-$i"
  if($focused.Count -ne 1){throw 'ENV_BLOCK: actual focused object ambiguous or missing'}
  $f=$focused[0];$id="$($app.Hwnd)/$($f.RuntimeId)";$entry=@{Tab=$i;Hwnd=$app.Hwnd;Focus=$f;Speech=$speech};$traversal+=$entry;Json $traversal traversal
  if($f.Left -eq $map.Left -and $f.Top -eq $map.Top -and $f.Right -eq $map.Right -and $f.Bottom -eq $map.Bottom -and $f.Type -eq $map.Type){$matched=$true;break}
  if(-not $firstId){$firstId=$id}
  if($seen.ContainsKey($id)){if($seen.Count -ge 3 -and $id -eq $firstId){$cycle=$true;break}else{throw 'ENV_BLOCK: stalled or incomplete keyboard cycle'}};$seen[$id]=$true
 }
 if(-not $matched){
  Json @{Status=if($cycle){'OBSERVED_REACHABILITY_CANDIDATE'}else{'ENV_BLOCK'};ProductVerdict='REQUIRES_RAW_REVIEW';ControlQualified=$script:ControlQualified;CompleteCycle=$cycle;Tabs=$traversal.Count;Target=$map;Difference='Server 2022, chosen app/NVDA versions; original versions unknown'} final-result
  exit 2
 }
 # Speech attribution starts only at the previously operated, exactly bounded Quick Save control.
 $offset=Log-Offset;Nvda-Gesture $app 0x09 'Tab';$before=Speech-Since $offset target-before
 if(-not $before){throw 'ENV_BLOCK: no authentic target focus speech'}
 Start-Clip quick-save-keyboard
 try{$offset=Log-Offset;Keys $app ' ';Nvda-Gesture $app 0x09 'Tab';Save-Desktop target-after-space;$after=Speech-Since $offset target-after;if(-not $after){throw 'ENV_BLOCK: target action actual speech absent'};Dismiss-Notice $app;Read-State $app $oppositeToggle keyboard-opposite|Out-Null;Save-Desktop target-state-opposite;Start-Sleep -Seconds 2}finally{Stop-Clip}
 $complete=$before -match '(?i)Quick Save' -and $before -match '(?i)(check ?box|switch)' -and $before -match '(?i)(checked|unchecked|on|off)'
 $map=Quick-Map $app;Click-Control $app $map;Dismiss-Notice $app;Read-State $app $originalToggle final-restored|Out-Null;Save-Desktop final-restored
 Json @{Status='COMPLETED';ProductVerdict=if($null -eq $originalToggle){'STATE_REQUIRES_RAW_REVIEW'}elseif($complete){'NON_REPRODUCTION'}else{'NAMED_CONTROL_SYMPTOM_CANDIDATE'};ActualControlQualified=$true;TargetBounded=$true;BeforeSpeech=$before;AfterSpeech=$after;RealSpaceStateChanged=if($null -ne $originalToggle){$true}else{$null};Restored=if($null -ne $originalToggle){$true}else{$null};OriginalNativeToggle=$originalToggle;OppositeNativeToggle=$oppositeToggle;ProductExperiments=1;Difference='Server 2022 differs from report Windows 10/11; original numeric app/NVDA unknown';Review='Inspect original speech/pixels/clip before accepting a product failure; no UIA-only verdict'} final-result
}catch{
 if(Get-Command Save-Desktop -ErrorAction SilentlyContinue){try{Save-Desktop "$script:Stage-exception"}catch{}}
 $_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt)
 Json @{Status='ENV_BLOCK';ProductVerdict='NONE';Error="$_";Stage=$script:Stage;ActualControlQualified=$script:ControlQualified} final-result
 exit 2
}finally{
 try{Stop-Clip}catch{};foreach($a in $script:Owned){try{Stop-Owned $a}catch{}}
 if(Test-Path C:\s3296\nvda-profile\nvda.ini){Copy-Item C:\s3296\nvda-profile\nvda.ini (Join-Path $Evidence nvda-original-profile.ini)}
 Stop-Transcript
}
