# Launch the official portable LocalSend release on a Windows desktop and capture its UI.
param(
  [string] $OutputDirectory = $env:LS_RELEASE_UI_OUTPUT
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  throw 'Set LS_RELEASE_UI_OUTPUT or pass -OutputDirectory.'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$releaseUrl = 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-arm-64.zip'
$archivePath = Join-Path $OutputDirectory 'LocalSend-1.18.2-windows-arm-64.zip'
$extractPath = Join-Path $OutputDirectory 'release'
$screenshotPath = Join-Path $OutputDirectory 'desktop.png'
$reportPath = Join-Path $OutputDirectory 'release-ui-report.json'
$report = [ordered]@{
  release = 'v1.18.2'
  assetUrl = $releaseUrl
  runner = $env:RUNNER_NAME
  os = [System.Environment]::OSVersion.VersionString
  processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
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
  errors = @()
}

try {
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
  $report.executable = [ordered]@{
    path = $exe.FullName
    bytes = $exe.Length
    version = $exe.VersionInfo.FileVersion
    sha256 = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
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
  public static class Windows {
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
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
          Pid = pid, Hwnd = "0x" + hwnd.ToInt64().ToString("X"), ClassName = cls.ToString(),
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
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  foreach ($window in @($report.topLevelBefore | Where-Object {
    $_.Visible -and $_.Title -match '^(Windows Security|Windows Security Alert|Windows Defender Firewall)$'
  })) {
    $entry = [ordered]@{ hwnd = $window.Hwnd; title = $window.Title; names = @(); matchedFirewall = $false; action = 'none'; closed = $false; error = $null }
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
  } else {
    $report.errors += 'LocalSend was not the foreground window at capture; inspect topLevelAfter and screenshot for firewall or OOBE overlays.'
  }
} catch {
  $report.errors += $_.Exception.ToString()
} finally {
  $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
  [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 10), [System.Text.UTF8Encoding]::new($false))
  Write-Host "Release UI report: $reportPath"
  if ($report.status -ne 'captured-foreground-app') { exit 1 }
}
