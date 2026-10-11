param([string]$ReleaseRoot,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/desktop.ps1" -ReleaseRoot $ReleaseRoot -EvidenceDirectory $EvidenceDirectory
Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture|ConvertTo-Json|Set-Content "$EvidenceDirectory/os.json"
Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,VideoModeDescription|ConvertTo-Json|Set-Content "$EvidenceDirectory/gpu.json"
@{image=$env:ImageOS;imageVersion=$env:ImageVersion;architecture=$env:PROCESSOR_ARCHITECTURE;screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString()}|ConvertTo-Json|Set-Content "$EvidenceDirectory/runner.json"
function Snapshot($name,$process) {
 $process.Refresh();$r=New-Object Desktop2861+Rect;$handle=[IntPtr]::Zero
 if(!$process.HasExited -and $process.MainWindowHandle){$handle=$process.MainWindowHandle}
 [Desktop2861]::GetClientRect($handle,[ref]$r)|Out-Null
 @{utc=[DateTime]::UtcNow.ToString('o');pid=$process.Id;hasExited=$process.HasExited;window=$handle.ToInt64();foreground=[Desktop2861]::GetForegroundWindow().ToInt64();client=@{width=$r.right;height=$r.bottom};dpi=[Desktop2861]::GetDpiForWindow($handle)}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-state.json"
 $bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
 $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height);$g=[System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size);$bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$bmp.Dispose()
 $scope=[System.Windows.Automation.TreeScope]::Children
 $root=[System.Windows.Automation.AutomationElement]::RootElement
 if($handle -ne [IntPtr]::Zero){$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle);$scope=[System.Windows.Automation.TreeScope]::Descendants}
 $elements=$root.FindAll($scope,[System.Windows.Automation.Condition]::TrueCondition)
 $elements|ForEach-Object{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;bounds=$_.Current.BoundingRectangle.ToString();pid=$_.Current.ProcessId;offscreen=$_.Current.IsOffscreen}}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-uia.json"
}
function FocusLocalSend($process) {
 Get-Process wsl,WindowsTerminal -ErrorAction SilentlyContinue|Stop-Process -Force
 [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
 $process.Refresh();if(!$process.MainWindowHandle){throw 'No LocalSend window to focus'}
 [Desktop2861]::SetForegroundWindow($process.MainWindowHandle)|Out-Null
 $window=[System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle).Current.BoundingRectangle
 [Desktop2861]::SetCursorPos([int]$window.Left+100,[int]$window.Top+15)|Out-Null
 [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 500
 if([Desktop2861]::GetForegroundWindow() -ne $process.MainWindowHandle){throw 'Real title-bar focus did not reach LocalSend'}
}
Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
$exe=Get-ChildItem $ReleaseRoot -Filter localsend_app.exe -Recurse|Select-Object -First 1
Get-FileHash $exe.FullName|ConvertTo-Json|Set-Content "$EvidenceDirectory/localsend-exe.json"
New-NetFirewallRule -DisplayName 'Bug2380 disposable LocalSend' -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any|Out-Null
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 15
FocusLocalSend $app
Start-Sleep -Seconds 2
Snapshot 'control-no-powertoys' $app
Stop-Process -Id $app.Id -Force
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
 $relative=$_.FullName.Substring($ptSettings.Length).TrimStart('\','/');$target=Join-Path "$EvidenceDirectory/powertoys-settings" $relative
 New-Item -ItemType Directory -Force (Split-Path $target)|Out-Null;Copy-Item $_.FullName $target
}
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 15;Snapshot 'powertoys-default-localsend' $app
Stop-Process -Id $app.Id -Force
Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
$rootFile="$ptSettings/settings.json";$rootConfig=Get-Content $rootFile -Raw|ConvertFrom-Json
foreach($property in $rootConfig.enabled.PSObject.Properties){$property.Value=($property.Name -eq 'FancyZones')}
$rootConfig|ConvertTo-Json -Depth 20|Set-Content -Encoding UTF8 $rootFile
$fzFile="$ptSettings/FancyZones/settings.json";$fzConfig=Get-Content $fzFile -Raw|ConvertFrom-Json
foreach($key in @('fancyzones_appLastZone_moveWindows','fancyzones_overrideSnapHotkeys','fancyzones_shiftDrag')){
 $fzConfig.properties|Add-Member -MemberType NoteProperty -Name $key -Value @{value=$true} -Force
}
$fzConfig|ConvertTo-Json -Depth 20|Set-Content -Encoding UTF8 $fzFile
Copy-Item $fzFile "$EvidenceDirectory/restore-config.json"
$power=Start-Process $pt.FullName -PassThru;Start-Sleep -Seconds 10
Get-Process '*PowerToys*'|Select-Object Name,Id,Path|ConvertTo-Json|Set-Content "$EvidenceDirectory/zone-processes.json"
if(!(Get-Process PowerToys.FancyZones -ErrorAction SilentlyContinue)){throw 'FancyZones module not running'}
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class Input2380 {
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
}
"@
function RealZoneKey {
 [Input2380]::keybd_event(0x5b,0,0,[UIntPtr]::Zero);[Input2380]::keybd_event(0x25,0,0,[UIntPtr]::Zero)
 [Input2380]::keybd_event(0x25,0,2,[UIntPtr]::Zero);[Input2380]::keybd_event(0x5b,0,2,[UIntPtr]::Zero)
}
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru;Start-Sleep -Seconds 15
FocusLocalSend $app
Start-Sleep -Seconds 1;Snapshot 'restore-enabled-before-zone' $app
if([Desktop2861]::GetForegroundWindow() -ne $app.MainWindowHandle){throw 'LocalSend not foreground before actual zone key'}
RealZoneKey;Start-Sleep -Seconds 3;Snapshot 'actual-win-left-zone' $app
$history="$ptSettings/FancyZones/app-zone-history.json"
if(!(Test-Path $history) -or !((Get-Content $history -Raw|ConvertFrom-Json).'app-zone-history'|Where-Object{$_.'app-path' -ieq $exe.FullName})){
 # Use the normal Shift-drag workflow when this desktop's Win+arrow override does not record a zone.
 FocusLocalSend $app
 $window=[System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle).Current.BoundingRectangle
 $startX=[int]$window.Left+100;$startY=[int]$window.Top+15
 [Desktop2861]::SetCursorPos($startX,$startY)|Out-Null;[Input2380]::keybd_event(0x10,0,0,[UIntPtr]::Zero)
 [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 for($step=1;$step -le 20;$step++){[Desktop2861]::SetCursorPos([int]($startX+(300-$startX)*$step/20),[int]($startY+(350-$startY)*$step/20))|Out-Null;Start-Sleep -Milliseconds 40}
 Snapshot 'actual-shift-drag-highlight' $app
 [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero);[Input2380]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
 Start-Sleep -Seconds 3;Snapshot 'actual-shift-drag-zone' $app
}
if(!(Test-Path $history)){throw 'No actual FancyZones history recorded'}
Copy-Item $history "$EvidenceDirectory/actual-zone-history.json"
$historyData=Get-Content $history -Raw|ConvertFrom-Json
if(!($historyData.'app-zone-history'|Where-Object{$_.'app-path' -ieq $exe.FullName})){throw 'LocalSend not found in genuine zone history'}
Get-ChildItem "$ptSettings/FancyZones" -File -Filter '*layouts.json'|Copy-Item -Destination $EvidenceDirectory
Stop-Process -Id $app.Id -Force
foreach($iteration in 1..3){
 $app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
 Start-Sleep -Seconds 1;Snapshot "zone-relaunch-$iteration-1s" $app
 Start-Sleep -Seconds 9;Snapshot "zone-relaunch-$iteration-10s" $app
 $app.Refresh();[Desktop2861]::SetForegroundWindow($app.MainWindowHandle)|Out-Null
 # Real mouse corner resize in the same process; this is a causal diagnostic after retaining startup evidence.
 $window=[System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle).Current.BoundingRectangle
 [Desktop2861]::SetCursorPos([int]$window.Right-2,[int]$window.Bottom-2)|Out-Null
 [Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 for($step=1;$step -le 10;$step++){[Desktop2861]::SetCursorPos([int]$window.Right-2-$step*5,[int]$window.Bottom-2-$step*3)|Out-Null;Start-Sleep -Milliseconds 30}
 [Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Seconds 2;Snapshot "zone-relaunch-$iteration-same-pid-user-resize" $app
 Stop-Process -Id $app.Id -Force
}
Stop-Transcript
