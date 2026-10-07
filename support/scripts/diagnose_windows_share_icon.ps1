$ErrorActionPreference = 'Stop'
$evidence = New-Item -ItemType Directory -Force (Join-Path $PWD 'share-icon-evidence')
Start-Transcript (Join-Path $evidence 'transcript.txt')
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture | Format-List
whoami
query session
Get-Process explorer -ErrorAction SilentlyContinue | Select-Object Id, SessionId

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
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
$item.InvokeVerb('Windows.ModernShare')
Start-Sleep 10
Save-Desktop 'baseline-share'
Stop-Transcript
