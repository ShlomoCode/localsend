param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
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
    $result = [ordered]@{
      case = $name
      processId = $process.Id
      processExited = $process.HasExited
      mainWindowHandle = $process.MainWindowHandle.ToInt64()
      errorTextVisibleToUIAutomation = (($windowText -join "`n") -match "type 'bool' is not a subtype of type 'String\?'")
      settings = if (Test-Path (Join-Path $settingsDirectory 'settings.json')) { Get-Content (Join-Path $settingsDirectory 'settings.json') -Raw } else { $null }
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $caseDirectory 'result.json')
    Write-Host ($result | ConvertTo-Json -Depth 5)
    if ($result.errorTextVisibleToUIAutomation -ne $expectError) {
      throw "Unexpected UI error state in $name"
    }
    if (-not $result.mainWindowHandle) { throw "No LocalSend window in $name" }
  } finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:APPDATA = $originalAppData
  }
}

$environment = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
$environment | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $EvidenceDirectory 'environment.json')
$releaseSettings = Join-Path (Split-Path $Executable) 'settings.json'
if (Test-Path $releaseSettings) { Remove-Item $releaseSettings }
Invoke-Case 'clean-control' @{} $false
Invoke-Case 'legacy-bool-no-version' @{ 'flutter.ls_quick_save' = $true } $true
Invoke-Case 'legacy-bool-version-3' @{ 'flutter.ls_version' = 3; 'flutter.ls_quick_save' = $true } $true
