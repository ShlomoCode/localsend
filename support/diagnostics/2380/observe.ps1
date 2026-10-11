param([string]$ReleaseRoot,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/capture_progress.ps1"
. "$PSScriptRoot/desktop.ps1" -ReleaseRoot $ReleaseRoot -EvidenceDirectory $EvidenceDirectory
Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture|ConvertTo-Json|Set-Content "$EvidenceDirectory/os.json"
Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,VideoModeDescription|ConvertTo-Json|Set-Content "$EvidenceDirectory/gpu.json"
@{image=$env:ImageOS;imageVersion=$env:ImageVersion;architecture=$env:PROCESSOR_ARCHITECTURE;screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString()}|ConvertTo-Json|Set-Content "$EvidenceDirectory/runner.json"
function Snapshot($name,$process) {
 $process.Refresh();$r=New-Object Desktop2861+Rect;$frame=New-Object Desktop2861+Rect;$handle=[IntPtr]::Zero
 if(!$process.HasExited -and $process.MainWindowHandle){$handle=$process.MainWindowHandle}
 $clientOk=[Desktop2861]::GetClientRect($handle,[ref]$r)
 $frameOk=[Desktop2861]::GetWindowRect($handle,[ref]$frame)
 $nullResult=[UIntPtr]::Zero;$health=[Desktop2861]::SendMessageTimeout($handle,0,[UIntPtr]::Zero,[IntPtr]::Zero,2,1000,[ref]$nullResult)
 $owner=[uint32]0;[Desktop2861]::GetWindowThreadProcessId($handle,[ref]$owner)|Out-Null
 @{validWindow=($handle -ne [IntPtr]::Zero -and $clientOk -and $frameOk -and $r.right -gt 0 -and $r.bottom -gt 0 -and $owner -eq $process.Id);windowOwner=$owner;elapsedSeconds=$(if($launchClock){$launchClock.Elapsed.TotalSeconds}else{$null});wmNullResponded=($health -ne [IntPtr]::Zero);cpuSeconds=$process.CPU;utc=[DateTime]::UtcNow.ToString('o');pid=$process.Id;hasExited=$process.HasExited;window=$handle.ToInt64();foreground=[Desktop2861]::GetForegroundWindow().ToInt64();frame=$frame;client=@{width=$r.right;height=$r.bottom};dpi=[Desktop2861]::GetDpiForWindow($handle)}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-state.json"
 $bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
 $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height);$g=[System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size);$bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$bmp.Dispose()
 # Native geometry and rendered pixels measure this bug; avoid blocking its startup on a UIA provider.
 Get-Process|Where-Object{$_.MainWindowHandle -ne [IntPtr]::Zero}|Select-Object Id,Name,MainWindowTitle,MainWindowHandle|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-windows.json"
}
function FocusLocalSend($process) {
 Snapshot "focus-$($process.Id)-before" $process
 [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
 $process.Refresh();if(!$process.MainWindowHandle){throw 'No LocalSend window to focus'}
 [Desktop2861]::SetForegroundWindow($process.MainWindowHandle)|Out-Null
 $window=New-Object Desktop2861+Rect;[Desktop2861]::GetWindowRect($process.MainWindowHandle,[ref]$window)|Out-Null
 [Desktop2861]::SetCursorPos([int]$window.Left+100,[int]$window.Top+15)|Out-Null
 [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 500
 Snapshot "focus-$($process.Id)-after" $process
 if([Desktop2861]::GetForegroundWindow() -ne $process.MainWindowHandle){throw 'Real title-bar focus did not reach LocalSend; before/after pixels and geometry retained'}
}
function CloseSeedNormally($name,$process) {
 $requested=[DateTime]::UtcNow.ToString('o')
 if(!$process.CloseMainWindow()){throw 'Normal seed close request failed'}
 if(!$process.WaitForExit(20000)){throw 'Seed did not exit normally; saved profile is invalid'}
 @{requestedUtc=$requested;exitedUtc=[DateTime]::UtcNow.ToString('o');pid=$process.Id;normalExit=$true}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-close.json"
}
function AssertSavedGeometry($name,$stateName) {
 $saved=Get-Content $profileFile -Raw|ConvertFrom-Json
 $state=Get-Content "$EvidenceDirectory/$stateName-state.json" -Raw|ConvertFrom-Json
 if(!$state.validWindow -or $state.dpi -ne 96){throw 'Saved geometry comparison requires valid seed window at DPI 96'}
 $expected=@{ls_window_offset_x=$state.frame.left;ls_window_offset_y=$state.frame.top;ls_window_width=($state.frame.right-$state.frame.left);ls_window_height=($state.frame.bottom-$state.frame.top)}
 foreach($key in $expected.Keys){
  $property=$saved.PSObject.Properties["flutter.$key"]
  if(!$property -or $null -eq $property.Value -or [double]::IsNaN([double]$property.Value) -or [double]::IsInfinity([double]$property.Value) -or [Math]::Abs([double]$property.Value-[double]$expected[$key]) -gt 2){throw "Saved $name geometry does not match measured seed: $key"}
 }
 @{savedGeometryMatchesNative=$true;expected=$expected;dpi=$state.dpi}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-geometry-validity.json"
}
$app=$null;$recording=$null;$launchClock=$null
try {
Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
$exe=Get-ChildItem $ReleaseRoot -Filter localsend_app.exe -Recurse|Select-Object -First 1
Get-FileHash $exe.FullName|ConvertTo-Json|Set-Content "$EvidenceDirectory/localsend-exe.json"
New-NetFirewallRule -DisplayName 'Bug2380 disposable LocalSend' -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any|Out-Null
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 15
FocusLocalSend $app
Start-Sleep -Seconds 2
Snapshot 'control-no-powertoys' $app
$profilePaths=@((Join-Path $exe.DirectoryName 'settings.json'),"$env:APPDATA/LocalSend/settings.json","$env:APPDATA/org.localsend/localsend_app/shared_preferences.json")
$profileFile=$profilePaths|Where-Object{Test-Path $_}|Select-Object -First 1
if(!$profileFile){throw 'Cannot freeze actual LocalSend settings store'}
function SaveProfile($name) {
 $profile=Get-Content $profileFile -Raw|ConvertFrom-Json
 foreach($property in $profile.PSObject.Properties){if($property.Name -match 'security_context|show_token|pin'){$property.Value='<REDACTED>'}}
 @{path=$profileFile;hash=(Get-FileHash $profileFile).Hash;settings=$profile}|ConvertTo-Json -Depth 20|Set-Content "$EvidenceDirectory/$name-settings.json"
}
SaveProfile 'wide-before-close'
CloseSeedNormally 'wide' $app
AssertSavedGeometry 'wide' 'control-no-powertoys'
$wideProfile=[System.IO.File]::ReadAllBytes($profileFile)
SaveProfile 'wide-frozen'
$roots=@("$env:LOCALAPPDATA/PowerToys","$env:ProgramFiles/PowerToys","${env:ProgramFiles(x86)}/PowerToys")
@{localAppData=$env:LOCALAPPDATA;programFiles=$env:ProgramFiles;roots=$roots}|ConvertTo-Json|Set-Content "$EvidenceDirectory/paths.json"
Get-ChildItem $roots -Recurse -ErrorAction SilentlyContinue|Select-Object FullName,Length|ConvertTo-Json|Set-Content "$EvidenceDirectory/installed-files.json"
Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*','HKLM:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*'|Where-Object{$_.DisplayName -like '*PowerToys*'}|Select-Object DisplayName,DisplayVersion,InstallLocation,DisplayIcon|ConvertTo-Json|Set-Content "$EvidenceDirectory/installation-registry.json"
$pt=Get-ChildItem $roots -Filter '*PowerToys*.exe' -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.Name -eq 'PowerToys.exe'}|Select-Object -First 1
if(!$pt){throw 'Official PowerToys executable missing; inspect installed-files and installation-registry'}
Get-FileHash $pt.FullName|ConvertTo-Json|Set-Content "$EvidenceDirectory/powertoys-exe.json"
$power=Start-Process $pt.FullName -PassThru
Start-Sleep -Seconds 12
Snapshot 'powertoys-started' $power
Get-Process '*PowerToys*'|Select-Object Name,Id,Path,MainWindowHandle|ConvertTo-Json|Set-Content "$EvidenceDirectory/powertoys-processes.json"
$ptSettings="$env:LOCALAPPDATA/Microsoft/PowerToys"
Get-ChildItem $ptSettings -Recurse -File -Filter '*.json'|Where-Object{$_.Name -in @('settings.json','app-zone-history.json','applied-layouts.json','custom-layouts.json','layout-hotkeys.json','layout-templates.json')}|ForEach-Object {
 $relative=$_.FullName.Substring($ptSettings.Length).TrimStart([char[]]'\/');$target=Join-Path "$EvidenceDirectory/powertoys-settings" $relative
 New-Item -ItemType Directory -Force (Split-Path $target)|Out-Null;Copy-Item $_.FullName $target
}
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 15;Snapshot 'powertoys-default-localsend' $app
Stop-Process -Id $app.Id -Force
Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
# Wait for all module exits before replacing their persisted settings.
$exitDeadline=[DateTime]::UtcNow.AddSeconds(30)
while(Get-Process '*PowerToys*' -ErrorAction SilentlyContinue){
 if([DateTime]::UtcNow -gt $exitDeadline){throw 'PowerToys modules did not exit before configuration'}
 Start-Sleep -Milliseconds 250
}
$rootFile="$ptSettings/settings.json";$rootConfig=Get-Content $rootFile -Raw|ConvertFrom-Json
foreach($property in $rootConfig.enabled.PSObject.Properties){$property.Value=($property.Name -eq 'FancyZones')}
[System.IO.File]::WriteAllText($rootFile,($rootConfig|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
$fzFile="$ptSettings/FancyZones/settings.json";$fzConfig=Get-Content $fzFile -Raw|ConvertFrom-Json
foreach($key in @('fancyzones_appLastZone_moveWindows','fancyzones_overrideSnapHotkeys','fancyzones_shiftDrag')){
 $fzConfig.properties|Add-Member -MemberType NoteProperty -Name $key -Value @{value=$true} -Force
}
[System.IO.File]::WriteAllText($fzFile,($fzConfig|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
Copy-Item $fzFile "$EvidenceDirectory/restore-config.json"
$power=Start-Process $pt.FullName -PassThru;Start-Sleep -Seconds 10
Copy-Item $rootFile "$EvidenceDirectory/loaded-root-config.json";Copy-Item $fzFile "$EvidenceDirectory/loaded-fz-config.json"
Get-Process '*PowerToys*'|Select-Object Name,Id,Path|ConvertTo-Json|Set-Content "$EvidenceDirectory/zone-processes.json"
if(!(Get-Process PowerToys.FancyZones -ErrorAction SilentlyContinue)){throw 'FancyZones module not running'}
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class Input2380 {
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
}
"@
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru;Start-Sleep -Seconds 15
FocusLocalSend $app
Start-Sleep -Seconds 1;Snapshot 'restore-enabled-before-zone' $app
$history="$ptSettings/FancyZones/app-zone-history.json"
# Use actual Shift-drag; Windows Snap alone does not establish FancyZones history.
& {
 try {
 FocusLocalSend $app
 $window=New-Object Desktop2861+Rect;[Desktop2861]::GetWindowRect($app.MainWindowHandle,[ref]$window)|Out-Null
 $startX=[int]$window.Left+100;$startY=[int]$window.Top+15
 [Desktop2861]::SetCursorPos($startX,$startY)|Out-Null;[Input2380]::keybd_event(0x10,0,0,[UIntPtr]::Zero)
 [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 for($step=1;$step -le 20;$step++){[Desktop2861]::SetCursorPos([int]($startX+(300-$startX)*$step/20),[int]($startY+(350-$startY)*$step/20))|Out-Null;Start-Sleep -Milliseconds 40}
 Snapshot 'actual-shift-drag-highlight' $app
 [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero);[Input2380]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
 Start-Sleep -Seconds 3;Snapshot 'actual-shift-drag-zone' $app
 } finally {[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero);[Input2380]::keybd_event(0x10,0,2,[UIntPtr]::Zero)}
}
if(!(Test-Path $history)){throw 'No actual FancyZones history recorded'}
Copy-Item $history "$EvidenceDirectory/actual-zone-history.json"
$historyData=Get-Content $history -Raw|ConvertFrom-Json
if(!($historyData.'app-zone-history'|Where-Object{$_.'app-path' -ieq $exe.FullName})){throw 'LocalSend not found in genuine zone history'}
Get-ChildItem "$ptSettings/FancyZones" -File -Filter '*layouts.json'|Copy-Item -Destination $EvidenceDirectory
# Freeze both actual state files before diagnostic resizes alter either application.
$genuineHistoryBytes=[System.IO.File]::ReadAllBytes($history)
SaveProfile 'narrow-before-close'
$layout=Get-Content "$ptSettings/FancyZones/applied-layouts.json" -Raw|ConvertFrom-Json
$entry=$historyData.'app-zone-history'|Where-Object{$_.'app-path' -ieq $exe.FullName}|Select-Object -First 1
$zone=$entry.history|Where-Object{($_.'zone-index-set' -join ',') -eq '0'}|Select-Object -First 1
if(!$zone){throw 'Exact executable lacks genuine zone zero history'}
if(!($layout.'applied-layouts'|Where-Object{$_.device.monitor -eq $zone.device.monitor -and $_.device.'monitor-instance' -eq $zone.device.'monitor-instance' -and $_.'applied-layout'.uuid -eq $zone.'zoneset-uuid'})){throw 'Genuine history does not match applied monitor/layout'}
CloseSeedNormally 'narrow' $app
AssertSavedGeometry 'narrow' 'actual-shift-drag-zone'
$narrowProfile=[System.IO.File]::ReadAllBytes($profileFile)
SaveProfile 'narrow-frozen'
$wideSaved=[System.Text.Encoding]::UTF8.GetString($wideProfile)|ConvertFrom-Json
$narrowSaved=[System.Text.Encoding]::UTF8.GetString($narrowProfile)|ConvertFrom-Json
if($wideSaved.'flutter.ls_window_width' -eq $narrowSaved.'flutter.ls_window_width' -and $wideSaved.'flutter.ls_window_height' -eq $narrowSaved.'flutter.ls_window_height'){throw 'Frozen wide and narrow saved dimensions are identical'}
$baseFzConfig=Get-Content $fzFile -Raw
$cases=@(
 @{name='wide-enabled';profile=$wideProfile;restore=$true;excluded=''},
 @{name='wide-disabled';profile=$wideProfile;restore=$false;excluded=''},
 @{name='narrow-enabled';profile=$narrowProfile;restore=$true;excluded=''},
 @{name='narrow-disabled';profile=$narrowProfile;restore=$false;excluded=''},
 @{name='wide-excluded';profile=$wideProfile;restore=$true;excluded='localsend_app.exe'},
 @{name='wide-enabled-again';profile=$wideProfile;restore=$true;excluded=''}
)
 foreach($case in $cases){foreach($iteration in 1..3){
  $name="$($case.name)-$iteration";$recording=$null;$app=$null;$launchClock=$null;$recorderStartUtc=$null;$recorderClock=$null;$progress=$null
  try {
   Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
   $exitDeadline=[DateTime]::UtcNow.AddSeconds(30)
   while(Get-Process '*PowerToys*' -ErrorAction SilentlyContinue){if([DateTime]::UtcNow -gt $exitDeadline){throw 'PowerToys did not exit for frozen trial'};Start-Sleep -Milliseconds 250}
   [System.IO.File]::WriteAllBytes($profileFile,$case.profile)
   [System.IO.File]::WriteAllBytes($history,$genuineHistoryBytes)
   $fzConfig=$baseFzConfig|ConvertFrom-Json
   $fzConfig.properties.fancyzones_appLastZone_moveWindows.value=$case.restore
   $fzConfig.properties.fancyzones_excluded_apps.value=$case.excluded
   [System.IO.File]::WriteAllText($fzFile,($fzConfig|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
   SaveProfile "$name-before"
   if([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($profileFile)) -ne [Convert]::ToBase64String($case.profile)){throw 'Frozen application settings differ before trial'}
   Copy-Item $history "$EvidenceDirectory/$name-history-before.json"
   Copy-Item $fzFile "$EvidenceDirectory/$name-config-before.json"
   $power=Start-Process $pt.FullName -PassThru;Start-Sleep -Seconds 10
   if(!(Get-Process PowerToys.FancyZones -ErrorAction SilentlyContinue)){throw 'FancyZones not running for frozen trial'}
   Copy-Item $history "$EvidenceDirectory/$name-history-loaded.json"
   Copy-Item $fzFile "$EvidenceDirectory/$name-config-loaded.json"
   $recorderStartUtc=[DateTime]::UtcNow.ToString('o')
   $progress=NewCaptureProgressPath $EvidenceDirectory $name
   $recorderClock=[System.Diagnostics.Stopwatch]::StartNew()
   $recording=Start-Process $env:FFMPEG2380 -NoNewWindow -ArgumentList @('-y','-f','gdigrab','-framerate','10','-i','desktop','-t','30','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-stats_period','0.25','-progress',$progress,"$EvidenceDirectory/$name.mp4") -RedirectStandardOutput "$EvidenceDirectory/$name-record.log" -RedirectStandardError "$EvidenceDirectory/$name-record-error.log" -PassThru
   $readyDeadline=[DateTime]::UtcNow.AddSeconds(15)
   do {
    if($recording.HasExited){throw 'Recorder exited before application launch'}
    $readyBlock=ReadLiveCaptureProgress $progress $recording
    if($readyBlock){
     if($readyBlock.Groups[3].Value -eq 'end'){throw 'Recorder ended before application launch'}
     if([int]$readyBlock.Groups[1].Value -gt 0 -and [long]$readyBlock.Groups[2].Value -ge 0){break}
    }
    if([DateTime]::UtcNow -gt $readyDeadline){throw 'No first captured frame before application launch'}
    Start-Sleep -Milliseconds 100
   }while($true)
   if([long]$readyBlock.Groups[2].Value -gt 2000000){throw 'Recording lacks twenty-eight seconds of remaining coverage at launch'}
   if($recording.HasExited){throw 'Recorder exited immediately before application launch'}
   $recordReadyUtc=[DateTime]::UtcNow.ToString('o');$launchUtc=[DateTime]::UtcNow.ToString('o')
   $app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru;$launchClock=[System.Diagnostics.Stopwatch]::StartNew()
   @{case=$case.name;iteration=$iteration;pid=$app.Id;launchUtc=$launchUtc;recordStartUtc=$recorderStartUtc;firstCaptureObservedUtc=$recordReadyUtc;firstCaptureProgress=$readyBlock.Value;progressFile=$progress;recordingPid=$recording.Id}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-timing.json"
   foreach($seconds in @(0.5,1,3,10)){
    while($launchClock.Elapsed.TotalSeconds -lt $seconds){Start-Sleep -Milliseconds 50}
    if($recording.HasExited){throw 'Recorder exited before startup observation completed'}
    Snapshot "$name-$($seconds)s" $app
   }
   $state=Get-Content "$EvidenceDirectory/$name-10s-state.json" -Raw|ConvertFrom-Json
   if(!$state.validWindow){throw 'No valid app-owned window at observation deadline'}
   SaveProfile "$name-startup-after"
   Copy-Item $history "$EvidenceDirectory/$name-history-startup-after.json"
   if($recording.HasExited){throw 'Recorder exited before focus input'}
   @{focusInputUtc=[DateTime]::UtcNow.ToString('o');pid=$app.Id}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-focus-input.json"
   FocusLocalSend $app
   Snapshot "$name-focused" $app
   while($launchClock.Elapsed.TotalSeconds -lt 13){Start-Sleep -Milliseconds 50}
   if($recording.HasExited){throw 'Recorder exited before resize input'}
   $oldPid=$app.Id;$oldHandle=$app.MainWindowHandle
   $window=New-Object Desktop2861+Rect;[Desktop2861]::GetWindowRect($oldHandle,[ref]$window)|Out-Null
   @{resizeInputUtc=[DateTime]::UtcNow.ToString('o');pid=$oldPid;window=$oldHandle.ToInt64();frame=$window}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-resize-input.json"
   [Desktop2861]::SetCursorPos([int]$window.Right-2,[int]$window.Bottom-2)|Out-Null
   [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
   for($step=1;$step -le 10;$step++){[Desktop2861]::SetCursorPos([int]$window.Right-2-$step*5,[int]$window.Bottom-2-$step*3)|Out-Null;Start-Sleep -Milliseconds 30}
   [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
   Start-Sleep -Seconds 2;Snapshot "$name-same-pid-resize" $app
   $newWindow=New-Object Desktop2861+Rect;[Desktop2861]::GetWindowRect($app.MainWindowHandle,[ref]$newWindow)|Out-Null
   @{samePid=($app.Id -eq $oldPid);sameWindow=($app.MainWindowHandle -eq $oldHandle);dimensionsChanged=(($newWindow.right-$newWindow.left) -ne ($window.right-$window.left) -or ($newWindow.bottom-$newWindow.top) -ne ($window.bottom-$window.top));utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-resize-result.json"
   $resizeResult=Get-Content "$EvidenceDirectory/$name-resize-result.json" -Raw|ConvertFrom-Json
   @{interventionValid=($resizeResult.samePid -and $resizeResult.sameWindow -and $resizeResult.dimensionsChanged)}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-resize-validity.json"
   $lastObservedUtc=[DateTime]::UtcNow.ToString('o')
   $lastObservedProgress=[string](Get-Content $progress -Raw)
   SaveProfile "$name-resize-after"
   Copy-Item $history "$EvidenceDirectory/$name-history-after.json"
   if(!$recording.WaitForExit(30000)){throw 'Recorder did not finish normal duration'}
   if($recording.ExitCode -ne 0){throw 'Recording ended abnormally'}
   $recordingExitedUtc=[DateTime]::UtcNow.ToString('o')
   $ffprobe=Join-Path (Split-Path $env:FFMPEG2380) 'ffprobe.exe'
   & $ffprobe -v error -show_format -show_streams -of json "$EvidenceDirectory/$name.mp4" | Set-Content "$EvidenceDirectory/$name-recording.json"
   if($LASTEXITCODE -ne 0){throw 'Recording metadata cannot decode'}
   $video=Get-Content "$EvidenceDirectory/$name-recording.json" -Raw|ConvertFrom-Json
   if([double]$video.format.duration -lt 29 -or [int]$video.streams[0].nb_frames -lt 280){throw 'Recording duration/frame count is insufficient'}
   & $env:FFMPEG2380 -v error -i "$EvidenceDirectory/$name.mp4" -f null NUL 2> "$EvidenceDirectory/$name-decode.log"
   if($LASTEXITCODE -ne 0){throw 'Full recording decode failed'}
   @{lastObservedUtc=$lastObservedUtc;lastObservedProgress=$lastObservedProgress;recordingExitedUtc=$recordingExitedUtc;recordingDuration=[double]$video.format.duration;finalProgress=[string](Get-Content $progress -Raw);fullDecode=$true}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-coverage.json"
  } finally {
   [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero);[Input2380]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
   FinishOwnedRecorder $name $recording $recorderClock $progress $EvidenceDirectory
   if($app -and !$app.HasExited){Stop-Process -Id $app.Id -Force;$app.WaitForExit()}
   Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
  }
 }}
} finally {
 [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 if('Input2380' -as [type]){[Input2380]::keybd_event(0x10,0,2,[UIntPtr]::Zero)}
 if($recording -and !$recording.HasExited){FinishOwnedRecorder $name $recording $recorderClock $progress $EvidenceDirectory}
 if($app -and !$app.HasExited){Stop-Process -Id $app.Id -Force;$app.WaitForExit()}
 Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
 Stop-Transcript
}
