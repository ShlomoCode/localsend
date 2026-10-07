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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
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
    $searchRoots = @($Root)
    if ($Root.Current.ClassName -eq '#32769') {
        # Menus and the Share picker are separate top-level UIA windows. Search
        # each window rather than asking the desktop provider for all descendants.
        $searchRoots = @()
        $topLevels = $Root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($topLevel in $topLevels) {
            try {
                $current = $topLevel.Current
                if ($current.BoundingRectangle.Width -gt 0 -and $current.BoundingRectangle.Height -gt 0 -and
                    $current.ClassName -ne 'Progman' -and $current.ClassName -ne 'Shell_TrayWnd') {
                    $searchRoots += $topLevel
                }
            } catch { }
        }
    }
    foreach ($name in $Names) {
        foreach ($type in $Types) {
            $conditions = @(
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $name),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
            )
            if ($ClassName) {
                $conditions += [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, $ClassName)
            }
            $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]] $conditions)
            foreach ($searchRoot in $searchRoots) {
                try {
                    $element = $searchRoot.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $condition)
                    if ($element) {
                        $bounds = $element.Current.BoundingRectangle
                        if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) { return $element }
                    }
                } catch [System.TimeoutException], [System.Runtime.InteropServices.COMException] { }
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
        try {
            # Shell UIA providers can time out while a XAML menu is opening.
            # Retry within the deadline and refresh the desktop root.
            $searchRoot = if ($Root -eq [System.Windows.Automation.AutomationElement]::RootElement) {
                [System.Windows.Automation.AutomationElement]::RootElement
            } else { $Root }
            $element = Find-VisibleElement -Root $searchRoot -Names $Names -Types $Types -ClassName $ClassName
        } catch [System.TimeoutException], [System.Runtime.InteropServices.COMException] {
            $element = $null
        }
        if ($element) { return $element }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible UI element not found: $($Names -join ' / ') [$($Types.ProgrammaticName -join ', ')]"
}

function Click-Element {
    param($Element)
    $bounds = $Element.Current.BoundingRectangle
    $x = [int][Math]::Round($bounds.X + $bounds.Width / 2)
    $y = [int][Math]::Round($bounds.Y + $bounds.Height / 2)
    if (-not [LocalSendShareInput]::SetCursorPos($x, $y)) { throw "Cannot move pointer to $x,$y" }
    [LocalSendShareInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [LocalSendShareInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
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
    $path = Join-Path $EvidenceDirectory "$Name-uia.txt"
    if ($Name -eq 'dialog') { Save-PickerUiTree $path }
    else { Save-ShallowUiTree $path }
}

function Save-ShallowUiTree {
    param([string] $Path)
    # A shallow desktop snapshot remains useful when a deep UIA query hangs.
    # Limit traversal to top-level shell windows and their immediate children.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $topLevels = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($topLevel in $topLevels) {
        try {
            $current = $topLevel.Current
            if ($current.BoundingRectangle.Width -le 0) { continue }
            $lines.Add(('{0} | {1} | {2} | {3}' -f $current.Name, $current.ControlType.ProgrammaticName, $current.ClassName, $current.BoundingRectangle))
            if ($current.Name -notlike '*ShareIconFixture*' -and $current.ControlType -ne [System.Windows.Automation.ControlType]::Menu -and
                $current.ClassName -notlike '*Popup*' -and $current.ClassName -ne '#32768') { continue }
            $children = $topLevel.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($child in $children) {
                $c = $child.Current
                $lines.Add(('  {0} | {1} | {2} | {3}' -f $c.Name, $c.ControlType.ProgrammaticName, $c.ClassName, $c.BoundingRectangle))
            }
        } catch { $lines.Add("UIA snapshot error: $($_.Exception.Message)") }
    }
    $lines | Set-Content $Path
}

function Save-FailureEvidence {
    $path = Join-Path $EvidenceDirectory 'failure.png'
    $bitmap = Save-Screenshot $path
    $bitmap.Dispose()
    try { Save-ShallowUiTree (Join-Path $EvidenceDirectory 'failure-uia.txt') }
    catch { Write-Warning "Shallow UIA snapshot failed: $($_.Exception.Message)" }
    try { Save-PickerUiTree (Join-Path $EvidenceDirectory 'failure-picker-uia.txt') }
    catch { Write-Warning "Picker UIA snapshot failed: $($_.Exception.Message)" }
}

function Get-SharePickerWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($window in $windows) {
        try {
            $current = $window.Current
            if ($current.ClassName -eq 'ApplicationFrameWindow' -and $current.BoundingRectangle.Width -gt 0 -and
                $current.BoundingRectangle.Height -gt 0) { return $window }
        } catch { }
    }
    return $null
}

function Find-SharePickerTarget {
    if (-not $env:UIA3_INTEROP_PATH -or -not (Test-Path $env:UIA3_INTEROP_PATH)) {
        throw 'UIA3_INTEROP_PATH must point to the generated UIAutomationCore interop assembly'
    }
    if (-not $script:Uia3Automation) {
        $assembly = [Reflection.Assembly]::LoadFrom($env:UIA3_INTEROP_PATH)
        $class = $assembly.GetType('LocalSend.UIA3.CUIAutomation8Class')
        if (-not $class) { throw 'Generated interop assembly lacks LocalSend.UIA3.CUIAutomation8Class' }
        $elementType = $assembly.GetType('LocalSend.UIA3.IUIAutomationElement')
        if (-not $elementType) { throw 'Generated interop assembly lacks LocalSend.UIA3.IUIAutomationElement' }
        $script:Uia3ScopeType = $elementType.GetMethod('FindFirst').GetParameters()[0].ParameterType
        $script:Uia3Automation = [Activator]::CreateInstance($class)
        try { $script:Uia3Automation.ConnectionTimeout = 5000 } catch { }
    }
    $uia = $script:Uia3Automation
    $children = [Enum]::ToObject($script:Uia3ScopeType, 2)
    $descendants = [Enum]::ToObject($script:Uia3ScopeType, 4)
    $frame = $uia.GetRootElement().FindFirst($children, $uia.CreatePropertyCondition(30012, 'ApplicationFrameWindow'))
    if (-not $frame) { return $null }
    $name = $uia.CreatePropertyCondition(30005, 'LocalSend')
    $listItem = $uia.CreatePropertyCondition(30003, 50007)
    $target = $frame.FindFirst($descendants, $uia.CreateAndCondition($name, $listItem))
    if (-not $target) { return $null }
    $rect = $target.CurrentBoundingRectangle
    $bounds = [System.Windows.Rect]::new($rect.left, $rect.top, $rect.right - $rect.left, $rect.bottom - $rect.top)
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return $null }
    ('Name={0}; ControlType={1}; ClassName={2}; Bounds={3}' -f $target.CurrentName,
        $target.CurrentControlType, $target.CurrentClassName, $bounds) |
        Set-Content (Join-Path $EvidenceDirectory 'picker-target-uia3.txt')
    return [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = $bounds } }
}

function Wait-SharePickerTarget {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        try {
            $target = Find-SharePickerTarget
            if ($target) { return $target }
        } catch [System.TimeoutException], [System.Runtime.InteropServices.COMException] { }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'LocalSend share picker tile not found in ApplicationFrameWindow'
}

function Save-PickerUiTree {
    param([string] $Path)
    $picker = Get-SharePickerWindow
    if (-not $picker) { return }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($picker, 0))
    while ($queue.Count -gt 0 -and $lines.Count -lt 200) {
        $entry = $queue.Dequeue()
        $element = $entry[0]
        $depth = [int] $entry[1]
        try {
            $current = $element.Current
            $lines.Add(('{0}{1} | {2} | {3} | {4}' -f ('  ' * $depth), $current.Name,
                $current.ControlType.ProgrammaticName, $current.ClassName, $current.BoundingRectangle))
            if ($depth -ge 7) { continue }
            $children = $element.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) { $queue.Enqueue(@($children.Item($i), $depth + 1)) }
        } catch { $lines.Add(('UIA error at depth {0}: {1}' -f $depth, $_.Exception.Message)) }
    }
    $lines | Set-Content $Path
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
    Stop-Process -Name wsl, wslhost -Force -ErrorAction SilentlyContinue
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $window = Wait-VisibleElement -Root $desktop -Names @('ShareIconFixture - File Explorer') -Types @([System.Windows.Automation.ControlType]::Window)
    $handle = [IntPtr] $window.Current.NativeWindowHandle
    $file = Wait-VisibleElement -Root $window -Names @('share-me', 'share-me.txt') -Types @(
        [System.Windows.Automation.ControlType]::ListItem,
        [System.Windows.Automation.ControlType]::DataItem
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # The disposable GitHub Windows image can show a WSL update prompt while
        # Explorer initializes Linux navigation. It can take keyboard focus.
        Stop-Process -Name wsl, wslhost -Force -ErrorAction SilentlyContinue
        [LocalSendShareInput]::ShowWindow($handle, 9) | Out-Null
        if (-not [LocalSendShareInput]::SetForegroundWindow($handle)) { throw 'Could not foreground File Explorer' }
        Click-Element $file
        $file.SetFocus()
        Start-Sleep -Milliseconds 500
        Stop-Process -Name wsl, wslhost -Force -ErrorAction SilentlyContinue
        [LocalSendShareInput]::SetForegroundWindow($handle) | Out-Null
        if ([LocalSendShareInput]::GetForegroundWindow() -ne $handle) {
            Write-Host "Explorer lost foreground before context menu (attempt $attempt)."
            continue
        }
        [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
        Start-Sleep -Seconds 1
        $contextBitmap = Save-Screenshot (Join-Path $EvidenceDirectory "context-attempt-$attempt.png")
        $contextBitmap.Dispose()
        try {
            $share = Wait-VisibleElement -Root $desktop -Names @('Share with', 'Share') -Types @([System.Windows.Automation.ControlType]::MenuItem) -TimeoutSeconds 5
            Click-Element $share
            return $desktop
        } catch {
            if ($_.Exception.Message -notlike 'Visible UI element not found:*') { throw }
            Write-Host "Explorer context menu was interrupted (attempt $attempt): $($_.Exception.Message)"
            [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        }
    }
    throw 'Explorer Share with context menu did not open after three foreground retries'
}

try {
    Write-Host 'GIVEN: install LocalSend with its signed helper and register its real Windows share target.'
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
    Start-Sleep -Seconds 3
    Stop-Process -Name wsl, wslhost -Force -ErrorAction SilentlyContinue
    $fixtureDir = Join-Path $env:TEMP 'ShareIconFixture'
    New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
    Set-Content -Path (Join-Path $fixtureDir 'share-me.txt') -Value 'LocalSend share icon regression fixture'
    Start-Process explorer.exe -ArgumentList $fixtureDir
    Write-Host 'WHEN: select the fixture in Explorer and open Share with > More options.'
    $desktop = Open-ExplorerShareMenu $fixtureDir
    $more = Wait-VisibleElement -Root $desktop -Names @('More options') -Types @([System.Windows.Automation.ControlType]::MenuItem)
    Click-Element $more
    $pickerTarget = Wait-SharePickerTarget
    Save-RelevantUiTree 'dialog' $desktop
    Write-Host 'THEN: inspect the rendered LocalSend picker icon.'
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
    Write-Host 'THEN: inspect the rendered LocalSend recent-target menu icon.'
    $result.Assertions += (Assert-Surface Menu $recentTarget)
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
    $result.Passed = @($result.Assertions | Where-Object { -not $_.Passed }).Count -eq 0
} catch {
    $result.Error = $_.Exception.Message
    try { Save-FailureEvidence } catch { Write-Warning "Failure evidence capture also failed: $($_.Exception.Message)" }
    Write-Error $result.Error -ErrorAction Continue
} finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $EvidenceDirectory 'result.json')
}

if (-not $result.Passed) { exit 1 }
