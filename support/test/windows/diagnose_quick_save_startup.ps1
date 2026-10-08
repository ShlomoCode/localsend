param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
  [bool]$ExpectLegacyError = $true
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WindowCapture {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect bounds);
}
'@
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null

function Save-Screenshot([string]$path) {
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Save-WindowScreenshot([IntPtr]$window, [string]$path) {
  $bounds = New-Object WindowCapture+Rect
  if (-not [WindowCapture]::GetWindowRect($window, [ref]$bounds)) { throw 'Could not measure LocalSend window' }
  $width = $bounds.Right - $bounds.Left
  $height = $bounds.Bottom - $bounds.Top
  if ($width -lt 300 -or $height -lt 300) { throw "Unexpected LocalSend window size $width x $height" }
  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $homePixel = $bitmap.GetPixel([int]($width / 2), [int]($height / 3))
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
  return [ordered]@{
    left = $bounds.Left
    top = $bounds.Top
    width = $width
    height = $height
    homeLogoPixel = [ordered]@{ red = $homePixel.R; green = $homePixel.G; blue = $homePixel.B }
    homeLogoVisible = ($homePixel.R -lt 80 -and $homePixel.G -lt 150 -and $homePixel.B -lt 150)
  }
}

function Get-WindowText([int]$processId) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($window in $windows) {
    if ($window.Current.ProcessId -ne $processId) { continue }
    $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($element in $elements) {
      $name = $element.Current.Name
      if ($name) { $lines.Add($name) }
    }
  }
  return $lines
}

function Invoke-Case([string]$name, [hashtable]$settings, [bool]$expectError) {
  $caseDirectory = Join-Path $EvidenceDirectory $name
  $appData = Join-Path $caseDirectory 'AppData\Roaming'
  $settingsDirectory = Join-Path $appData 'LocalSend'
  New-Item -ItemType Directory -Force $settingsDirectory | Out-Null
  if ($settings) {
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $settingsDirectory 'settings.json')
  }
  $originalAppData = $env:APPDATA
  $env:APPDATA = $appData
  $process = $null
  try {
    $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru
    Start-Sleep -Seconds 15
    $process.Refresh()
    $windowText = @(Get-WindowText $process.Id)
    $windowText | Set-Content -Encoding UTF8 (Join-Path $caseDirectory 'window-text.txt')
    Save-Screenshot (Join-Path $caseDirectory 'desktop.png')
    if (-not $process.MainWindowHandle) { throw "No LocalSend window in $name" }
    $windowBounds = Save-WindowScreenshot $process.MainWindowHandle (Join-Path $caseDirectory 'app-window.png')
    $tesseract = 'C:\Program Files\Tesseract-OCR\tesseract.exe'
    if (-not (Test-Path $tesseract)) { throw 'Tesseract installation missing' }
    $ocrOutput = Join-Path $caseDirectory 'app-window-ocr.txt'
    $ocrError = Join-Path $caseDirectory 'app-window-ocr-stderr.txt'
    $ocrProcess = Start-Process -FilePath $tesseract -ArgumentList @((Join-Path $caseDirectory 'app-window.png'), 'stdout', '-l', 'eng', '--psm', '11') -RedirectStandardOutput $ocrOutput -RedirectStandardError $ocrError -NoNewWindow -Wait -PassThru
    if ($ocrProcess.ExitCode -ne 0) { throw "Tesseract failed in $name with exit code $($ocrProcess.ExitCode)" }
    $ocrText = Get-Content $ocrOutput -Raw
    $settingsFile = Join-Path $settingsDirectory 'settings.json'
    $stored = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw | ConvertFrom-Json } else { $null }
    $storedQuickSave = if ($stored) { $stored.'flutter.ls_quick_save' } else { $null }
    $errorVisible = $ocrText -match '(?is)bool.*not a sub.*type'
    $result = [ordered]@{
      case = $name
      processId = $process.Id
      processExited = $process.HasExited
      mainWindowHandle = $process.MainWindowHandle.ToInt64()
      windowBounds = $windowBounds
      homeLogoVisible = $windowBounds.homeLogoVisible
      errorTextVisibleInOCR = $errorVisible
      cleanHomeVisibleInOCR = ($ocrText -match '(?i)receive')
      storedVersion = if ($stored) { $stored.'flutter.ls_version' } else { $null }
      storedQuickSaveType = if ($null -ne $storedQuickSave) { $storedQuickSave.GetType().Name } else { $null }
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $caseDirectory 'result.json')
    Write-Host ($result | ConvertTo-Json -Depth 5)
    if ($result.errorTextVisibleInOCR -ne $expectError) {
      throw "Unexpected UI error state in $name"
    }
    if (-not $expectError -and -not $result.homeLogoVisible) { throw "LocalSend home screen not visible in $name" }
  } finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path $appData) { Remove-Item $appData -Recurse -Force }
    $env:APPDATA = $originalAppData
  }
}

$environment = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
$environment | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $EvidenceDirectory 'environment.json')
$releaseSettings = Join-Path (Split-Path $Executable) 'settings.json'
if (Test-Path $releaseSettings) { Remove-Item $releaseSettings }
Invoke-Case 'clean-control' @{} $false
Invoke-Case 'legacy-bool-no-version' @{ 'flutter.ls_quick_save' = $true } $ExpectLegacyError
Invoke-Case 'legacy-bool-version-3' @{ 'flutter.ls_version' = 3; 'flutter.ls_quick_save' = $true } $ExpectLegacyError
