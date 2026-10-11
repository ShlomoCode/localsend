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
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect1549 rect);
}
public struct Rect1549 { public int Left, Top, Right, Bottom; }
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
$fixedManifest = Join-Path $env:RUNNER_TEMP 'manifest151-fixed-switch'
New-Item -ItemType Directory -Force $fixedManifest | Out-Null
Copy-Item "$manifest/*" $fixedManifest
$installerText = Get-Content "$fixedManifest/LocalSend.LocalSend.installer.yaml" -Raw
$installerText = [regex]::Replace($installerText, '(?m)^(    Custom: [^\r\n]+)', '$1' + "`n    Upgrade: /FORCECLOSEAPPLICATIONS")
[IO.File]::WriteAllText("$fixedManifest/LocalSend.LocalSend.installer.yaml", $installerText, (New-Object Text.UTF8Encoding $false))
Copy-Item "$fixedManifest/LocalSend.LocalSend.installer.yaml" "$ev/fixed-switch-installer.yaml"
$installManifest = Join-Path $env:RUNNER_TEMP 'manifest151-install'
$installFixedManifest = Join-Path $env:RUNNER_TEMP 'manifest151-install-force'
New-Item -ItemType Directory -Force $installManifest,$installFixedManifest | Out-Null
Copy-Item "$manifest/*" $installManifest
Copy-Item "$fixedManifest/*" $installFixedManifest
foreach ($dir in @($installManifest,$installFixedManifest)) {
 $text = (Get-Content "$dir/LocalSend.LocalSend.installer.yaml" -Raw) -replace 'UpgradeBehavior: uninstallPrevious[^\r\n]*','UpgradeBehavior: install'
 [IO.File]::WriteAllText("$dir/LocalSend.LocalSend.installer.yaml",$text,(New-Object Text.UTF8Encoding $false))
}
$currentManifest = Join-Path $env:RUNNER_TEMP 'manifest182-fixed'
$currentNegativeManifest = Join-Path $env:RUNNER_TEMP 'manifest182-no-force'
New-Item -ItemType Directory -Force $currentManifest,$currentNegativeManifest | Out-Null
foreach ($file in @('LocalSend.LocalSend.yaml','LocalSend.LocalSend.installer.yaml','LocalSend.LocalSend.locale.en-US.yaml')) {
 Invoke-WebRequest "https://raw.githubusercontent.com/microsoft/winget-pkgs/ce0af1b598526303ab464bb648000fab4479b392/manifests/l/LocalSend/LocalSend/1.18.2/$file" -OutFile "$currentManifest/$file"
}
Copy-Item "$currentManifest/*" $currentNegativeManifest
$text = (Get-Content "$currentNegativeManifest/LocalSend.LocalSend.installer.yaml" -Raw) -replace '(?m)^    Upgrade: /FORCECLOSEAPPLICATIONS\r?\n',''
[IO.File]::WriteAllText("$currentNegativeManifest/LocalSend.LocalSend.installer.yaml",$text,(New-Object Text.UTF8Encoding $false))
foreach ($variant in @(@('install-no-force',$installManifest),@('install-force',$installFixedManifest),@('current-fixed',$currentManifest),@('current-no-force',$currentNegativeManifest))) {
 New-Item -ItemType Directory -Force "$ev/$($variant[0])-manifest" | Out-Null
 Copy-Item "$($variant[1])/*" "$ev/$($variant[0])-manifest"
}
& $wgPath settings --enable LocalManifestFiles 2>&1 | Out-File "$ev/manifest-setting.txt"
& $wgPath validate --manifest $manifest 2>&1 | Out-File "$ev/original-manifest-validation.txt"
if ($LASTEXITCODE -ne 0) { throw 'Original Microsoft manifest validation failed' }
& $wgPath validate --manifest $fixedManifest 2>&1 | Out-File "$ev/fixed-manifest-validation.txt"
if ($LASTEXITCODE -ne 0) { throw 'Single-switch manifest validation failed' }
foreach ($dir in @($installManifest,$installFixedManifest,$currentManifest,$currentNegativeManifest)) {
 & $wgPath validate --manifest $dir 2>&1 | Out-File "$ev/validate-$([IO.Path]::GetFileName($dir)).txt"
 if ($LASTEXITCODE -ne 0) { throw "Manifest validation failed: $dir" }
}
function Snapshot($name) {
 Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object Id, Path, StartTime, Responding, MainWindowHandle, MainWindowTitle | ConvertTo-Json | Set-Content "$ev/$name-process.json"
 $registry = foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
  Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'LocalSend' } | Select-Object PSPath, DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString
 }
 @($registry) | ConvertTo-Json | Set-Content "$ev/$name-registry.json"
 @{ Registry = @($registry); Process = @(Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object Id, MainWindowHandle); SampleTime = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Depth 4 | Set-Content "$ev/$name-state.json"
 $profilePath = "$env:APPDATA/LocalSend/settings.json"
 if (Test-Path $profilePath) {
  $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
  @{ Path = $profilePath; Exists = $true; MinimizeToTray = $profile.'flutter.ls_minimize_to_tray' } | ConvertTo-Json | Set-Content "$ev/$name-profile-state.json"
 }
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
function Upgrade($name,$route,$running,$tray=$false,$hidden=$false,$target='1.15.1') {
 ResetBaseline $name
 if ($running) {
  $app = Start-Process "$env:ProgramFiles/LocalSend/localsend_app.exe" -PassThru
  Start-Sleep 15
  $app.Refresh()
  if ($app.HasExited -or $app.MainWindowHandle -eq 0) { throw 'Baseline app failed to create its real window' }
  if ($tray) {
   [Input1549]::SetForegroundWindow($app.MainWindowHandle) | Out-Null
   $rect = New-Object Rect1549
   [Input1549]::GetWindowRect($app.MainWindowHandle, [ref]$rect) | Out-Null
   if ($rect.Right-$rect.Left -ne 400 -or $rect.Bottom-$rect.Top -ne 500) { throw 'Tray UI probe geometry changed' }
   [Input1549]::SetCursorPos($rect.Right-64, $rect.Bottom-44) | Out-Null
   [Input1549]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [Input1549]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
   Start-Sleep 2
   Screenshot "$name-setting-off"
   # Switch coordinates were observed in run38145897069, not inferred from code.
   [Input1549]::SetCursorPos($rect.Right-117, $rect.Bottom-98) | Out-Null
   [Input1549]::mouse_event(2,0,0,0,[UIntPtr]::Zero); [Input1549]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
   Start-Sleep 2
   $prefs = Get-Content "$env:APPDATA/LocalSend/settings.json" -Raw | ConvertFrom-Json
   @{ MinimizeToTray = $prefs.'flutter.ls_minimize_to_tray'; ProfilePath = "$env:APPDATA/LocalSend/settings.json"; Input = 'Settings then observed switch'; SwitchX = $rect.Right-117; SwitchY = $rect.Bottom-98 } | ConvertTo-Json | Set-Content "$ev/$name-setting.json"
   if ($prefs.'flutter.ls_minimize_to_tray' -ne $true) { throw 'Real UI action did not enable tray preference' }
   [Input1549]::SetCursorPos($rect.Left+220, $rect.Top+280) | Out-Null
   [Input1549]::mouse_event(2048,0,0,4294967176,[UIntPtr]::Zero)
   Start-Sleep 1
   Screenshot "$name-setting-on"
   if ($hidden) {
    $app.CloseMainWindow() | Out-Null
    Start-Sleep 2
    $app.Refresh()
    if ($app.HasExited) { throw 'Normal close exited instead of tray hiding' }
   }
  }
 }
 Snapshot "$name-before"
 if ($route -eq 'source') { $args = @('upgrade','--id','LocalSend.LocalSend','--exact','--version',$target,'--source','winget','--scope','machine','--architecture','x64','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') }
 else {
  $selectedManifest = switch ($route) {
   'local-manifest-fixed' { $fixedManifest }
   'install-no-force' { $installManifest }
   'install-force' { $installFixedManifest }
   'current-fixed' { $currentManifest }
   'current-no-force' { $currentNegativeManifest }
   default { $manifest }
  }
  $args = @('upgrade','--manifest',"`"$selectedManifest`"",'--scope','machine','--architecture','x64','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
 }
 $start = Get-Date
 $up = Start-Process $wgPath -ArgumentList $args -PassThru -RedirectStandardOutput "$ev/$name-winget-upgrade.txt" -RedirectStandardError "$ev/$name-winget-error.txt"
 $retainedHandle = $up.Handle
 $timeline = @()
 while (-not $up.HasExited) {
  $timeline += @{ Time = (Get-Date).ToUniversalTime().ToString('o'); Processes = @(Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object Id, MainWindowHandle, MainWindowTitle, Responding) }
  if (((Get-Date)-$start).TotalSeconds -gt 180) { throw 'Upgrade exceeded 180-second evidence deadline' }
  Start-Sleep 1; $up.Refresh()
 }
 $up.WaitForExit()
 $timeline | ConvertTo-Json -Depth 5 | Set-Content "$ev/$name-timeline.json"
 @{ Name = $name; Route = $route; Running = $running; Tray = $tray; Hidden = $hidden; Arguments = $args; ExitCode = $up.ExitCode; DurationSeconds = ((Get-Date)-$start).TotalSeconds } | ConvertTo-Json | Set-Content "$ev/$name-result.json"
 Snapshot "$name-after"
 $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{00809252-FEC6-448E-83B4-E7F55AE7E47D}_is1' -ErrorAction SilentlyContinue
 $installedVersion = if (Test-Path "$env:ProgramFiles/LocalSend/localsend_app.exe") { (Get-Item "$env:ProgramFiles/LocalSend/localsend_app.exe").VersionInfo.ProductVersion } else { $null }
 $completed = $up.ExitCode -eq 0 -and $reg.DisplayVersion -eq $target -and $installedVersion -like "$target*"
 $expectedSuccess = $route -in @('install-force','current-fixed')
 @{ ExpectedSuccess = $expectedSuccess; Completed = $completed; Registration = $reg.DisplayVersion; FileVersion = $installedVersion; ProcessAlive = [bool](Get-Process localsend_app -ErrorAction SilentlyContinue) } | ConvertTo-Json | Set-Content "$ev/$name-verdict.json"
}
try {
 $route = if ($source151 -eq 0) { 'source' } else { 'local-manifest' }
 Upgrade 'historical-install-no-force' 'install-no-force' $true $true
 Upgrade 'historical-install-force' 'install-force' $true $true
 Upgrade 'current-exact-no-force' 'current-no-force' $true $true $false '1.18.2'
 Upgrade 'current-exact-fixed' 'current-fixed' $true $true $false '1.18.2'
} finally {
 foreach ($logRoot in @("$env:LOCALAPPDATA/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir", "$env:LOCALAPPDATA/Microsoft/WinGet/DiagOutputDir")) {
  if (Test-Path $logRoot) { Copy-Item "$logRoot/*" $ev -Force -ErrorAction Continue }
 }
 Stop-Transcript
}
