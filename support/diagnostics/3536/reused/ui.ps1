Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Path (Join-Path $PSScriptRoot native.cs)
$script:Desktop = [System.Windows.Automation.AutomationElement]::RootElement
function Write-Event($Name, $Data) {
    [ordered]@{ Utc = [DateTime]::UtcNow.ToString("o"); Stage = $script:Stage; Name = $Name; Data = $Data } |
        ConvertTo-Json -Depth 8 -Compress | Add-Content (Join-Path $Evidence events.jsonl)
}
function Save-Desktop($Name) {
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
        $bitmap.Save((Join-Path $Evidence "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Save-Tree($Name) {
    $lines = foreach ($w in $script:Desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            "WINDOW $($w.Current.Name) | $($w.Current.ClassName) | $($w.Current.NativeWindowHandle) | $($w.Current.BoundingRectangle)"
            if ($w.Current.BoundingRectangle.Width -gt 0) {
                foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
                    "$($e.Current.Name) | $($e.Current.ControlType.ProgrammaticName) | $($e.Current.AutomationId) | $($e.Current.BoundingRectangle)"
                }
            }
        } catch { "UIA_ERROR $_" }
    }
    $lines | Set-Content (Join-Path $Evidence "$Name-uia.txt")
}
function Find-Ui($Names, $Root = $script:Desktop) {
    foreach ($name in $Names) {
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $name)
        foreach ($e in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
            if (-not $e.Current.IsOffscreen -and $e.Current.BoundingRectangle.Width -gt 0) { return $e }
        }
    }
    return $null
}
function Wait-Ui($Names, $Root = $script:Desktop, $Seconds = 12) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Check-Budget
        $e = Find-Ui $Names $Root
        if ($e) { return $e }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    throw "ENV_BLOCK: UI control unavailable: $($Names -join ", ")"
}
function Focus-Window($Element) {
    $h = [IntPtr]$Element.Current.NativeWindowHandle
    [Issue3456Native]::ShowWindow($h, 9) | Out-Null
    [Issue3456Native]::SetForegroundWindow($h) | Out-Null
    if ([Issue3456Native]::GetForegroundWindow() -ne $h) { throw "ENV_BLOCK: foreground control failed" }
    Write-Event foreground @{ Handle = "$h"; Name = $Element.Current.Name }
}
function Click-Ui($Element, [switch]$Right, [switch]$Double) {
    $r = $Element.Current.BoundingRectangle
    $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    if (-not [Issue3456Native]::SetCursorPos($x, $y)) { throw "ENV_BLOCK: pointer unavailable" }
    Write-Event mouse @{ X = $x; Y = $y; Right = [bool]$Right; Double = [bool]$Double; Target = $Element.Current.Name }
    $down = if ($Right) { 8 } else { 2 }; $up = if ($Right) { 16 } else { 4 }
    [Issue3456Native]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    [Issue3456Native]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
    if ($Double) {
        Start-Sleep -Milliseconds 100
        [Issue3456Native]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
        [Issue3456Native]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 400
}
function Send-Keys($Keys) {
    Write-Event keys @{ Keys = $Keys; Foreground = "$( [Issue3456Native]::GetForegroundWindow() )" }
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
}
function Start-Clip($Name) {
    $out = Join-Path $Evidence "$Name.mp4"
    $args = "-y -f gdigrab -framerate 10 -draw_mouse 1 -i desktop -t 120 -c:v libx264 -threads 2 -preset ultrafast -crf 25 -pix_fmt yuv420p -movflags +frag_keyframe+empty_moov `"$out`""
    $psi = [System.Diagnostics.ProcessStartInfo]::new("ffmpeg.exe", $args)
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
    $script:Recorder = [System.Diagnostics.Process]::Start($psi)
    $script:RecorderLog = $script:Recorder.StandardError.ReadToEndAsync()
    $script:ClipName = $Name
    Start-Sleep -Milliseconds 800
    Write-Event recording @{ Name = $Name; Pid = $script:Recorder.Id; Rate = 10; MaximumSeconds = 120 }
}
function Stop-Clip {
    if ($script:Recorder) {
        if (-not $script:Recorder.HasExited) { $script:Recorder.StandardInput.WriteLine("q") }
        if (-not $script:Recorder.WaitForExit(6000)) { $script:Recorder.Kill() }
        $script:RecorderLog.GetAwaiter().GetResult() | Set-Content (Join-Path $Evidence "$script:ClipName-ffmpeg.txt")
        $script:Recorder = $null
    }
}
function App-Processes {
    @(Get-Process localsend_app -ErrorAction SilentlyContinue | Where-Object { -not $script:ExpectedExe -or $_.Path -eq $script:ExpectedExe })
}
function Assert-CleanLaunch {
    $script:LaunchBaseline = @(Get-Process localsend_app -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($script:LaunchBaseline.Count -gt 0) { throw "ENV_BLOCK: previous app process still running before launch" }
}
function Wait-App($Seconds = 15) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Check-Budget
        $apps = App-Processes
        foreach ($app in $apps) {
            if ($app.MainWindowHandle -ne 0 -and $app.Id -notin $script:LaunchBaseline) {
                $window = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
                if ($window.Current.ProcessId -ne $app.Id -or $window.Current.IsOffscreen) { continue }
                Focus-Window $window
                Write-Event nativeProcessIdentity @{ Pid = $app.Id; Path = $app.Path; StartTime = $app.StartTime.ToUniversalTime().ToString("o"); Package = [Issue3456Native]::ProcessPackage([uint32]$app.Id); Handle = "$($app.MainWindowHandle)" }
                return $app
            }
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    return $null
}
function Quit-App([switch]$Required, [int]$ExpectedPid = 0) {
    $before = @(App-Processes | Select-Object Id, Path, StartTime)
    if ($before.Count -eq 0) {
        if ($Required) { throw "ENV_BLOCK: mandatory genuine Exit has no live owned app" }
        return
    }
    if ($ExpectedPid -ne 0 -and $ExpectedPid -notin @($before.Id)) { throw "ENV_BLOCK: mandatory Exit target changed from observed app PID" }
    Write-Event actualQuitBefore @{ ExpectedPid = $ExpectedPid; OwnedProcesses = $before; Required = [bool]$Required }
    function Find-TrayIcon {
        $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, "LocalSend"),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        ))
        $icons = @()
        foreach ($root in $script:Desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ($root.Current.ClassName -notin @("Shell_TrayWnd", "NotifyIconOverflowWindow")) { continue }
            foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
                if (-not $e.Current.IsOffscreen) { $icons += $e }
            }
        }
        if ($icons.Count -gt 1) { throw "ENV_BLOCK: ambiguous tray icon selection" }
        if ($icons.Count -eq 1) { return $icons[0] }
        return $null
    }
    $icon = Find-TrayIcon
    if (-not $icon) {
        $chevron = Find-Ui @("Show hidden icons", "Notification Chevron")
        if ($chevron) { Click-Ui $chevron }
        $icon = Find-TrayIcon
    }
    if (-not $icon) {
        Initialize-NativePicker
        Save-Desktop "$script:Stage-tray-before-native"
        [Issue3456Picker]::TraySnapshot() | Set-Content (Join-Path $Evidence "$script:Stage-tray-native-uia.txt")
        $icon = Find-NativeTrayControl "LocalSend"
        if (-not $icon) {
            $chevron = Find-NativeTrayControl "Show hidden icons"
            if (-not $chevron) { $chevron = Find-NativeTrayControl "Notification Chevron" }
            if ($chevron) { Click-Ui $chevron; $icon = Wait-NativeTrayControl "LocalSend" }
        }
    }
    if (-not $icon) { throw "ENV_BLOCK: named native LocalSend tray icon unavailable; actual Exit not reached" }
    Click-Ui $icon -Right
    $exit = $null
    $menuCandidates = @()
    foreach ($menu in $script:Desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($menu.Current.ClassName -ne "#32768") { continue }
        if ($menu.Current.ProcessId -notin @($before.Id)) { continue }
        $item = Find-Ui @("Exit") $menu
        if ($item -and $item.Current.ProcessId -in @($before.Id) -and $item.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem) {
            Write-Event ownedExitMenu @{ MenuPid = $menu.Current.ProcessId; MenuHandle = $menu.Current.NativeWindowHandle; OwnedPids = @($before.Id); Name = $item.Current.Name; Backend = "Managed UI Automation" }
            $menuCandidates += $item
        }
    }
    if ($menuCandidates.Count -gt 1) { throw "ENV_BLOCK: ambiguous native Exit menu item" }
    if ($menuCandidates.Count -eq 1) { $exit = $menuCandidates[0] }
    if (-not $exit) {
        Initialize-NativePicker
        $exit = Wait-NativeTrayControl "Exit" -Popup -OwnerIds @($before.Id)
    }
    Save-Desktop "$script:Stage-tray-exit-menu"
    Click-Ui $exit
    $end = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if ((App-Processes).Count -eq 0 -and @(Get-Process -Id @($before.Id) -ErrorAction SilentlyContinue).Count -eq 0) {
            Write-Event actualQuit $before
            Save-PackageInventory "$script:Stage-after-actualQuit" | Out-Null
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $end)
    throw "ENV_BLOCK: actual tray Exit did not terminate app; window close is insufficient"
}
function Open-Share($FixtureFolder) {
    Start-Process explorer.exe -ArgumentList "`"$FixtureFolder`""
    $window = Wait-Ui @("Issue3456Fixture", "Issue3456Fixture - File Explorer")
    Focus-Window $window
    $file = Wait-Ui @("share-3456.txt", "share-3456") $window
    Click-Ui $file
    Focus-Window $window
    # Selection and context menu are real Explorer input, not shell Share COM injection.
    Send-Keys "+{F10}"
    # 'Share with' can be SMB sharing on Server; only invoke the modern Share command.
    $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, "Share"),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    ))
    $end = [DateTime]::UtcNow.AddSeconds(12)
    do {
        Check-Budget
        $commands = @($script:Desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) | Where-Object { -not $_.Current.IsOffscreen })
        if ($commands.Count -gt 1) { throw "ENV_BLOCK: ambiguous modern Explorer Share command" }
        if ($commands.Count -eq 1) { break }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    if ($commands.Count -ne 1) { throw "ENV_BLOCK: unique modern Explorer Share command unavailable; SMB Share with is excluded" }
    Click-Ui $commands[0]
    $more = Find-Ui @("More options")
    if ($more) { Click-Ui $more }
    Save-Desktop "$script:Stage-share"
    Save-Tree "$script:Stage-share"
    # Successful native COM target lookup separately qualifies the opened picker.
}
function Initialize-NativePicker {
    if ("Issue3456Picker" -as [type]) { return }
    # Read-only PR 72 diagnostic pattern: native COM UIA with finite provider timeouts.
    $tlbimp = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows" -Filter TlbImp.exe -Recurse | Select-Object -First 1
    if (-not $tlbimp) { throw "ENV_BLOCK: SDK UIA type-library importer unavailable" }
    $interop = Join-Path $Evidence NativeUIA.dll
    & $tlbimp.FullName "$env:WINDIR\System32\UIAutomationCore.dll" /namespace:Issue3456.UIA "/out:$interop" /silent 2>&1 |
        Out-File (Join-Path $Evidence uia-import-original.txt)
    if ($LASTEXITCODE -ne 0) { throw "ENV_BLOCK: native UIA import failed" }
    [Reflection.Assembly]::LoadFrom($interop) | Out-Null
    Add-Type -ReferencedAssemblies $interop -TypeDefinition @"
using Issue3456.UIA;
using System;
using System.Text;
public sealed class Issue3456PickerTarget { public int Left, Top, Right, Bottom, ControlType, RootProcessId; public string Name, ClassName, RootWindowHandle; }
public static class Issue3456Picker {
    static IUIAutomation Client() {
        var instance = new CUIAutomation8Class();
        var newer = (IUIAutomation2)instance;
        newer.ConnectionTimeout = 3000; newer.TransactionTimeout = 3000;
        return (IUIAutomation)instance;
    }
    static Issue3456PickerTarget Visible(IUIAutomationElement element) {
        if (Convert.ToBoolean(element.GetCurrentPropertyValue(30022))) return null;
        var r = element.CurrentBoundingRectangle;
        if (r.right <= r.left || r.bottom <= r.top) return null;
        return new Issue3456PickerTarget { Left=r.left, Top=r.top, Right=r.right, Bottom=r.bottom,
            Name=element.CurrentName, ClassName=element.CurrentClassName, ControlType=element.CurrentControlType };
    }
    public static Issue3456PickerTarget TrayControl(string name, bool popup, int[] ownerIds) {
        var uia = Client();
        var roots = uia.GetRootElement().FindAll((TreeScope)2, uia.CreateTrueCondition());
        Issue3456PickerTarget result = null;
        for (int i=0; i<roots.Length; i++) {
            var root = roots.GetElement(i);
            string cls = root.CurrentClassName;
            if (popup ? cls != "#32768" : cls != "Shell_TrayWnd" && cls != "NotifyIconOverflowWindow") continue;
            if (popup && Array.IndexOf(ownerIds, root.CurrentProcessId) < 0) continue;
            var condition = uia.CreatePropertyCondition(30005, name);
            if (popup) condition = uia.CreateAndCondition(condition, uia.CreatePropertyCondition(30003, 50011));
            var elements = root.FindAll((TreeScope)4, condition);
            for (int j=0; j<elements.Length; j++) {
                var candidate = Visible(elements.GetElement(j));
                if (candidate == null) continue;
                if (popup && Array.IndexOf(ownerIds, elements.GetElement(j).CurrentProcessId) < 0) continue;
                if (result != null) throw new InvalidOperationException("Ambiguous named native tray/menu control");
                candidate.RootProcessId = root.CurrentProcessId;
                candidate.RootWindowHandle = root.CurrentNativeWindowHandle.ToString();
                result = candidate;
            }
        }
        return result;
    }
    public static string TraySnapshot() {
        var uia = Client();
        var roots = uia.GetRootElement().FindAll((TreeScope)2, uia.CreateTrueCondition());
        var lines = new StringBuilder();
        for (int i=0; i<roots.Length; i++) {
            var root = roots.GetElement(i);
            if (root.CurrentClassName != "Shell_TrayWnd" && root.CurrentClassName != "NotifyIconOverflowWindow") continue;
            lines.AppendLine("ROOT " + root.CurrentClassName);
            var elements = root.FindAll((TreeScope)4, uia.CreateTrueCondition());
            for (int j=0; j<Math.Min(elements.Length, 128); j++) {
                var element = elements.GetElement(j);
                var r = element.CurrentBoundingRectangle;
                lines.AppendLine(element.CurrentName + " | " + element.CurrentClassName + " | " + element.CurrentControlType + " | " + r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
        }
        return lines.ToString();
    }
    public static Issue3456PickerTarget Find() {
        var uia = Client();
        var frame = uia.GetRootElement().FindFirst((TreeScope)2, uia.CreatePropertyCondition(30012, "ApplicationFrameWindow"));
        if (frame == null) return null;
        var target = frame.FindFirst((TreeScope)4, uia.CreatePropertyCondition(30005, "LocalSend"));
        if (target == null) return null;
        var r = target.CurrentBoundingRectangle;
        return new Issue3456PickerTarget { Left=r.left, Top=r.top, Right=r.right, Bottom=r.bottom };
    }
}
"@
}
function Find-NativeTrayControl($Name, [switch]$Popup, [int[]]$OwnerIds = @()) {
    $target = [Issue3456Picker]::TrayControl($Name, [bool]$Popup, $OwnerIds)
    if (-not $target) { return $null }
    Write-Event nativeTrayControl @{ Popup = [bool]$Popup; Target = $target; OwnedPids = $OwnerIds; Backend = "Native COM UI Automation; no window-close or termination injection" }
    return [pscustomobject]@{ Current = [pscustomobject]@{ Name = $target.Name; BoundingRectangle = [System.Windows.Rect]::new($target.Left, $target.Top, $target.Right-$target.Left, $target.Bottom-$target.Top) } }
}
function Wait-NativeTrayControl($Name, [switch]$Popup, [int[]]$OwnerIds = @()) {
    $end = [DateTime]::UtcNow.AddSeconds(12)
    do {
        Check-Budget
        $target = Find-NativeTrayControl $Name -Popup:$Popup -OwnerIds $OwnerIds
        if ($target) { return $target }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    throw "ENV_BLOCK: named native tray/menu control unavailable: $Name"
}
function Wait-StartMenuEntry {
    $end = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Check-Budget
        $matches = @()
        foreach ($root in $script:Desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
            $process = Get-Process -Id $root.Current.ProcessId -ErrorAction SilentlyContinue
            if ($process.ProcessName -notin @("StartMenuExperienceHost", "SearchApp", "SearchHost", "SearchUI")) { continue }
            foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
                if ($e.Current.Name -eq "LocalSend" -and -not $e.Current.IsOffscreen -and $e.Current.ControlType -in @([System.Windows.Automation.ControlType]::ListItem, [System.Windows.Automation.ControlType]::Button)) {
                    $matches += $e
                    Write-Event startMenuCandidate @{ Process = $process.ProcessName; Root = $root.Current.Name; Name = $e.Current.Name; Type = $e.Current.ControlType.ProgrammaticName; Bounds = "$($e.Current.BoundingRectangle)" }
                }
            }
        }
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1) { throw "ENV_BLOCK: ambiguous native Start Menu app result" }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    throw "ENV_BLOCK: native Start Menu app result unavailable in shell host"
}
function Wait-NativePickerTarget {
    $end = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Check-Budget
        $target = [Issue3456Picker]::Find()
        if ($target -and $target.Right -gt $target.Left) {
            Write-Event nativePickerTarget $target
            return [pscustomobject]@{ Current = [pscustomobject]@{ Name = "LocalSend native Share tile"; BoundingRectangle = [System.Windows.Rect]::new($target.Left, $target.Top, $target.Right-$target.Left, $target.Bottom-$target.Top) } }
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $end)
    throw "ENV_BLOCK: LocalSend target unavailable in native Share picker"
}
