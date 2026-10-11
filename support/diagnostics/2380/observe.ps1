param([string]$ReleaseRoot,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/desktop.ps1" -ReleaseRoot $ReleaseRoot -EvidenceDirectory $EvidenceDirectory
Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture|ConvertTo-Json|Set-Content "$EvidenceDirectory/os.json"
Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,VideoModeDescription|ConvertTo-Json|Set-Content "$EvidenceDirectory/gpu.json"
@{image=$env:ImageOS;imageVersion=$env:ImageVersion;architecture=$env:PROCESSOR_ARCHITECTURE;screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString()}|ConvertTo-Json|Set-Content "$EvidenceDirectory/runner.json"
function Snapshot($name,$process) {
 $bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
 $bmp=New-Object System.Drawing.Bitmap($bounds.Width,$bounds.Height);$g=[System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen($bounds.X,$bounds.Y,0,0,$bmp.Size);$bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$bmp.Dispose()
 $elements=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 $elements|ForEach-Object{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;bounds=$_.Current.BoundingRectangle.ToString();pid=$_.Current.ProcessId;offscreen=$_.Current.IsOffscreen}}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-uia.json"
 $process.Refresh();$r=New-Object Desktop2861+Rect
 [Desktop2861]::GetClientRect($process.MainWindowHandle,[ref]$r)|Out-Null
 @{utc=[DateTime]::UtcNow.ToString('o');pid=$process.Id;window=$process.MainWindowHandle.ToInt64();foreground=[Desktop2861]::GetForegroundWindow().ToInt64();client=@{width=$r.right;height=$r.bottom};dpi=[Desktop2861]::GetDpiForWindow($process.MainWindowHandle)}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-state.json"
}
Get-Process '*PowerToys*' -ErrorAction SilentlyContinue|Stop-Process -Force
$exe=Get-ChildItem $ReleaseRoot -Filter localsend_app.exe -Recurse|Select-Object -First 1
Get-FileHash $exe.FullName|ConvertTo-Json|Set-Content "$EvidenceDirectory/localsend-exe.json"
New-NetFirewallRule -DisplayName 'Bug2380 disposable LocalSend' -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any|Out-Null
$app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
Start-Sleep -Seconds 15
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
Stop-Transcript
