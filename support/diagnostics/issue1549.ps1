$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ev = Join-Path (Get-Location) 'evidence/cloud'
New-Item -ItemType Directory -Force $ev | Out-Null
Start-Transcript -Path "$ev/transcript.txt"
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture | ConvertTo-Json | Set-Content "$ev/os.json"
@{ User = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); ImageVersion = $env:ImageVersion; RunnerArch = $env:RUNNER_ARCH; Commit = $env:GITHUB_SHA } | ConvertTo-Json | Set-Content "$ev/environment.json"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Input1549 {
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
}
'@
function Screenshot($name) {
 $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
 $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
 $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
 $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
 $bitmap.Save("$ev/$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
 $graphics.Dispose(); $bitmap.Dispose()
}
Screenshot 'desktop-initial'
$desktop = [System.Windows.Automation.AutomationElement]::RootElement
$wizard = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), 'Shell_OOBEProxy'
for ($i = 0; $i -lt 4; $i++) {
 if (-not $desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $wizard)) { break }
 $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
 if ($screen.Width -ne 1024 -or $screen.Height -ne 768) { throw 'Unexpected OOBE dimensions' }
 [Input1549]::SetCursorPos(867,657) | Out-Null
 [Input1549]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [Input1549]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep 3
}
if ($desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $wizard)) { throw 'OOBE remained' }
Screenshot 'desktop-ready'
$wg = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $wg) {
 $package = Get-AppxPackage Microsoft.DesktopAppInstaller
 if ($package) { $wgPath = Join-Path $package.InstallLocation 'winget.exe' }
 if (-not $wgPath -or -not (Test-Path $wgPath)) { throw 'Winget is unavailable on this runner' }
} else { $wgPath = $wg.Source }
& $wgPath --info 2>&1 | Out-File "$ev/winget-info.txt"
& $wgPath source list 2>&1 | Out-File "$ev/winget-sources.txt"
& $wgPath show --id LocalSend.LocalSend --version 1.15.1 --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-File "$ev/source-151.txt"
$source151 = $LASTEXITCODE
& $wgPath show --id LocalSend.LocalSend --version 1.15.0 --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-File "$ev/source-150.txt"
$source150 = $LASTEXITCODE
@{ Source151Exit = $source151; Source150Exit = $source150 } | ConvertTo-Json | Set-Content "$ev/source-availability.json"
foreach ($version in @('1.15.0','1.15.1')) {
 $url = "https://github.com/localsend/localsend/releases/download/v$version/LocalSend-$version-windows-x86-64.exe"
 $path = Join-Path $env:RUNNER_TEMP "LocalSend-$version.exe"
 Invoke-WebRequest $url -OutFile $path
 $hash = (Get-FileHash $path).Hash
 if ($version -eq '1.15.1' -and $hash -ne '771651269F7D31520FB956EF2C0729EB2FF99395BBA8353B786DAF3D44936D21') { throw 'Wrong 1.15.1 installer' }
 $sig = Get-AuthenticodeSignature $path
 @{ Version = $version; Url = $url; Sha256 = $hash; SignatureStatus = [string]$sig.Status; Signer = [string]$sig.SignerCertificate.Subject } | ConvertTo-Json | Set-Content "$ev/artifact-$version.json"
}
$manifest = Join-Path $env:RUNNER_TEMP 'manifest151'
New-Item -ItemType Directory -Force $manifest | Out-Null
foreach ($file in @('LocalSend.LocalSend.yaml','LocalSend.LocalSend.installer.yaml','LocalSend.LocalSend.locale.en-US.yaml')) {
 Invoke-WebRequest "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/l/LocalSend/LocalSend/1.15.1/$file" -OutFile "$manifest/$file"
}
Copy-Item "$manifest/*" "$ev/" -Force
& $wgPath settings --enable LocalManifestFiles 2>&1 | Out-File "$ev/manifest-setting.txt"
function Snapshot($name) {
 Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object Id, Path, StartTime, Responding, MainWindowHandle, MainWindowTitle | ConvertTo-Json | Set-Content "$ev/$name-process.json"
 $registry = foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
  Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'LocalSend' } | Select-Object PSPath, DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString
 }
 @($registry) | ConvertTo-Json | Set-Content "$ev/$name-registry.json"
 & $wgPath list --id LocalSend.LocalSend --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-File "$ev/$name-winget-list.txt"
 Get-ChildItem "$env:ProgramFiles/LocalSend" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime | ConvertTo-Json | Set-Content "$ev/$name-files.json"
 if (Test-Path "$env:ProgramFiles/LocalSend/localsend_app.exe") {
  (Get-Item "$env:ProgramFiles/LocalSend/localsend_app.exe").VersionInfo | Select-Object FileVersion, ProductVersion | ConvertTo-Json | Set-Content "$ev/$name-version.json"
 }
 Screenshot $name
}
function ResetBaseline($name) {
 Get-Process localsend_app -ErrorAction SilentlyContinue | Stop-Process -Force
 if (Test-Path "$env:ProgramFiles/LocalSend/unins000.exe") {
  Start-Process "$env:ProgramFiles/LocalSend/unins000.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait
 }
 foreach ($profile in @("$env:APPDATA/LocalSend","$env:APPDATA/org.localsend","$env:LOCALAPPDATA/LocalSend")) {
  if (Test-Path $profile) { Remove-Item $profile -Recurse -Force }
 }
 $setup = Start-Process "$env:RUNNER_TEMP/LocalSend-1.15.0.exe" -ArgumentList @('/SP-','/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/ALLUSERS',"/LOG=`"$ev/$name-install150.log`"") -Wait -PassThru
 if ($setup.ExitCode -ne 0) { throw "Baseline installation failed: $($setup.ExitCode)" }
 Snapshot "$name-baseline"
}
function Upgrade($name,$route,$running) {
 ResetBaseline $name
 if ($running) {
  $app = Start-Process "$env:ProgramFiles/LocalSend/localsend_app.exe" -PassThru
  Start-Sleep 15
  $app.Refresh()
  if ($app.HasExited -or $app.MainWindowHandle -eq 0) { throw 'Baseline app failed to create its real window' }
 }
 Snapshot "$name-before"
 if ($route -eq 'source') { $args = @('upgrade','--id','LocalSend.LocalSend','--exact','--version','1.15.1','--source','winget','--scope','machine','--architecture','x64','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') }
 else { $args = @('upgrade','--manifest',"`"$manifest`"",'--scope','machine','--architecture','x64','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') }
 $start = Get-Date
 $up = Start-Process $wgPath -ArgumentList $args -PassThru -RedirectStandardOutput "$ev/$name-winget-upgrade.txt" -RedirectStandardError "$ev/$name-winget-error.txt"
 $timeline = @()
 while (-not $up.HasExited) {
  $timeline += @{ Time = (Get-Date).ToUniversalTime().ToString('o'); Processes = @(Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object Id, MainWindowHandle, MainWindowTitle, Responding) }
  if (((Get-Date)-$start).TotalSeconds -gt 180) { throw 'Upgrade exceeded 180-second evidence deadline' }
  Start-Sleep 1; $up.Refresh()
 }
 $up.WaitForExit()
 $timeline | ConvertTo-Json -Depth 5 | Set-Content "$ev/$name-timeline.json"
 @{ Name = $name; Route = $route; Running = $running; Arguments = $args; ExitCode = $up.ExitCode; DurationSeconds = ((Get-Date)-$start).TotalSeconds } | ConvertTo-Json | Set-Content "$ev/$name-result.json"
 Snapshot "$name-after"
}
try {
 $route = if ($source151 -eq 0) { 'source' } else { 'local-manifest' }
 Upgrade 'exited-control' $route $false
 Upgrade 'running-default-1' $route $true
 Upgrade 'running-default-2' $route $true
} finally {
 foreach ($logRoot in @("$env:LOCALAPPDATA/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir", "$env:LOCALAPPDATA/Microsoft/WinGet/DiagOutputDir")) {
  if (Test-Path $logRoot) { Copy-Item "$logRoot/*" $ev -Force -ErrorAction Continue }
 }
 Stop-Transcript
}
