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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    public static WindowInfo[] ForProcess(int pid) {
      List<WindowInfo> found = new List<WindowInfo>();
      EnumWindows((hwnd, data) => {
        uint owner;
        GetWindowThreadProcessId(hwnd, out owner);
        if (owner != pid) return true;
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

  if ($visible) {
    $report.status = 'captured-visible-app'
  } else {
    $report.errors += 'No visible LocalSend window appeared within 30 seconds; screenshot may show a locked or noninteractive desktop.'
  }
} catch {
  $report.errors += $_.Exception.ToString()
} finally {
  $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
  [System.IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 10), [System.Text.UTF8Encoding]::new($false))
  Write-Host "Release UI report: $reportPath"
  if ($report.status -ne 'captured-visible-app') { exit 1 }
}
