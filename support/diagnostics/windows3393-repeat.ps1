param([string]$Case='picker-calibration')
$ErrorActionPreference='Stop'
$fixture=Join-Path $PWD "evidence/issue3393-$Case.txt"
[System.IO.File]::WriteAllText($fixture,"LocalSend issue3393 $Case unique payload",[System.Text.UTF8Encoding]::new($false))
& "$PSScriptRoot/windows3393-ui.ps1" -Action click -X 318 -Y 423 -Label "windows-$Case-done"
& "$PSScriptRoot/windows3393-ui.ps1" -Action click -X 200 -Y 411 -Label "windows-$Case-send-tab"
$pidInfo=Get-Content "evidence/windows-$Case-send-tab-action.json"|ConvertFrom-Json
$argsLine='-NoProfile -STA -File "{0}" -TargetProcessId {1} -Path "{2}" -Mode File -SelectionMethod PathEntry -DialogScreenshotPath "{3}" -TimeoutSeconds 15' -f "$PSScriptRoot/windows_dialog_select.ps1",$pidInfo.appPid,$fixture,(Join-Path $PWD "evidence/windows-$Case-dialog.png")
$driver=Start-Process pwsh -ArgumentList $argsLine -PassThru -WindowStyle Hidden -RedirectStandardOutput "evidence/windows-$Case-dialog.stdout.txt" -RedirectStandardError "evidence/windows-$Case-dialog.stderr.txt"
Start-Sleep -Milliseconds 500
& "$PSScriptRoot/windows3393-ui.ps1" -Action click -X 80 -Y 85 -Label "windows-$Case-file-button"
if(-not $driver.WaitForExit(22000)){ $driver.Kill();throw 'Repeat file selection timed out' }
$selected=Get-Content "evidence/windows-$Case-dialog.stdout.txt" -Raw|ConvertFrom-Json
if(-not $selected.Success){throw 'Repeat native file selection failed'}
& "$PSScriptRoot/windows3393-ui.ps1" -Action snapshot -Label "windows-$Case-file-selected"
& "$PSScriptRoot/windows3393-ui.ps1" -Action click -X 246 -Y 266 -Label "windows-$Case-favorites"
& "$PSScriptRoot/windows3393-ui.ps1" -Action click -X 145 -Y 225 -Label "windows-$Case-start-send"
