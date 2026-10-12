# Isolated Windows sender observation: no receiver, relay, recipient click or retry.
$ErrorActionPreference='Stop'
if($env:ISSUE2311_SENDER_FAVORITES_QUALIFICATION -ne 'true' -or $env:OS -ne 'Windows_NT' -or
 $env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -ne 'ShlomoCode/localsend'){
 throw 'Sender Favorites qualification runs only in its authorized fork Windows Actions job'
}
$report=[ordered]@{scope='Sender Favorites dialog only; no working transfer claim';utc=[DateTime]::UtcNow.ToString('o');
 receiverAllocated=$false;recipientInputSent=$false;favorite=@{alias='Android15 receiver';ip='127.0.0.1';port=53318};
 fixture=$null;initialIdentity=$null;passed=$false;error=$null}
try{
 $fixture=(Resolve-Path -LiteralPath 'media-fixtures/capture.jpg').Path
 $hash=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
 $bytes=(Get-Item -LiteralPath $fixture).Length
 $report.fixture=@{path=$fixture;sha256=$hash;bytes=$bytes}
 if($bytes -ne 751 -or $hash -cne '900663f3fb8b3f81f7290dfa7cabe6713ff90bd15d60455e093cd09203468e03'){throw 'JPEG fixture differs from the retained immutable 751-byte source'}
 if(@(Get-Process localsend_app -ErrorAction SilentlyContinue).Count -or @(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue).Count){throw 'Sender qualification requires a fresh desktop with no LocalSend process or port owner'}
 & "$PSScriptRoot/windows2311-desktop.ps1"
 & "$PSScriptRoot/windows_release_ui_probe.ps1" -OutputDirectory evidence -ReleaseVersion 1.17.0 -AssetArchitecture x86-64 -RunnerLabel windows-2022 -DiagnosticPeerPort 53318 -SenderStartupOnly
 $release=Get-Content -LiteralPath 'evidence/release-ui-report.json' -Raw|ConvertFrom-Json
 if($release.status -cne 'sender-startup-observed' -or @($release.errors).Count){throw 'Pinned release startup probe was inconclusive or retained setup errors'}
 $processes=@(Get-Process localsend_app -ErrorAction SilentlyContinue)
 if($processes.Count -ne 1 -or $processes[0].Id -ne $release.launchedPid -or !$processes[0].MainWindowHandle){throw 'Startup did not retain one fresh original sender process/window'}
 $senderPid=[uint32]$processes[0].Id;$senderHwnd=$processes[0].MainWindowHandle.ToInt64()
 $deadline=[DateTime]::UtcNow.AddSeconds(10)
 do{
  $listeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess)
  if(@($listeners|Where-Object {$_.OwningProcess -ne $senderPid}).Count){throw 'A foreign process owns the sender port'}
  if($listeners.Count){break}
  Start-Sleep -Milliseconds 250
 }while([DateTime]::UtcNow -lt $deadline)
 $report.initialIdentity=@{pid=$senderPid;hwnd=$senderHwnd;listeners=$listeners;basis='Fresh pinned startup identity; not a working transfer control'}
 if(!$listeners.Count){throw 'Fresh sender did not establish its listener before the native workflow'}
 # Keep the existing context identity filename; its action is explicitly a snapshot.
 & "$PSScriptRoot/windows3393-ui.ps1" -Action snapshot -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -Label 'windows-control-send'
 & "$PSScriptRoot/windows2311-context.ps1" -Case 'sender-pointer' -FixtureSource $fixture -FixtureExtension jpg -QualifyFavoritesPointerOnly
 $report.passed=$true
}catch{$report.error=$_.Exception.Message}
finally{
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
 $report.finalProcesses=@(Get-CimInstance Win32_Process -Filter "Name = 'localsend_app.exe'"|Select-Object ProcessId,ParentProcessId,ExecutablePath,CreationDate)
 $report.finalListeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess)
 $report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'evidence/sender-favorites-qualification.json'
}
if(!$report.passed){throw "Sender Favorites qualification failed; raw boundary evidence retained. $($report.error)"}
