param(
  [Parameter(Mandatory = $true)][string]$AppPath,
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [Parameter(Mandatory = $true)][string]$Label,
  [switch]$ExpectedNative
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PlacementCaptureWin32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr param);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int maxCount);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
public class PlacementCaptureBanner : System.Windows.Forms.Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override System.Windows.Forms.CreateParams CreateParams {
    get { var p = base.CreateParams; p.ExStyle |= 0x08000000; return p; }
  }
}
'@ -ReferencedAssemblies @(
  [System.Windows.Forms.Form].Assembly.Location,
  [System.Drawing.Graphics].Assembly.Location,
  [System.Drawing.Point].Assembly.Location,
  [System.ComponentModel.Component].Assembly.Location,
  'System.Windows.Forms.Primitives',
  'System.Runtime'
)

$app = (Resolve-Path -LiteralPath $AppPath).Path
if ([IO.Path]::GetExtension($app) -ne '.exe') { throw 'AppPath must point to the built Windows .exe.' }
$settingsPath = Join-Path (Split-Path -Parent $app) 'settings.json'
if (Test-Path -LiteralPath $settingsPath) { throw "Refusing to overwrite existing portable settings: $settingsPath. Use a disposable build directory." }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$safeLabel = $Label -replace '[^a-zA-Z0-9_-]', '_'
$videoPath = Join-Path $output 'recording.mp4'
$metadataPath = Join-Path $output "$safeLabel-metadata.json"
$phaseSeconds = 6
$recordSeconds = 30

function Find-AppWindow([int]$pidToFind) {
  $script:foundWindow = [IntPtr]::Zero
  $callback = [PlacementCaptureWin32+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$unused)
    [uint32]$owner = 0
    [void][PlacementCaptureWin32]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -eq $pidToFind -and [PlacementCaptureWin32]::IsWindowVisible($hwnd) -and [PlacementCaptureWin32]::GetWindowTextLength($hwnd) -gt 0) {
      $script:foundWindow = $hwnd
      return $false
    }
    return $true
  }
  [void][PlacementCaptureWin32]::EnumWindows($callback, [IntPtr]::Zero)
  return $script:foundWindow
}

function Get-Bounds([IntPtr]$hwnd) {
  $rect = [PlacementCaptureWin32+RECT]::new()
  if (-not [PlacementCaptureWin32]::GetWindowRect($hwnd, [ref]$rect)) { throw 'GetWindowRect failed.' }
  return @{ x = $rect.Left; y = $rect.Top; width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top }
}

function Save-Desktop([string]$path) {
  $bitmap = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Hide-ConsoleWindows {
  $callback = [PlacementCaptureWin32+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$unused)
    $name = [Text.StringBuilder]::new(128)
    [void][PlacementCaptureWin32]::GetClassName($hwnd, $name, $name.Capacity)
    if ($name.ToString() -in @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')) {
      [void][PlacementCaptureWin32]::ShowWindow($hwnd, 6)
    }
    return $true
  }
  [void][PlacementCaptureWin32]::EnumWindows($callback, [IntPtr]::Zero)
}

function Write-SeedSettings($placement) {
  $seed = [ordered]@{
    'flutter.ls_version' = 3
    'flutter.ls_save_window_placement' = $true
    'flutter.ls_whats_new' = '1.18.0'
    'flutter.ls_locale' = 'en'
    'flutter.ls_window_offset_x' = [double]$placement.x
    'flutter.ls_window_offset_y' = [double]$placement.y
    'flutter.ls_window_width' = [double]$placement.width
    'flutter.ls_window_height' = [double]$placement.height
  }
  [IO.File]::WriteAllText($settingsPath, ($seed | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

function Wait-Until([Diagnostics.Stopwatch]$clock, [double]$seconds) {
  while ($clock.Elapsed.TotalSeconds -lt $seconds) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds ([Math]::Max(10, [Math]::Min(100, [int](($seconds - $clock.Elapsed.TotalSeconds) * 1000))))
  }
}

$width = [Math]::Min(900, [Math]::Max(400, $primary.Width - 120))
$height = [Math]::Min(600, [Math]::Max(500, $primary.Height - 120))
$centerX = $primary.Left + [int](($primary.Width - $width) / 2)
$centerY = $primary.Top + [int](($primary.Height - $height) / 2)
$cases = @(
  @{ name = 'partial-right'; x = $primary.Right - [int]($width / 3); y = $centerY; width = $width; height = $height },
  @{ name = 'partial-left'; x = $primary.Left - [int]($width * 2 / 3); y = $centerY; width = $width; height = $height },
  @{ name = 'partial-top'; x = $centerX; y = $primary.Top - [int]($height / 2); width = $width; height = $height },
  @{ name = 'disconnected-monitor'; x = $screen.Right + 2000; y = $screen.Bottom + 1200; width = $width; height = $height },
  @{ name = 'maximize-minimize-restore'; x = $centerX; y = $centerY; width = $width; height = $height }
)

$metadata = [ordered]@{
  label = $Label; expectedNative = $ExpectedNative; appPath = $app; settingsPath = $settingsPath
  startedUtc = $null; durationSeconds = $recordSeconds; phaseSeconds = $phaseSeconds
  desktop = @{ x = $screen.Left; y = $screen.Top; width = $screen.Width; height = $screen.Height }
  primaryDisplay = @{ x = $primary.Left; y = $primary.Top; width = $primary.Width; height = $primary.Height }
  displays = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { @{ device = $_.DeviceName; primary = $_.Primary; x = $_.Bounds.Left; y = $_.Bounds.Top; width = $_.Bounds.Width; height = $_.Bounds.Height } })
  os = [Environment]::OSVersion.VersionString
  dpi = $null; phases = @(); errors = @()
}
$dpiGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
try { $metadata.dpi = @{ x = $dpiGraphics.DpiX; y = $dpiGraphics.DpiY } } finally { $dpiGraphics.Dispose() }
$appProcess = $null
$warmProcess = $null
$recorder = $null
$banner = New-Object PlacementCaptureBanner
$banner.FormBorderStyle = 'None'
$banner.ShowInTaskbar = $false
$banner.TopMost = $true
$banner.StartPosition = 'Manual'
$banner.Location = [System.Drawing.Point]::new(($screen.Left + 20), ($screen.Top + 20))
$banner.Size = [System.Drawing.Size]::new(650, 56)
$banner.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
$bannerLabel = New-Object System.Windows.Forms.Label
$bannerLabel.Dock = 'Fill'
$bannerLabel.ForeColor = [System.Drawing.Color]::White
$bannerLabel.Font = [System.Drawing.Font]::new('Arial', 16, [System.Drawing.FontStyle]::Bold)
$bannerLabel.TextAlign = 'MiddleLeft'
$banner.Controls.Add($bannerLabel)
try {
  # Warm the same real app and native libraries before the timed capture.
  Write-SeedSettings $cases[4]
  $warmProcess = Start-Process -FilePath $app -WorkingDirectory (Split-Path -Parent $app) -PassThru
  $warmClock = [Diagnostics.Stopwatch]::StartNew()
  $warmWindow = [IntPtr]::Zero
  while ($warmClock.Elapsed.TotalSeconds -lt 20) {
    if ($warmProcess.HasExited) { throw "Warm-up app exited with code $($warmProcess.ExitCode)." }
    $warmWindow = Find-AppWindow $warmProcess.Id
    if ($warmWindow -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 100
  }
  if ($warmWindow -eq [IntPtr]::Zero) { throw 'Warm-up window did not appear within 20 seconds.' }
  Start-Sleep -Seconds 3
  $metadata.warmup = @{ readySeconds = $warmClock.Elapsed.TotalSeconds - 3; renderedSeconds = $warmClock.Elapsed.TotalSeconds }
  $warmProcess.Kill()
  [void]$warmProcess.WaitForExit(2000)
  Hide-ConsoleWindows

  # One raw, full-desktop recording for each build; phase offsets are exact video seconds.
  $ffmpegArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'gdigrab', '-framerate', '15', '-offset_x', "$($screen.Left)", '-offset_y', "$($screen.Top)", '-video_size', "$($screen.Width)x$($screen.Height)", '-i', 'desktop', '-t', "$recordSeconds", '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '20', '-pix_fmt', 'yuv420p', $videoPath)
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  $startInfo.FileName = $ffmpeg
  $startInfo.Arguments = ($ffmpegArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.CreateNoWindow = $true
  $recorder = [Diagnostics.Process]::Start($startInfo)
  if (-not $recorder) { throw 'ffmpeg did not start.' }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $metadata.startedUtc = [DateTime]::UtcNow.ToString('o')
  $banner.Show()

  for ($i = 0; $i -lt $cases.Count; $i++) {
    $case = $cases[$i]
    $startAt = $i * $phaseSeconds
    Wait-Until $clock $startAt
    $bannerLabel.Text = "$Label  |  $($case.name)"
    [System.Windows.Forms.Application]::DoEvents()
    $phase = [ordered]@{ name = $case.name; plannedStartSeconds = $startAt; actualStartSeconds = $clock.Elapsed.TotalSeconds; seeded = $case; actions = @(); readySeconds = $null; actualBounds = $null; savedSettings = $null; screenshot = $null }
    $metadata.phases += $phase
    if ($appProcess -and -not $appProcess.HasExited) {
      $appProcess.Kill()
      [void]$appProcess.WaitForExit(2000)
    }
    # SharedPreferencesPortable writes primitive values directly into this JSON map.
    # Reset the native key for every launch so both builds begin from the same legacy state.
    Write-SeedSettings $case
    $appProcess = Start-Process -FilePath $app -WorkingDirectory (Split-Path -Parent $app) -PassThru
    $hwnd = [IntPtr]::Zero
    while ($clock.Elapsed.TotalSeconds -lt ($startAt + 4.5)) {
      if ($appProcess.HasExited) { throw "App exited during $($case.name) with code $($appProcess.ExitCode)." }
      $hwnd = Find-AppWindow $appProcess.Id
      if ($hwnd -ne [IntPtr]::Zero) { break }
      Start-Sleep -Milliseconds 100
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw "App window did not appear within 4.5 seconds in $($case.name)." }
    $phase.readySeconds = $clock.Elapsed.TotalSeconds
    if ($case.name -eq 'maximize-minimize-restore') {
      [void][PlacementCaptureWin32]::ShowWindow($hwnd, 3)
      $phase.actions += @{ atSeconds = $clock.Elapsed.TotalSeconds; action = 'maximize' }
      Wait-Until $clock ($startAt + 3)
      [void][PlacementCaptureWin32]::ShowWindow($hwnd, 6)
      $phase.actions += @{ atSeconds = $clock.Elapsed.TotalSeconds; action = 'minimize' }
      Wait-Until $clock ($startAt + 4)
      [void][PlacementCaptureWin32]::ShowWindow($hwnd, 9)
      $phase.actions += @{ atSeconds = $clock.Elapsed.TotalSeconds; action = 'restore-to-maximized' }
      Wait-Until $clock ($startAt + 4.5)
      [void][PlacementCaptureWin32]::ShowWindow($hwnd, 1)
      $phase.actions += @{ atSeconds = $clock.Elapsed.TotalSeconds; action = 'show-normal' }
    }
    Wait-Until $clock ($startAt + 5)
    $phase.actualBounds = Get-Bounds $hwnd
    $phase.savedSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $phase.screenshot = Join-Path $output ("$safeLabel-{0:D2}-$($case.name).png" -f $i)
    Save-Desktop $phase.screenshot
    if ($ExpectedNative -and -not $phase.savedSettings.'flutter.ls_windows_window_placement') { throw "Native placement key missing after $($case.name)." }
  }
  Wait-Until $clock $recordSeconds
} catch {
  $metadata.errors += $_.Exception.Message
  throw
} finally {
  if ($warmProcess -and -not $warmProcess.HasExited) { $warmProcess.Kill(); [void]$warmProcess.WaitForExit(2000) }
  if ($appProcess -and -not $appProcess.HasExited) { $appProcess.Kill(); [void]$appProcess.WaitForExit(2000) }
  $banner.Close()
  $banner.Dispose()
  if ($recorder -and -not $recorder.HasExited) {
    try { $recorder.StandardInput.WriteLine('q'); $recorder.StandardInput.Flush() } catch {}
    if (-not $recorder.WaitForExit(10000)) { $recorder.Kill() }
  }
  if (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force }
  $metadata.finishedUtc = [DateTime]::UtcNow.ToString('o')
  $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
}
