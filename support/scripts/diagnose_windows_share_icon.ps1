$ErrorActionPreference = 'Stop'
$evidence = New-Item -ItemType Directory -Force (Join-Path $PWD 'share-icon-evidence')
Start-Transcript (Join-Path $evidence 'transcript.txt')
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture | Format-List
whoami
query session
Get-Process explorer -ErrorAction SilentlyContinue | Select-Object Id, SessionId

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ShareIconInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@
function Find-Element([string] $name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $name
    [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}
function Click-Element($element) {
    if (-not $element) { throw 'UI element not found' }
    $r = $element.Current.BoundingRectangle
    [ShareIconInput]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) | Out-Null
    [ShareIconInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [ShareIconInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep 2
}
function Save-Desktop([string] $name) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path $evidence "$name.png"))
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $lines = foreach ($element in $elements) {
        try {
            $c = $element.Current
            '{0} | {1} | {2} | {3} | {4}' -f $c.Name, $c.AutomationId, $c.ControlType.ProgrammaticName, $c.ClassName, $c.BoundingRectangle
        } catch { }
    }
    $lines | Set-Content (Join-Path $evidence "$name-uia.txt")
}

Save-Desktop 'initial'
# Hosted Windows 11 images may still show the first-login privacy wizard.
$oobe = Find-Element 'Microsoft account'
if ($oobe -and $oobe.Current.ClassName -eq 'Shell_OOBEProxy') {
    # The wizard's XAML is absent from UIA on this runner image. Advance its
    # bottom-right Next/Accept button on the captured 1024x768 desktop.
    for ($i = 0; $i -lt 4; $i++) {
        [ShareIconInput]::SetCursorPos(867, 657) | Out-Null
        [ShareIconInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [ShareIconInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep 3
    }
}
$paging = Find-Element 'System Properties'
if ($paging) { Click-Element (Find-Element 'OK') }
Save-Desktop 'ready'
$installer = Join-Path $env:TEMP 'localsend-release.exe'
Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.exe' -OutFile $installer
Get-FileHash $installer
if ((Get-FileHash $installer).Hash -ne '122783E6ABB4B0A1F1603D896F46A03AEDA3004479EBD3175CAB4DDAC6B60919') { throw 'Unexpected release installer hash' }
$installDir = Join-Path $env:LOCALAPPDATA 'LocalSendShareIconTest'
$proc = Start-Process $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/DIR=`"$installDir`"", "/LOG=`"$(Join-Path $evidence 'install.log')`"") -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "Installer failed: $($proc.ExitCode)" }
for ($i = 0; $i -lt 30; $i++) {
    $package = Get-AppxPackage -Name LocalSend.App
    if ($package) { break }
    Start-Sleep 1
}
$package | Format-List *
if (-not $package) { throw 'Released installer did not register its share-target package' }
Get-ChildItem $installDir | Select-Object Name | Format-Table

$fixtureDir = New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'ShareIconFixture')
Set-Content (Join-Path $fixtureDir 'share-me.txt') 'LocalSend share icon regression fixture'
$shell = New-Object -ComObject Shell.Application
Start-Process explorer.exe -ArgumentList $fixtureDir.FullName
Start-Sleep 5
$item = $shell.NameSpace($fixtureDir.FullName).ParseName('share-me.txt')
$item.Verbs() | ForEach-Object { $_.Name } | Set-Content (Join-Path $evidence 'verbs.txt')
function Capture-Share([string] $phase) {
    $file = Find-Element 'share-me'
    if (-not $file) { $file = Find-Element 'share-me.txt' }
    Click-Element $file
    $file.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
    Start-Sleep 3
    Save-Desktop "$phase-context"
    $share = Find-Element 'Share with'
    if (-not $share) { $share = Find-Element 'Share' }
    Click-Element $share
    Start-Sleep 5
    Save-Desktop "$phase-share"
    $more = Find-Element 'More options'
    if (-not $more) { throw 'Share With submenu did not open' }
    Click-Element $more
    Start-Sleep 5
    Save-Desktop "$phase-more-options"
    $closeCondition = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::AutomationIdProperty), 'SharePickerCloseButtonTabStop'
    $close = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $closeCondition)
    Click-Element $close
}
Capture-Share 'baseline'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$unpack = Join-Path $env:TEMP 'LocalSendSharePackage'
[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $installDir 'localsend_msix_helper.msix'), $unpack)
Copy-Item (Join-Path $unpack 'Images') $installDir -Recurse -Force
Get-AppxPackage LocalSend.App | Remove-AppxPackage
Add-AppxPackage (Join-Path $installDir 'localsend_msix_helper.msix') -ExternalLocation $installDir
Start-Sleep 5
Capture-Share 'images-only'

Copy-Item (Join-Path $unpack 'resources.pri') $installDir -Force
Get-AppxPackage LocalSend.App | Remove-AppxPackage
Add-AppxPackage (Join-Path $installDir 'localsend_msix_helper.msix') -ExternalLocation $installDir
Start-Sleep 5
Capture-Share 'images-and-pri'
Stop-Transcript
