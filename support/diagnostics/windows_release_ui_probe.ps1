# Launch the official portable LocalSend release on a Windows desktop and capture its UI.
param(
  [string] $OutputDirectory = $env:LS_RELEASE_UI_OUTPUT,
  [ValidateSet('File', 'Folder')][string] $SelectionMode = 'File',
  [ValidateSet('arm-64', 'x86-64')][string] $AssetArchitecture = 'arm-64',
  [ValidateSet('windows-11-arm', 'windows-2025', 'auto')][string] $RunnerLabel = 'auto'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  throw 'Set LS_RELEASE_UI_OUTPUT or pass -OutputDirectory.'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$assetName = "LocalSend-1.18.2-windows-$AssetArchitecture.zip"
$releaseUrl = "https://github.com/localsend/localsend/releases/download/v1.18.2/$assetName"
$archivePath = Join-Path $OutputDirectory $assetName
$extractPath = Join-Path $OutputDirectory 'release'
$screenshotPath = Join-Path $OutputDirectory 'desktop.png'
$windowScreenshotPath = Join-Path $OutputDirectory 'app-window.png'
$sendScreenshotPath = Join-Path $OutputDirectory 'app-window-send.png'
$afterFileScreenshotPath = Join-Path $OutputDirectory 'app-window-after-file.png'
$afterFolderScreenshotPath = Join-Path $OutputDirectory 'app-window-after-folder.png'
$afterSelectionScreenshotPath = if ($SelectionMode -eq 'Folder') { $afterFolderScreenshotPath } else { $afterFileScreenshotPath }
$reportPath = Join-Path $OutputDirectory 'release-ui-report.json'
$firewallRuleName = $null
$osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$expectedExecution = switch ($RunnerLabel) {
  'windows-11-arm' { if ($AssetArchitecture -eq 'arm-64') { 'native ARM64 on Windows 11 ARM' } else { 'x64 emulation on Windows 11 ARM' } }
  'windows-2025' { 'native x64 on Windows Server 2025' }
  default { if ($AssetArchitecture -eq 'arm-64') { 'native ARM64 on ARM64 host' } elseif ($osArchitecture -eq 'Arm64') { 'x64 emulation on ARM64 host' } else { 'native x64 on x64 host' } }
}
if ($RunnerLabel -eq 'windows-2025' -and $AssetArchitecture -ne 'x86-64') {
  throw 'The windows-2025 runner case requires the x86-64 release asset.'
}
$report = [ordered]@{
  release = 'v1.18.2'
  selectionMode = $SelectionMode
  assetArchitecture = $AssetArchitecture
  expectedExecution = $expectedExecution
  assetName = $assetName
  assetUrl = $releaseUrl
  runner = $env:RUNNER_NAME
  runnerLabel = $RunnerLabel
  os = [System.Environment]::OSVersion.VersionString
  osCaption = $null
  processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  osArchitecture = $osArchitecture
  sessionName = $env:SESSIONNAME
  user = [System.Environment]::UserName
  startedUtc = [DateTime]::UtcNow.ToString('o')
  status = 'inconclusive'
  archive = $null
  executable = $null
  launchedPid = $null
  processes = @()
  windows = @()
  topLevelBefore = @()
  topLevelAfter = @()
  firewall = @()
  activation = @()
  foreground = $null
  screenshot = $null
  windowScreenshot = $null
  sendTab = $null
  fileSelection = $null
  appUiTree = @()
  firewallRule = $null
  errors = @()
}

try {
  $report.osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
  Invoke-WebRequest -Uri $releaseUrl -OutFile $archivePath -MaximumRedirection 10
  $archive = Get-Item -LiteralPath $archivePath
  if ($archive.Length -lt 1000000) { throw "Downloaded archive is unexpectedly small: $($archive.Length) bytes" }
  $report.archive = [ordered]@{
    path = $archivePath
    bytes = $archive.Length
    sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  }

  [System.IO.Directory]::CreateDirectory($extractPath) | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
  $candidates = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter 'localsend_app.exe')
  if ($candidates.Count -eq 0) {
    $candidates = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter 'LocalSend.exe')
  }
  if ($candidates.Count -ne 1) {
    $exeList = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter '*.exe' | ForEach-Object FullName)
    throw "Expected one LocalSend application executable, found $($candidates.Count). Executables: $($exeList -join ', ')"
  }
  $exe = $candidates[0]
  $exeStream = [System.IO.File]::OpenRead($exe.FullName)
  try {
    $reader = [System.IO.BinaryReader]::new($exeStream)
    [void] $exeStream.Seek(0x3C, [System.IO.SeekOrigin]::Begin)
    $peOffset = $reader.ReadInt32()
    [void] $exeStream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
    if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature in $($exe.FullName)" }
    $machine = $reader.ReadUInt16()
  } finally {
    $exeStream.Dispose()
  }
  $expectedMachine = if ($AssetArchitecture -eq 'arm-64') { 0xAA64 } else { 0x8664 }
  if ($machine -ne $expectedMachine) {
    throw ('Unexpected PE machine 0x{0:X4} for {1}; expected 0x{2:X4}.' -f $machine, $assetName, $expectedMachine)
  }
  $report.executable = [ordered]@{
    path = $exe.FullName
    bytes = $exe.Length
    version = $exe.VersionInfo.FileVersion
    peMachine = ('0x{0:X4}' -f $machine)
    architecture = $AssetArchitecture
    sha256 = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
  }

  $firewallRuleName = 'LocalSendDiagnosticBlock-' + [Guid]::NewGuid().ToString('N')
  New-NetFirewallRule -Name $firewallRuleName -DisplayName $firewallRuleName -Direction Inbound -Program $exe.FullName -Action Block -Profile Any -Enabled True -ErrorAction Stop | Out-Null
  $report.firewallRule = [ordered]@{
    name = $firewallRuleName
    program = $exe.FullName
    direction = 'Inbound'
    action = 'Block'
    installed = $true
    removed = $false
  }

  $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace LocalSendReleaseUiProbe {
  public class WindowInfo {
    public int Pid;
    public string Hwnd;
    public string ClassName;
    public string Title;
    public bool Visible;
    public int Left;
    public int Top;
    public int Width;
    public int Height;
  }
  public class ClickInfo {
    public bool Posted;
    public string Error;
    public string TargetHwnd;
    public string TargetClass;
    public int ClientX;
    public int ClientY;
  }
  public static class Windows {
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr ChildWindowFromPointEx(IntPtr parent, POINT point, uint flags);
    [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from, IntPtr to, ref POINT point, uint count);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    private static WindowInfo[] Enumerate(int pid) {
      List<WindowInfo> found = new List<WindowInfo>();
      EnumWindows((hwnd, data) => {
        uint owner;
        GetWindowThreadProcessId(hwnd, out owner);
        if (pid >= 0 && owner != pid) return true;
        StringBuilder cls = new StringBuilder(256), title = new StringBuilder(1024);
        GetClassName(hwnd, cls, cls.Capacity);
        GetWindowText(hwnd, title, title.Capacity);
        RECT rect;
        GetWindowRect(hwnd, out rect);
        found.Add(new WindowInfo {
          Pid = (int)owner, Hwnd = "0x" + hwnd.ToInt64().ToString("X"), ClassName = cls.ToString(),
          Title = title.ToString(), Visible = IsWindowVisible(hwnd),
          Left = rect.Left, Top = rect.Top, Width = rect.Right - rect.Left, Height = rect.Bottom - rect.Top
        });
        return true;
      }, IntPtr.Zero);
      return found.ToArray();
    }
    public static WindowInfo[] ForProcess(int pid) { return Enumerate(pid); }
    public static WindowInfo[] All() { return Enumerate(-1); }
    public static bool Exists(IntPtr hwnd) { return IsWindow(hwnd) && IsWindowVisible(hwnd); }
    public static bool Activate(IntPtr hwnd) {
      ShowWindow(hwnd, 9); // SW_RESTORE
      BringWindowToTop(hwnd);
      return SetForegroundWindow(hwnd);
    }
    public static bool Escape(IntPtr hwnd) {
      const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101;
      const int VK_ESCAPE = 0x1B;
      bool down = PostMessage(hwnd, WM_KEYDOWN, new IntPtr(VK_ESCAPE), IntPtr.Zero);
      bool up = PostMessage(hwnd, WM_KEYUP, new IntPtr(VK_ESCAPE), IntPtr.Zero);
      return down && up;
    }
    public static bool Capture(IntPtr hwnd, IntPtr hdc) { return PrintWindow(hwnd, hdc, 2) || PrintWindow(hwnd, hdc, 0); }
    public static ClickInfo ClickClient(IntPtr app, int x, int y) {
      ClickInfo info = new ClickInfo { ClientX = x, ClientY = y };
      RECT client;
      if (!Exists(app) || !GetClientRect(app, out client) || x < 0 || y < 0 || x >= client.Right || y >= client.Bottom) {
        info.Error = "Click point is outside the visible LocalSend client area.";
        return info;
      }
      POINT point = new POINT { X = x, Y = y };
      IntPtr target = app;
      // Flutter may host its view in a child HWND; send the mouse messages there.
      for (int depth = 0; depth < 4; depth++) {
        IntPtr child = ChildWindowFromPointEx(target, point, 1); // CWP_SKIPINVISIBLE
        if (child == IntPtr.Zero || child == target) break;
        MapWindowPoints(target, child, ref point, 1);
        target = child;
      }
      uint appPid, targetPid;
      GetWindowThreadProcessId(app, out appPid);
      GetWindowThreadProcessId(target, out targetPid);
      if (appPid != targetPid) {
        info.Error = "The hit-tested child HWND is owned by a different process.";
        return info;
      }
      info.TargetHwnd = "0x" + target.ToInt64().ToString("X");
      StringBuilder cls = new StringBuilder(256);
      GetClassName(target, cls, cls.Capacity);
      info.TargetClass = cls.ToString();
      info.ClientX = point.X;
      info.ClientY = point.Y;
      IntPtr packed = new IntPtr((point.Y << 16) | (point.X & 0xFFFF));
      bool move = PostMessage(target, 0x0200, IntPtr.Zero, packed); // WM_MOUSEMOVE
      bool down = PostMessage(target, 0x0201, new IntPtr(1), packed); // WM_LBUTTONDOWN, MK_LBUTTON
      bool up = PostMessage(target, 0x0202, IntPtr.Zero, packed); // WM_LBUTTONUP
      info.Posted = move && down && up;
      if (!info.Posted) info.Error = "Could not post the three mouse messages to the LocalSend HWND.";
      return info;
    }
    public static WindowInfo Foreground() {
      IntPtr foreground = GetForegroundWindow();
      if (foreground == IntPtr.Zero) return null;
      foreach (WindowInfo window in All()) if (window.Hwnd == "0x" + foreground.ToInt64().ToString("X")) return window;
      return null;
    }
  }
}
'@
  Add-Type -TypeDefinition $source -Language CSharp

  $started = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
  $report.launchedPid = $started.Id
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  $visible = $false
  do {
    Start-Sleep -Milliseconds 500
    # A release build may spawn a second instance and exit the initial process.
    $running = @(Get-CimInstance Win32_Process -Filter ("Name = '{0}'" -f $exe.Name) |
      Where-Object {
        $_.ProcessId -eq $started.Id -or
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($extractPath, [System.StringComparison]::OrdinalIgnoreCase))
      })
    $report.processes = @($running | ForEach-Object {
      [ordered]@{ pid = $_.ProcessId; parentPid = $_.ParentProcessId; executablePath = $_.ExecutablePath; commandLine = $_.CommandLine }
    })
    $report.windows = @($running | ForEach-Object {
      [LocalSendReleaseUiProbe.Windows]::ForProcess([int] $_.ProcessId)
    })
    $visible = @($report.windows | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 }).Count -gt 0
  } until ($visible -or [DateTime]::UtcNow -ge $deadline)

  if ($visible) {
    Start-Sleep -Seconds 3
    $report.windows = @($running | ForEach-Object {
      [LocalSendReleaseUiProbe.Windows]::ForProcess([int] $_.ProcessId)
    })
  }

  $report.topLevelBefore = @([LocalSendReleaseUiProbe.Windows]::All())
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  foreach ($window in @($report.topLevelBefore | Where-Object {
    $_.Visible -and $_.Title -match '^(Windows Security|Windows Security Alert|Windows Defender Firewall)$'
  })) {
    $entry = [ordered]@{ hwnd = $window.Hwnd; title = $window.Title; className = $window.ClassName; names = @(); matchedFirewall = $false; action = 'none'; closed = $false; error = $null }
    try {
      $hwnd = [IntPtr]::new([Convert]::ToInt64($window.Hwnd.Substring(2), 16))
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
      $elements = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
      )
      $cancel = $null
      foreach ($element in $elements) {
        try {
          $name = [string] $element.Current.Name
          if (-not [string]::IsNullOrWhiteSpace($name)) { $entry.names += $name }
          if ($name -eq 'Cancel' -and $element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) {
            $cancel = $element
          }
        } catch { }
      }
      $entry.names = @($entry.names | Select-Object -Unique | Select-Object -First 100)
      $entry.matchedFirewall = $window.Title -match 'Firewall' -or
        @($entry.names | Where-Object { $_ -match '(?i)firewall|blocked some features' }).Count -gt 0
      if ($entry.matchedFirewall) {
        if ($cancel) {
          try {
            $pattern = $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $pattern.Invoke()
            $entry.action = 'Invoked this firewall prompt Cancel button through UI Automation'
          } catch {
            $entry.action = "Cancel invocation failed: $($_.Exception.Message); posting Escape to this firewall prompt HWND"
            if (-not [LocalSendReleaseUiProbe.Windows]::Escape($hwnd)) { throw 'Could not post Escape to firewall prompt HWND.' }
          }
        } else {
          $entry.action = 'Posted Escape to this firewall prompt HWND'
          if (-not [LocalSendReleaseUiProbe.Windows]::Escape($hwnd)) { throw 'Could not post Escape to firewall prompt HWND.' }
        }
        for ($attempt = 0; $attempt -lt 30 -and [LocalSendReleaseUiProbe.Windows]::Exists($hwnd); $attempt++) {
          Start-Sleep -Milliseconds 100
        }
        $entry.closed = -not [LocalSendReleaseUiProbe.Windows]::Exists($hwnd)
        if (-not $entry.closed -and $cancel) {
          $entry.action += '; posted Escape to this firewall prompt HWND'
          [void] [LocalSendReleaseUiProbe.Windows]::Escape($hwnd)
          Start-Sleep -Milliseconds 500
          $entry.closed = -not [LocalSendReleaseUiProbe.Windows]::Exists($hwnd)
        }
        if (-not $entry.closed) { $entry.error = 'Firewall prompt remained visible after Cancel/Escape.' }
      }
    } catch {
      $entry.error = $_.Exception.ToString()
    }
    $report.firewall += $entry
  }

  $target = @($report.windows | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 } |
    Sort-Object -Property @{ Expression = { $_.Width * $_.Height }; Descending = $true } | Select-Object -First 1)
  if ($target.Count -gt 0) {
    $appWindow = $target[0]
    $appHwnd = [IntPtr]::new([Convert]::ToInt64($appWindow.Hwnd.Substring(2), 16))
    $nativeResult = [LocalSendReleaseUiProbe.Windows]::Activate($appHwnd)
    $report.activation += [ordered]@{ method = 'ShowWindow/BringWindowToTop/SetForegroundWindow'; hwnd = $appWindow.Hwnd; returned = $nativeResult }
    Start-Sleep -Milliseconds 500
    $foreground = [LocalSendReleaseUiProbe.Windows]::Foreground()
    if (-not $foreground -or $foreground.Pid -ne $appWindow.Pid) {
      try {
        $shell = New-Object -ComObject WScript.Shell
        $appActivateResult = $shell.AppActivate([int] $appWindow.Pid)
        $report.activation += [ordered]@{ method = 'WScript.Shell.AppActivate'; pid = $appWindow.Pid; returned = $appActivateResult }
      } catch {
        $report.activation += [ordered]@{ method = 'WScript.Shell.AppActivate'; pid = $appWindow.Pid; error = $_.Exception.Message }
      }
    }
  }
  Start-Sleep -Seconds 2
  $report.topLevelAfter = @([LocalSendReleaseUiProbe.Windows]::All())
  $report.foreground = [LocalSendReleaseUiProbe.Windows]::Foreground()

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  if ($target.Count -gt 0) {
    try {
      $appElement = [System.Windows.Automation.AutomationElement]::FromHandle($appHwnd)
      $appElements = $appElement.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
      )
      foreach ($element in $appElements) {
        if ($report.appUiTree.Count -ge 150) { break }
        try {
          $report.appUiTree += [ordered]@{
            name = [string] $element.Current.Name
            controlType = [string] $element.Current.ControlType.ProgrammaticName
            automationId = [string] $element.Current.AutomationId
          }
        } catch { }
      }
    } catch {
      $report.errors += "LocalSend UI Automation tree: $($_.Exception.Message)"
    }

    try {
      $windowBitmap = [System.Drawing.Bitmap]::new($appWindow.Width, $appWindow.Height)
      try {
        $windowGraphics = [System.Drawing.Graphics]::FromImage($windowBitmap)
        try {
          $hdc = $windowGraphics.GetHdc()
          try {
            $printed = [LocalSendReleaseUiProbe.Windows]::Capture($appHwnd, $hdc)
          } finally {
            $windowGraphics.ReleaseHdc($hdc)
          }
        } finally {
          $windowGraphics.Dispose()
        }
        if ($printed) {
          $windowBitmap.Save($windowScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $windowColors = [System.Collections.Generic.HashSet[int]]::new()
          for ($y = 0; $y -lt $appWindow.Height; $y += [Math]::Max(1, [int]($appWindow.Height / 10))) {
            for ($x = 0; $x -lt $appWindow.Width; $x += [Math]::Max(1, [int]($appWindow.Width / 10))) {
              [void] $windowColors.Add($windowBitmap.GetPixel($x, $y).ToArgb())
            }
          }
          $report.windowScreenshot = [ordered]@{
            path = $windowScreenshotPath
            bytes = (Get-Item -LiteralPath $windowScreenshotPath).Length
            hwnd = $appWindow.Hwnd
            width = $appWindow.Width
            height = $appWindow.Height
            sampledDistinctColors = $windowColors.Count
          }
        } else {
          $report.errors += 'PrintWindow returned false for the LocalSend window.'
        }
      } finally {
        $windowBitmap.Dispose()
      }
    } catch {
      $report.errors += "LocalSend PrintWindow capture: $($_.Exception.Message)"
    }

    $report.sendTab = [ordered]@{
      requestedClientX = 200
      requestedClientY = 442
      action = 'WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_LBUTTONUP to LocalSend HWND'
      click = $null
      screenshot = $null
      beforeSha256 = $null
      afterSha256 = $null
      imageChanged = $false
      uiNamesAfter = @()
      error = $null
    }
    $click = [LocalSendReleaseUiProbe.Windows]::ClickClient($appHwnd, 200, 442)
    $report.sendTab.click = $click
    if ($click.Posted) {
      Start-Sleep -Seconds 2
      try {
        $sendBitmap = [System.Drawing.Bitmap]::new($appWindow.Width, $appWindow.Height)
        try {
          $sendGraphics = [System.Drawing.Graphics]::FromImage($sendBitmap)
          try {
            $sendHdc = $sendGraphics.GetHdc()
            try {
              $sendPrinted = [LocalSendReleaseUiProbe.Windows]::Capture($appHwnd, $sendHdc)
            } finally {
              $sendGraphics.ReleaseHdc($sendHdc)
            }
          } finally {
            $sendGraphics.Dispose()
          }
          if (-not $sendPrinted) { throw 'PrintWindow returned false after clicking Send.' }
          $sendBitmap.Save($sendScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
          $report.sendTab.screenshot = [ordered]@{
            path = $sendScreenshotPath
            bytes = (Get-Item -LiteralPath $sendScreenshotPath).Length
            hwnd = $appWindow.Hwnd
            width = $appWindow.Width
            height = $appWindow.Height
          }
        } finally {
          $sendBitmap.Dispose()
        }
        if ($report.windowScreenshot) {
          $report.sendTab.beforeSha256 = (Get-FileHash -LiteralPath $windowScreenshotPath -Algorithm SHA256).Hash
          $report.sendTab.afterSha256 = (Get-FileHash -LiteralPath $sendScreenshotPath -Algorithm SHA256).Hash
          $report.sendTab.imageChanged = $report.sendTab.beforeSha256 -ne $report.sendTab.afterSha256
          if (-not $report.sendTab.imageChanged) { $report.sendTab.error = 'The LocalSend window image did not change after clicking Send.' }
        }
        try {
          $afterRoot = [System.Windows.Automation.AutomationElement]::FromHandle($appHwnd)
          $afterElements = $afterRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
          foreach ($element in $afterElements) {
            if ($report.sendTab.uiNamesAfter.Count -ge 100) { break }
            try {
              $name = [string] $element.Current.Name
              if (-not [string]::IsNullOrWhiteSpace($name)) { $report.sendTab.uiNamesAfter += $name }
            } catch { }
          }
        } catch { }
      } catch {
        $report.sendTab.error = $_.Exception.ToString()
      }
    } else {
      $report.sendTab.error = $click.Error
    }

    $fixtureDirectory = if ($SelectionMode -eq 'Folder') { Join-Path $OutputDirectory 'folder-containing-old-file' } else { $OutputDirectory }
    [System.IO.Directory]::CreateDirectory($fixtureDirectory) | Out-Null
    $fixturePath = Join-Path $fixtureDirectory 'fixture-1979-12-31.txt'
    [System.IO.File]::WriteAllText($fixturePath, 'LocalSend 1979 timestamp picker diagnostic', [System.Text.UTF8Encoding]::new($false))
    $expectedTime = [DateTime]::Parse('1979-12-31T23:59:58Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    [System.IO.File]::SetLastWriteTimeUtc($fixturePath, $expectedTime)
    $actualTime = [System.IO.File]::GetLastWriteTimeUtc($fixturePath)
    $fixtureVerified = $actualTime.Ticks -eq $expectedTime.Ticks
    if (-not $fixtureVerified) { throw "Fixture LastWriteTimeUtc mismatch: expected $expectedTime, got $actualTime" }
    $driveLetter = [System.IO.Path]::GetPathRoot($fixturePath).Substring(0, 1)
    $volume = Get-Volume -DriveLetter $driveLetter
    if ($volume.FileSystem -ne 'NTFS') { throw "Fixture volume is $($volume.FileSystem), expected NTFS." }
    if ($SelectionMode -eq 'Folder' -and @(Get-ChildItem -LiteralPath $fixtureDirectory -Force).Count -ne 1) {
      throw "Folder fixture must contain exactly one old file: $fixtureDirectory"
    }
    $selectionPath = if ($SelectionMode -eq 'Folder') { $fixtureDirectory } else { $fixturePath }
    $buttonX = if ($SelectionMode -eq 'Folder') { 200 } else { 80 }

    $driverScript = Join-Path $PSScriptRoot 'windows_dialog_select.ps1'
    if (-not (Test-Path -LiteralPath $driverScript -PathType Leaf)) { throw "Missing dialog driver: $driverScript" }
    $driverStdout = Join-Path $OutputDirectory 'file-dialog-driver.stdout.txt'
    $driverStderr = Join-Path $OutputDirectory 'file-dialog-driver.stderr.txt'
    $report.fileSelection = [ordered]@{
      mode = $SelectionMode
      selectedPath = $selectionPath
      fixture = [ordered]@{
        path = $fixturePath
        directory = $fixtureDirectory
        expectedLastWriteTimeUtc = $expectedTime.ToString('o')
        actualLastWriteTimeUtc = $actualTime.ToString('o')
        size = (Get-Item -LiteralPath $fixturePath).Length
        fileSystem = $volume.FileSystem
        verified = $fixtureVerified
      }
      selectionButtonClientX = $buttonX
      selectionButtonClientY = 85
      selectionButtonClick = $null
      driver = $null
      screenshot = $null
      topLevelAfter = @()
      uiNamesAfter = @()
      outcome = 'unclassified; inspect screenshot and driver result for added selection or No Permission'
    }

    $driverArguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -TargetProcessId {1} -Path "{2}" -Mode {3} -TimeoutSeconds 15' -f $driverScript, $appWindow.Pid, $selectionPath, $SelectionMode
    $driverProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $driverArguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $driverStdout -RedirectStandardError $driverStderr
    Start-Sleep -Milliseconds 500
    $report.fileSelection.selectionButtonClick = [LocalSendReleaseUiProbe.Windows]::ClickClient($appHwnd, $buttonX, 85)
    $driverTimedOut = -not $driverProcess.WaitForExit(22000)
    if ($driverTimedOut) {
      $driverProcess.Kill()
      $driverProcess.WaitForExit()
    }
    $driverText = [System.IO.File]::ReadAllText($driverStdout)
    $driverError = [System.IO.File]::ReadAllText($driverStderr)
    $driverJson = $null
    try { $driverJson = ConvertFrom-Json -InputObject $driverText } catch { }
    $driverProcess.Refresh()
    $driverExitCode = $null
    try { if ($driverProcess.HasExited) { $driverExitCode = $driverProcess.ExitCode } } catch { }
    $report.fileSelection.driver = [ordered]@{
      pid = $driverProcess.Id
      exitCode = $driverExitCode
      timedOut = $driverTimedOut
      reportedSuccess = $driverJson -and $driverJson.Success -eq $true
      stdout = $driverText
      stderr = $driverError
      result = $driverJson
    }
    Start-Sleep -Seconds 2
    $report.fileSelection.topLevelAfter = @([LocalSendReleaseUiProbe.Windows]::All())
    try {
      $fileBitmap = [System.Drawing.Bitmap]::new($appWindow.Width, $appWindow.Height)
      try {
        $fileGraphics = [System.Drawing.Graphics]::FromImage($fileBitmap)
        try {
          $fileHdc = $fileGraphics.GetHdc()
          try {
            $filePrinted = [LocalSendReleaseUiProbe.Windows]::Capture($appHwnd, $fileHdc)
          } finally {
            $fileGraphics.ReleaseHdc($fileHdc)
          }
        } finally {
          $fileGraphics.Dispose()
        }
        if (-not $filePrinted) { throw "PrintWindow returned false after selecting $SelectionMode." }
        $fileBitmap.Save($afterSelectionScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $report.fileSelection.screenshot = [ordered]@{
          path = $afterSelectionScreenshotPath
          bytes = (Get-Item -LiteralPath $afterSelectionScreenshotPath).Length
          sha256 = (Get-FileHash -LiteralPath $afterSelectionScreenshotPath -Algorithm SHA256).Hash
          sendTabSha256 = if (Test-Path -LiteralPath $sendScreenshotPath) { (Get-FileHash -LiteralPath $sendScreenshotPath -Algorithm SHA256).Hash } else { $null }
        }
      } finally {
        $fileBitmap.Dispose()
      }
    } catch {
      $report.errors += "LocalSend after-$SelectionMode PrintWindow capture: $($_.Exception.Message)"
    }
    try {
      $afterFileRoot = [System.Windows.Automation.AutomationElement]::FromHandle($appHwnd)
      $afterFileElements = $afterFileRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($element in $afterFileElements) {
        if ($report.fileSelection.uiNamesAfter.Count -ge 100) { break }
        try {
          $name = [string] $element.Current.Name
          if (-not [string]::IsNullOrWhiteSpace($name)) { $report.fileSelection.uiNamesAfter += $name }
        } catch { }
      }
    } catch { }
    if (@($report.fileSelection.uiNamesAfter | Where-Object { $_ -match '(?i)no permission' }).Count -gt 0) {
      $report.fileSelection.outcome = 'No Permission text found in LocalSend UI Automation tree'
    } elseif (@($report.fileSelection.uiNamesAfter | Where-Object { $_ -like '*fixture-1979-12-31.txt*' }).Count -gt 0) {
      $report.fileSelection.outcome = 'fixture filename found in LocalSend UI Automation tree'
    }
  }

  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw "Invalid virtual screen bounds: $bounds" }
  $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
  try {
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
    } finally {
      $graphics.Dispose()
    }
    $bitmap.Save($screenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $colors = [System.Collections.Generic.HashSet[int]]::new()
    for ($y = 0; $y -lt $bounds.Height; $y += [Math]::Max(1, [int]($bounds.Height / 20))) {
      for ($x = 0; $x -lt $bounds.Width; $x += [Math]::Max(1, [int]($bounds.Width / 20))) {
        [void] $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
      }
    }
    $report.screenshot = [ordered]@{
      path = $screenshotPath
      bytes = (Get-Item -LiteralPath $screenshotPath).Length
      left = $bounds.Left
      top = $bounds.Top
      width = $bounds.Width
      height = $bounds.Height
      sampledDistinctColors = $colors.Count
    }
  } finally {
    $bitmap.Dispose()
  }

  $appPids = @($report.processes | ForEach-Object { [int] $_.pid })
  if ($visible -and $report.foreground -and $report.foreground.Pid -in $appPids) {
    $report.status = 'captured-foreground-app'
  } elseif ($report.windowScreenshot -and $report.windowScreenshot.sampledDistinctColors -gt 1) {
    $report.status = 'captured-app-window'
  } elseif (@($report.appUiTree | Where-Object { -not [string]::IsNullOrWhiteSpace($_.name) }).Count -gt 0) {
    $report.status = 'captured-app-ui-tree'
  } else {
    $report.errors += 'LocalSend was not foreground and PrintWindow did not capture a varied app image; inspect topLevelAfter, appUiTree, and screenshot.'
  }
  if (-not $report.sendTab -or -not $report.sendTab.imageChanged) {
    $report.status = 'inconclusive'
    $report.errors += 'Send tab selection was not verified by a changed LocalSend window image.'
  }
  if (-not $report.fileSelection -or -not $report.fileSelection.selectionButtonClick.Posted -or
      $report.fileSelection.driver.timedOut -or -not $report.fileSelection.driver.reportedSuccess -or
      -not $report.fileSelection.screenshot) {
    $report.status = 'inconclusive'
    $report.errors += "${SelectionMode} selection was not fully driven and captured; inspect fileSelection.driver and the after-selection screenshot."
  } elseif ($report.status -ne 'inconclusive') {
    $report.status = 'selection-dialog-observed'
  }
} catch {
  $report.errors += $_.Exception.ToString()
} finally {
  if ($firewallRuleName) {
    try {
      $rule = Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue
      if ($rule) { Remove-NetFirewallRule -Name $firewallRuleName -ErrorAction Stop }
      if ($report.firewallRule) { $report.firewallRule.removed = $true }
    } catch {
      $report.errors += "Could not remove temporary firewall rule ${firewallRuleName}: $($_.Exception.Message)"
      $report.status = 'inconclusive'
    }
  }
  $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
  [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 10), [System.Text.UTF8Encoding]::new($false))
  Write-Host "Release UI report: $reportPath"
  if ($report.status -ne 'selection-dialog-observed') { exit 1 }
}
