$ErrorActionPreference='Stop'
function Wait-Milestone([string]$Name,[int]$Seconds=90) {
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while(-not (Test-Path "evidence/$Name")) {
  if([DateTime]::UtcNow -gt $deadline){throw "Milestone timeout: $Name"}
  Start-Sleep -Milliseconds 50
 }
}
function Ui([string]$Action,[int]$X,[int]$Y,[string]$Label) {
 & "$PSScriptRoot/2007-windows-ui.ps1" -Action $Action -X $X -Y $Y -Label $Label -RequireForeground -UseControlSequence
}
function Capture-Completed([string]$Label) {
 # The receiver milestone requires saved bytes and a new completed transfer.
 # Windows Flutter exposes only FLUTTERVIEW via UIAutomation on this runner.
 # Retain the original pixels for independent post-run Finished inspection.
 Ui snapshot 0 0 $Label
 @{receiverMilestoneVerified=$true;senderFinishedRequiresVisualInspection=$true;reason='Native UIAutomation exposes FLUTTERVIEW only'}|ConvertTo-Json|Set-Content "evidence/$Label-review.json"
}
$payload="LocalSend issue 2007 original app control v1`nRun: $env:GITHUB_RUN_ID`n"
& "$PSScriptRoot/windows_release_ui_probe.ps1" -OutputDirectory evidence -ReleaseVersion $env:ISSUE_2007_RELEASE -AssetArchitecture x86-64 -RunnerLabel windows-11-arm -FixtureTimestampUtc '2026-10-11T00:00:00Z' -FixtureFileName A.txt -FixtureContent $payload -DiagnosticPeerPort ([int]$env:TRANSPORT_SENDER_PORT)
$report=Get-Content evidence/release-ui-report.json -Raw|ConvertFrom-Json
if(-not $report.fileSelection.driver.reportedSuccess){throw 'Initial native picker failed'}
Ui click 246 266 windows-first-favorites
Ui click 145 205 transfer-requested
New-Item evidence/transfer-requested -ItemType File|Out-Null
Wait-Milestone control-completed
Capture-Completed sender-first-completed
New-Item evidence/sender-first-finished -ItemType File|Out-Null
$fixture=(Resolve-Path evidence/A.txt).Path
$variant=$env:ISSUE_2007_VARIANT
if($variant -eq 'changed') {
 [IO.File]::WriteAllText($fixture,$payload.Replace('control v1','control v2'),[Text.UTF8Encoding]::new($false))
}elseif($variant -eq 'renamed') {
 $newPath=Join-Path $PWD evidence/B.txt
 Copy-Item $fixture $newPath
 $fixture=$newPath
}
@{variant=$variant;path=$fixture;name=[IO.Path]::GetFileName($fixture)}|ConvertTo-Json|Set-Content evidence/resend-input.json
Ui click 318 423 windows-repeat-done
Ui click 200 411 windows-repeat-send-tab
$pidInfo=Get-Content evidence/windows-repeat-send-tab-action.json|ConvertFrom-Json
$argsLine='-NoProfile -STA -File "{0}" -TargetProcessId {1} -Path "{2}" -Mode File -SelectionMethod PathEntry -TimeoutSeconds 15' -f "$PSScriptRoot/windows_dialog_select.ps1",$pidInfo.appPid,$fixture
$driver=Start-Process pwsh -ArgumentList $argsLine -PassThru -WindowStyle Hidden -RedirectStandardOutput evidence/windows-repeat-dialog.stdout.txt -RedirectStandardError evidence/windows-repeat-dialog.stderr.txt
Start-Sleep -Milliseconds 500
Ui click 80 85 windows-repeat-file-button
if(-not $driver.WaitForExit(22000)){$driver.Kill();throw 'Repeat native picker timeout'}
$selected=Get-Content evidence/windows-repeat-dialog.stdout.txt -Raw|ConvertFrom-Json
if(-not $selected.Success){throw 'Repeat native picker failed'}
Ui snapshot 0 0 windows-repeat-selected
Ui click 246 266 windows-repeat-favorites
New-Item evidence/resend-address-ready -ItemType File|Out-Null
Wait-Milestone resend-ready
Ui click 145 225 windows-resend-submission
$action=Get-Content evidence/windows-resend-submission-action.json|ConvertFrom-Json
@{utc=$action.inputUtc;action='Actual click on pre-staged original Windows Favorite';timestamp='Immediately before native PostMessage input sequence'}|ConvertTo-Json|Set-Content evidence/resend-submission.json
New-Item evidence/resend-requested -ItemType File|Out-Null
Wait-Milestone resend-completed
Capture-Completed sender-resend-completed
