# Complete the first-run Windows privacy page when it covers the disposable CI desktop.
param([Parameter(Mandatory = $true)][string] $ReportPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$report = [ordered]@{
  status = 'not-present'
  detected = $false
  actions = @()
  visibleNames = @()
  error = $null
}

try {
  $missingAfterAction = 0
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    $elements = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $records = @()
    foreach ($element in $elements) {
      try {
        $current = $element.Current
        if ([string]::IsNullOrWhiteSpace($current.Name)) { continue }
        $records += [pscustomobject]@{
          element = $element
          name = [string] $current.Name
          processId = [int] $current.ProcessId
          controlType = [string] $current.ControlType.ProgrammaticName
          visible = -not $current.IsOffscreen
        }
      } catch { }
    }
    $report.visibleNames = @($records | Where-Object { $_.visible } | Select-Object -First 100 -ExpandProperty name)
    $heading = @($records | Where-Object { $_.visible -and $_.name -like '*Choose privacy settings for your device*' } | Select-Object -First 1)
    if ($heading.Count -eq 0) {
      if ($report.detected -and $missingAfterAction -eq 0) {
        $missingAfterAction = 1
        Start-Sleep -Seconds 1
        continue
      }
      $report.status = if ($report.detected) { 'completed' } else { 'not-present' }
      break
    }
    $missingAfterAction = 0
    $report.detected = $true
    $ownerPid = $heading[0].processId
    $button = @($records | Where-Object {
      $_.visible -and $_.processId -eq $ownerPid -and $_.controlType -eq 'ControlType.Button' -and $_.name -in @('Next', 'Accept')
    } | Select-Object -First 1)
    if ($button.Count -eq 0) { throw 'Windows privacy page is visible but neither Next nor Accept is exposed as a button.' }
    $pattern = $button[0].element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
    $report.actions += "Invoked $($button[0].name) on Windows privacy page through UI Automation"
    Start-Sleep -Milliseconds 600
  }
  if ($report.detected -and $report.status -ne 'completed') {
    throw 'Windows privacy page remained visible after eight button actions.'
  }
} catch {
  $report.status = 'failed'
  $report.error = $_.Exception.ToString()
} finally {
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ReportPath))) | Out-Null
  [System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 5), [System.Text.UTF8Encoding]::new($false))
}

if ($report.status -eq 'failed') { throw $report.error }
