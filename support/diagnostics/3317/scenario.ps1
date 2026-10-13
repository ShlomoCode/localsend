param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline,[string]$PrelaunchPhase,[string]$PhaseContext,[string]$PhaseTag)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot prelaunch.ps1)
if($PrelaunchPhase){Run-PrelaunchPhase}
$script:Recorder=$null;$script:ProductStarted=$false;$script:CompletedConditions=@();$script:AutoStartOwned=$false
Start-Transcript (Join-Path $Evidence scenario-original.txt)
function Find-SettingsNavigation($App){
 $tree=@(Snapshot $App);$views=@($tree|Where-Object ClassName -eq FLUTTERVIEW)
 if($views.Count -ne 1){throw 'ENV_BLOCK: unique Flutter client unavailable'}
 $view=$views[0];$rail=@()
 foreach($name in @("Receive`nTab 1 of 3","Send`nTab 2 of 3","Settings`nTab 3 of 3")){
  $matches=@($tree|Where-Object {$_.Name -eq $name -and $_.Type -in @(50000,50019,50020) -and $_.Enabled -and $_.Pid -eq $App.Id})
  if($matches.Count -ne 1){throw 'ENV_BLOCK: complete unique three-item navigation unavailable'}
  $c=$matches[0]
  if($c.Right -le $c.Left -or $c.Bottom -le $c.Top -or $c.Left -lt $view.Left -or $c.Right -gt $view.Right -or $c.Top -lt $view.Top -or $c.Bottom -gt $view.Bottom){throw 'ENV_BLOCK: navigation bounds outside live client'}
  $rail+=$c
 }
 Json @{View=$view;AllThree=$rail;SupportedRenderedTextType=50020} "$script:Stage-navigation-binding"
 return $rail[2]
}
function Bind-GeneralBooleanRows($App,$CompositeName,$LanguageName,$BooleanLabels){
 $tree=@(Snapshot $App);$groups=@($tree|Where-Object {$_.Name -eq $CompositeName -and $_.Type -eq 50026});$navigation=@(Find-SettingsNavigation $App);$views=@($tree|Where-Object ClassName -eq FLUTTERVIEW)
 if($groups.Count -ne 1 -or $navigation.Count -ne 1 -or $views.Count -ne 1){throw 'ENV_BLOCK: unique source-contracted General composite/navigation unavailable'}
 $group=$groups[0];$inside={param($c) $c.Left -ge $group.Left -and $c.Right -le $group.Right -and $c.Top -ge $group.Top -and $c.Bottom -le $group.Bottom}
 $view=$views[0];$nav=$navigation[0]
 if($group.Left -lt $view.Left -or $group.Right -gt $view.Right -or $group.Top -lt $view.Top -or $group.Bottom -gt $view.Bottom){throw 'ENV_BLOCK: General rows outside visible native client bounds'}
 if(-not ($group.Bottom -le $nav.Top -or $group.Left -ge $nav.Right)){throw 'ENV_BLOCK: General rows overlap actual bottom/rail navigation'}
 $visibleBottom=if($group.Left -ge $nav.Right){$view.Bottom}else{$nav.Top}
 $language=@($tree|Where-Object {$_.Name -eq $LanguageName -and $_.Type -eq 50000 -and (& $inside $_)})
 $checks=@($tree|Where-Object {$_.Type -eq 50002 -and (& $inside $_)}|Sort-Object Top)
 if($language.Count -ne 1 -or $checks.Count -ne $BooleanLabels.Count){throw 'ENV_BLOCK: complete source-contracted General row controls unavailable'}
 $rows=@();$previous=$language[0]
 for($i=0;$i -lt $checks.Count;$i++){
  $c=$checks[$i]
  if(-not $c.Enabled -or $c.Pid -ne $App.Id -or $c.Toggle -notin @(0,1) -or $c.Top -le $previous.Bottom){throw 'ENV_BLOCK: General row order/toggle/ownership ambiguous'}
  if($i -gt 0 -and ($c.Left -ne $checks[0].Left -or $c.Right -ne $checks[0].Right)){throw 'ENV_BLOCK: source Boolean column alignment differs'}
  $top=[int][Math]::Floor(($previous.Bottom+$c.Top)/2)
  $bottom=if($i+1 -lt $checks.Count){[int][Math]::Floor(($c.Bottom+$checks[$i+1].Top)/2)}else{$group.Bottom}
  if($top -lt $group.Top -or $bottom -gt $group.Bottom -or $bottom -gt $visibleBottom -or $c.Top -lt $top -or $c.Bottom -gt $bottom){throw 'ENV_BLOCK: full rendered Boolean row not inside visible General bounds'}
  $rows+=[pscustomobject]@{Label=$BooleanLabels[$i];SourceOrdinal=$i;Control=$c;Row=[pscustomobject]@{Left=$group.Left;Top=$top;Right=$group.Right;Bottom=$bottom};LabelArea=[pscustomobject]@{Left=$group.Left;Top=$top;Right=$c.Left;Bottom=$bottom}}
  $previous=$c
 }
 Json @{SourceContract='v1.18.2 SettingsTab General: Theme, Color, Language, then minimizeToTray, launchAtStartup, animations; advanced rows absent; autostart-hidden row included only in the explicitly selected four-row condition';Composite=$group;Language=$language[0];Rows=$rows;Tree=$tree} "$script:Stage-general-row-binding"
 return $rows
}
function Save-RowPixels($Row,$Name){
 Check-Budget;$screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
 if($Row.Left -lt $screen.Left -or $Row.Top -lt $screen.Top -or $Row.Right -gt $screen.Right -or $Row.Bottom -gt $screen.Bottom){throw 'ENV_BLOCK: row pixels outside actual desktop'}
 $size=[System.Drawing.Size]::new($Row.Right-$Row.Left,$Row.Bottom-$Row.Top);$b=[System.Drawing.Bitmap]::new($size.Width,$size.Height);$g=[System.Drawing.Graphics]::FromImage($b)
 try{$g.CopyFromScreen([System.Drawing.Point]::new($Row.Left,$Row.Top),[System.Drawing.Point]::Empty,$size);$b.Save((Join-Path $Evidence "$Name.png"),[System.Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
 Json $Row "$Name-bounds"
}
function Set-GeneralContract([bool]$HiddenVisible){
 $script:BooleanLabels=@('Minimize to the System Tray/Menu Bar when closing','Autostart after login')
 if($HiddenVisible){$script:BooleanLabels+='Autostart: Start hidden'}
 $script:BooleanLabels+='Animations'
 $script:GeneralComposite=(@('General','Theme','Color','Language')+$script:BooleanLabels) -join "`n"
}
function AutoStart-Receipt($App,$Name){
 $props=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
 $value=if($props){$props.LocalSend}else{$null}
 $receipt=[pscustomobject]@{Path='HKCU Software Microsoft Windows CurrentVersion Run';Name='LocalSend';Value=$value;Enabled=$value -eq ('"'+$App.Path+'"') -or $value -eq ('"'+$App.Path+'" --hidden');Hidden=$value -eq ('"'+$App.Path+'" --hidden');ObservedOnly=$true}
 Json $receipt $Name;return $receipt
}
function Set-AutoStartThroughUI($App,$Label,[bool]$Desired,[bool]$HiddenVisibleAfter,$Name){
 Check-Budget
 if($script:ProductEnd -and [DateTime]::UtcNow -ge $script:ProductEnd){throw 'ENV_BLOCK: screenshot configuration product deadline'}
 $rows=@(Bind-GeneralBooleanRows $App $script:GeneralComposite 'English' $script:BooleanLabels)
 $target=@($rows|Where-Object Label -eq $Label)
 if($target.Count -ne 1){throw 'ENV_BLOCK: autostart configuration row ambiguous'}
 Save-RowPixels $target[0].Row "$Name-before";Save-Desktop "$Name-before"
 if(($target[0].Control.Toggle -eq 1) -ne $Desired){Click-Control $App $target[0].Control}
 Set-GeneralContract $HiddenVisibleAfter
 Start-Sleep -Milliseconds 600
 $rows=@(Bind-GeneralBooleanRows $App $script:GeneralComposite 'English' $script:BooleanLabels)
 $target=@($rows|Where-Object Label -eq $Label)
 if($target.Count -ne 1 -or ($target[0].Control.Toggle -eq 1) -ne $Desired){throw 'ENV_BLOCK: native autostart configuration did not reach expected toggle'}
 Save-RowPixels $target[0].Row "$Name-after";Save-Desktop "$Name-after"
 $receipt=AutoStart-Receipt $App "$Name-app-written-registry"
 if($Label -eq 'Autostart after login' -and ($receipt.Enabled -ne $Desired -or (-not $Desired -and $receipt.Value))){throw 'ENV_BLOCK: app-written autostart registry disagrees'}
 if($Label -eq 'Autostart: Start hidden' -and (-not $receipt.Enabled -or $receipt.Hidden -ne $Desired)){throw 'ENV_BLOCK: app-written hidden registry disagrees'}
}
function Observe-Row($App,$Label,$Key,[bool]$Default,$Name){
 Check-Budget
 if($script:ProductEnd -and [DateTime]::UtcNow -ge $script:ProductEnd){throw 'ENV_BLOCK: selected product condition deadline'}
 $rows=@(Bind-GeneralBooleanRows $App $script:GeneralComposite 'English' $script:BooleanLabels)
 $target=@($rows|Where-Object Label -eq $Label)
 if($target.Count -ne 1){throw 'ENV_BLOCK: unique target row missing'}
 $profile=Get-Content $App.Profile -Raw -Encoding UTF8|ConvertFrom-Json
 $entry=$profile.PSObject.Properties[$Key];$explicit=$null -ne $entry
 $value=if($explicit){$entry.Value}else{$Default}
 if($value -isnot [bool]){throw 'ENV_BLOCK: persisted Boolean type invalid'}
 Save-RowPixels $target[0].Row $Name;Save-Desktop $Name
 $receipt=[pscustomobject]@{Label=$Label;Key=$Key;NativeToggle=$target[0].Control.Toggle;EffectivePreference=$value;ExplicitKey=$explicit;SourceDefault=$Default;ObservedOnly=$true;ProfileSha256=(Get-FileHash $App.Profile).Hash;Row=$target[0];Utc=[DateTime]::UtcNow.ToString('o')}
 Json $receipt $Name;Profile-Receipt $App "$Name-profile"|Out-Null
 return $receipt
}
function Toggle-Row($App,$Label,$Key,[bool]$Default,$Name){
 $before=Observe-Row $App $Label $Key $Default "$Name-before"
 if(-not $script:ProductStarted -and (($before.NativeToggle -eq 1) -ne $before.EffectivePreference)){throw 'ENV_BLOCK: initial UI/preference disagreement; no valid input control'}
 Click-Control $App $before.Row.Control
 $expected=$before.NativeToggle -eq 0;$end=[DateTime]::UtcNow.AddSeconds(3)
 do{
  $after=Observe-Row $App $Label $Key $Default "$Name-after"
  if(($after.NativeToggle -eq 1) -eq $expected -and $after.ExplicitKey -and $after.EffectivePreference -eq $expected){break}
  Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $end)
 $success=($after.NativeToggle -eq 1) -eq $expected -and $after.ExplicitKey -and $after.EffectivePreference -eq $expected
 $result=[pscustomobject]@{Name=$Name;Before=$before;After=$after;Expected=$expected;InputSucceeded=$success}
 Json $result "$Name-result";return $result
}
try{
 . (Join-Path $PSScriptRoot ui.ps1)
 $os=Get-CimInstance Win32_OperatingSystem
 Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Architecture=$env:PROCESSOR_ARCHITECTURE;Desktop=[System.Windows.Forms.SystemInformation]::VirtualScreen;Difference='Windows Server2022 build20348, different from reported Windows11 x64; reported original/previous version and installation unknown'} environment
 if($os.Caption -notmatch 'Windows Server 2022' -or $os.BuildNumber -ne '20348' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'ENV_BLOCK: environment mismatch'}
 $desktop=[Issue3456Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw 'ENV_BLOCK: input desktop absent'};[Issue3456Native]::CloseDesktop($desktop)|Out-Null
 if(Test-Path C:\s3317){throw 'ENV_BLOCK: pre-existing unowned profile root'};New-Item -ItemType Directory C:\s3317|Out-Null
 $script:Archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip
 Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip' -UseBasicParsing -OutFile $script:Archive -TimeoutSec 90
 $hash=(Get-FileHash $script:Archive).Hash;Json @{Path=$script:Archive;Sha256=$hash} archive
 if($hash -ne '737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a'){throw 'ENV_BLOCK: official ZIP hash mismatch'}
 $script:App=Launch-App app 53317 C:\s3317 (Join-Path $PSScriptRoot scenario.ps1)
 $script:Stage='settings-navigation';Click-Name $script:App Maximize 50000
 $end=[DateTime]::UtcNow.AddSeconds(5)
 do{Check-Budget;if([Tray3166Native]::Zoomed([IntPtr]$script:App.Hwnd)){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 if(-not [Tray3166Native]::Zoomed([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: native Maximize not confirmed'}
 Save-Desktop settings-navigation-before;Click-Control $script:App (Find-SettingsNavigation $script:App)
 Set-GeneralContract $false
 $null=Bind-GeneralBooleanRows $script:App $script:GeneralComposite 'English' $script:BooleanLabels
 Save-Desktop settings-general-qualified
 $script:RoundProductEnd=[DateTime]::UtcNow.AddSeconds(180);$script:ProductEnd=[DateTime]::UtcNow.AddSeconds(90);$script:Stage='animations-control'
 $control1=Toggle-Row $script:App 'Animations' 'flutter.ls_enable_animations' $true animations-change
 if(-not $control1.InputSucceeded){throw 'ENV_BLOCK: ordinary Animations working control failed'}
 $control2=Toggle-Row $script:App 'Animations' 'flutter.ls_enable_animations' $true animations-restore
 if(-not $control2.InputSucceeded){throw 'ENV_BLOCK: ordinary Animations restore failed'}
 $script:Stage='minimize-toggle'
 $initial=Observe-Row $script:App $script:BooleanLabels[0] 'flutter.ls_minimize_to_tray' $false minimize-initial
 if(($initial.NativeToggle -eq 1) -ne $initial.EffectivePreference){throw 'ENV_BLOCK: target initial UI/preference qualification disagrees'}
 $script:ProductStarted=$true;$outcomes=@()
 foreach($repeat in 1..2){
  $capture=Test-Path (Join-Path $Evidence capture-qualified.json)
  if($capture){try{Start-Clip "minimize-repeat$repeat"}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "recorder-repeat$repeat-block"}}
  try{
   $outcomes+=Toggle-Row $script:App $script:BooleanLabels[0] 'flutter.ls_minimize_to_tray' $false "repeat$repeat-change"
   $outcomes+=Toggle-Row $script:App $script:BooleanLabels[0] 'flutter.ls_minimize_to_tray' $false "repeat$repeat-restore"
  }finally{try{Stop-Clip}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "recorder-repeat$repeat-stop-block"}}
 }
 $failed=@($outcomes|Where-Object {-not $_.InputSucceeded})
 $script:CompletedConditions+=@{Name='fresh-profile';Outcomes=$outcomes;Failure=$failed.Count -gt 0}
 if(-not $failed.Count -and ($script:RoundProductEnd-[DateTime]::UtcNow).TotalSeconds -ge 30){
  $script:Stage='autostart-screenshot-configuration';$script:ProductStarted=$false
  $script:ProductEnd=[DateTime]::UtcNow.AddSeconds(90);if($script:ProductEnd -gt $script:RoundProductEnd){$script:ProductEnd=$script:RoundProductEnd}
  $start=AutoStart-Receipt $script:App autostart-original
  if($start.Value){throw 'ENV_BLOCK: pre-existing LocalSend startup registration unowned'}
  $script:AutoStartOwned=$true
  Set-AutoStartThroughUI $script:App 'Autostart after login' $true $true autostart-enable
  Set-AutoStartThroughUI $script:App 'Autostart: Start hidden' $true $true hidden-enable
  $script:Stage='minimize-toggle-screenshot-profile';$script:ProductStarted=$true;$configured=@()
  foreach($repeat in 1..2){
   $capture=Test-Path (Join-Path $Evidence capture-qualified.json)
   if($capture){try{Start-Clip "screenshot-profile-repeat$repeat"}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "configured-recorder$repeat-block"}}
   try{
    $configured+=Toggle-Row $script:App $script:BooleanLabels[0] 'flutter.ls_minimize_to_tray' $false "configured-repeat$repeat-change"
    $configured+=Toggle-Row $script:App $script:BooleanLabels[0] 'flutter.ls_minimize_to_tray' $false "configured-repeat$repeat-restore"
   }finally{try{Stop-Clip}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "configured-recorder$repeat-stop-block"}}
  }
  $configuredFailed=@($configured|Where-Object {-not $_.InputSucceeded})
  $script:CompletedConditions+=@{Name='autostart-on-start-hidden-on';Outcomes=$configured;Failure=$configuredFailed.Count -gt 0}
  $script:Stage='restore-startup-configuration'
  Set-AutoStartThroughUI $script:App 'Autostart: Start hidden' $false $true hidden-restore
  Set-AutoStartThroughUI $script:App 'Autostart after login' $false $false autostart-restore
  $script:AutoStartOwned=$false
 }
 $anyFailure=@($script:CompletedConditions|Where-Object Failure).Count -gt 0
 Json @{Status=if($anyFailure){'CURRENT_RELEASE_FAILURE'}else{'CURRENT_RELEASE_NON_REPRODUCTION'};ProductExperiments=$script:CompletedConditions.Count;IdenticalRepetitions=2;Conditions=$script:CompletedConditions;Controls=@($control1,$control2);SameApp=$script:App;OS='WindowsServer2022 build20348';OriginalWindows11='UNTESTED';HistoricalAttribution='UNKNOWN'} final-result
 if($anyFailure){exit 1}
}catch{
 try{Save-Desktop "$script:Stage-exception"}catch{}
 $_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt)
 Json @{Status='ENV_BLOCK';Error="$_";TargetInputStarted=$script:ProductStarted;ProductExperiments=$script:CompletedConditions.Count;CompletedConditions=$script:CompletedConditions;Verdict='Infrastructure block; incomplete condition has no product verdict'} final-result;exit 2
}finally{
 try{Stop-Clip}catch{}
 if($script:AutoStartOwned){
  try{
   $script:Stage='configuration-cleanup';$script:ProductEnd=$null
   $state=AutoStart-Receipt $script:App cleanup-startup-before
   if($state.Enabled){
    Set-GeneralContract $true
    if($state.Hidden){Set-AutoStartThroughUI $script:App 'Autostart: Start hidden' $false $true cleanup-hidden}
    Set-AutoStartThroughUI $script:App 'Autostart after login' $false $false cleanup-autostart
   }
   $finalStartup=AutoStart-Receipt $script:App cleanup-startup-final
   if($finalStartup.Value){throw 'ENV_BLOCK: owned startup entry remains; cleanup unknown'}
   Json @{Status='NATIVE_CONFIGURATION_RESTORED'} configuration-cleanup
  }catch{Json @{Status='CONFIGURATION_CLEANUP_UNKNOWN';Error="$_"} configuration-cleanup}
 }
 foreach($a in $script:Owned){try{Stop-Owned $a}catch{}};Stop-Transcript}
