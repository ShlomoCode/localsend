param(
    [Parameter(Mandatory = $true)] [string] $InstallerPath,
    [string] $EvidenceDirectory = (Join-Path $PWD 'share-icon-evidence')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
. (Join-Path $PSScriptRoot 'share_icon_assertions.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LocalSendShareInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
}
'@

$EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$result = [ordered]@{
    Given = 'LocalSend installed and registered as a Windows share target; a real text file is selected in File Explorer'
    When = 'Open Share with, inspect More options, select LocalSend once, then reopen Share with'
    Then = 'The LocalSend logo is rendered in the picker and the recent-target submenu'
    Passed = $false
    Assertions = @()
    Error = $null
}

function Find-VisibleElement {
    param(
        [Parameter(Mandatory = $true)] [System.Windows.Automation.AutomationElement] $Root,
        [Parameter(Mandatory = $true)] [string[]] $Names,
        [Parameter(Mandatory = $true)] [System.Windows.Automation.ControlType[]] $Types,
        [string] $ClassName
    )
    foreach ($name in $Names) {
        foreach ($type in $Types) {
            $conditions = @(
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $name),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)
            )
            if ($ClassName) {
                $conditions += [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, $ClassName)
            }
            $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]] $conditions)
            $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($element) {
                $bounds = $element.Current.BoundingRectangle
                if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) { return $element }
            }
        }
    }
    return $null
}

function Wait-VisibleElement {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string[]] $Names,
        [System.Windows.Automation.ControlType[]] $Types,
        [string] $ClassName,
        [int] $TimeoutSeconds = 20
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $element = Find-VisibleElement -Root $Root -Names $Names -Types $Types -ClassName $ClassName
        if ($element) { return $element }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible UI element not found: $($Names -join ' / ') [$($Types.ProgrammaticName -join ', ')]"
}

function Click-Element {
    param([System.Windows.Automation.AutomationElement] $Element)
    $bounds = $Element.Current.BoundingRectangle
    $x = [int][Math]::Round($bounds.X + $bounds.Width / 2)
    $y = [int][Math]::Round($bounds.Y + $bounds.Height / 2)
    if (-not [LocalSendShareInput]::SetCursorPos($x, $y)) { throw "Cannot move pointer to $x,$y" }
    [LocalSendShareInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [LocalSendShareInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Save-Screenshot {
    param([string] $Path)
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose() }
    return $bitmap
}

function Get-CaptureBounds {
    param($Element)
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bounds = $Element.Current.BoundingRectangle
    return [System.Windows.Rect]::new($bounds.X - $screen.X, $bounds.Y - $screen.Y, $bounds.Width, $bounds.Height)
}

function Save-RelevantUiTree {
    param([string] $Name, [System.Windows.Automation.AutomationElement] $Root)
    $conditions = [System.Windows.Automation.OrCondition]::new([System.Windows.Automation.Condition[]] @(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    ))
    $elements = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $conditions)
    $lines = foreach ($element in $elements) {
        try {
            $current = $element.Current
            if (-not $current.IsOffscreen -and $current.BoundingRectangle.Width -gt 0) {
                '{0} | {1} | {2} | {3}' -f $current.Name, $current.ControlType.ProgrammaticName, $current.ClassName, $current.BoundingRectangle
            }
        } catch { }
    }
    $lines | Set-Content (Join-Path $EvidenceDirectory "$Name-uia.txt")
}

function Assert-Surface {
    param([string] $Surface, $Element)
    $base = $Surface.ToLowerInvariant()
    $screenshotPath = Join-Path $EvidenceDirectory "$base.png"
    $cropPath = Join-Path $EvidenceDirectory "$base-icon.png"
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    do {
        $bitmap = Save-Screenshot $screenshotPath
        try {
            $score = Assert-LocalSendShareIcon -Screenshot $bitmap -TargetBounds (Get-CaptureBounds $Element) -Surface $Surface -CropPath $cropPath
            return [pscustomobject]@{ Surface = $Surface; Passed = $true; Score = $score.Score; Error = $null; Screenshot = $screenshotPath; CropPath = $cropPath }
        } catch {
            $message = $_.Exception.Message
            if ($message -notmatch 'icon not rendered \(score ([0-9.]+) <') { throw }
            $lastScore = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        } finally { $bitmap.Dispose() }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::UtcNow -lt $deadline)
    return [pscustomobject]@{ Surface = $Surface; Passed = $false; Score = $lastScore; Error = 'icon not rendered'; Screenshot = $screenshotPath; CropPath = $cropPath }
}

function Open-ExplorerShareMenu {
    param([string] $FolderPath)
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $window = Wait-VisibleElement -Root $desktop -Names @('ShareIconFixture - File Explorer') -Types @([System.Windows.Automation.ControlType]::Window)
    $handle = [IntPtr] $window.Current.NativeWindowHandle
    [LocalSendShareInput]::ShowWindow($handle, 9) | Out-Null
    if (-not [LocalSendShareInput]::SetForegroundWindow($handle)) { throw 'Could not foreground File Explorer' }
    $file = Wait-VisibleElement -Root $window -Names @('share-me', 'share-me.txt') -Types @(
        [System.Windows.Automation.ControlType]::ListItem,
        [System.Windows.Automation.ControlType]::DataItem
    )
    Click-Element $file
    $file.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
    $share = Wait-VisibleElement -Root $desktop -Names @('Share with', 'Share') -Types @([System.Windows.Automation.ControlType]::MenuItem)
    Click-Element $share
    return $desktop
}

try {
    $installer = (Resolve-Path $InstallerPath).Path
    $installDir = Join-Path $env:LOCALAPPDATA 'LocalSendShareIconE2E'
    Stop-Process -Name localsend_app -Force -ErrorAction SilentlyContinue
    Get-AppxPackage -Name LocalSend.App | Remove-AppxPackage -ErrorAction Stop
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    $installLog = Join-Path $EvidenceDirectory 'install.log'
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/DIR=`"$installDir`"", "/LOG=`"$installLog`"")
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode)" }
    if (-not (Test-Path (Join-Path $installDir 'localsend_app.exe'))) { throw 'Installed LocalSend executable missing' }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $package = Get-AppxPackage -Name LocalSend.App
        if ($package) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $package) { throw 'Installer did not register the LocalSend share-target package' }

    # Force Explorer to reload shell extension/icon state after installation.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Process explorer.exe
    $fixtureDir = Join-Path $env:TEMP 'ShareIconFixture'
    New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
    Set-Content -Path (Join-Path $fixtureDir 'share-me.txt') -Value 'LocalSend share icon regression fixture'
    Start-Process explorer.exe -ArgumentList $fixtureDir
    $desktop = Open-ExplorerShareMenu $fixtureDir
    $more = Wait-VisibleElement -Root $desktop -Names @('More options') -Types @([System.Windows.Automation.ControlType]::MenuItem)
    Click-Element $more
    $pickerTarget = Wait-VisibleElement -Root $desktop -Names @('LocalSend') -Types @(
        [System.Windows.Automation.ControlType]::ListItem,
        [System.Windows.Automation.ControlType]::DataItem
    ) -ClassName 'GridViewItem'
    Save-RelevantUiTree 'dialog' $desktop
    $result.Assertions += (Assert-Surface Dialog $pickerTarget)

    # Selecting the target once puts it in Explorer's recent Share with submenu.
    Click-Element $pickerTarget
    $appDeadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $app = Get-Process -Name localsend_app -ErrorAction SilentlyContinue
        if ($app) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $appDeadline)
    Stop-Process -Name localsend_app -Force -ErrorAction SilentlyContinue
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
    $desktop = Open-ExplorerShareMenu $fixtureDir
    $recentTarget = Wait-VisibleElement -Root $desktop -Names @('LocalSend') -Types @([System.Windows.Automation.ControlType]::MenuItem)
    Save-RelevantUiTree 'menu' $desktop
    $result.Assertions += (Assert-Surface Menu $recentTarget)
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
    $result.Passed = @($result.Assertions | Where-Object { -not $_.Passed }).Count -eq 0
} catch {
    $result.Error = $_.Exception.Message
    Write-Error $result.Error -ErrorAction Continue
} finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $EvidenceDirectory 'result.json')
}

if (-not $result.Passed) { exit 1 }
