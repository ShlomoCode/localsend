$ErrorActionPreference='Stop'
$evidence=Join-Path (Get-Location) 'evidence/2230'
Start-Transcript -Path (Join-Path $evidence 'sender.log')
Add-Type -Path "$PSScriptRoot/native.cs"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$app=$null
$receiver=$null
$currentCase=$null
$sequence=0
function Snapshot([string]$Label) {
  $script:sequence++
  $name=('{0:D3}-{1}' -f $sequence,$Label)
  $w=@([ReceiverNative]::All() | Where-Object { $_.Pid -eq $app.Id -and $_.Visible -and $_.ClassName -ne '#32770' })
  if($w.Count -ne 1) { throw 'No unique visible original Windows application window.' }
  $script:window=$w[0]
  [void][ReceiverNative]::Activate([IntPtr]::new($window.Hwnd))
  Start-Sleep -Milliseconds 200
  $image=Join-Path $evidence ($name+'.png')
  $bitmap=[Drawing.Bitmap]::new($window.Width,$window.Height)
  try {
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($window.Left,$window.Top,0,0,$bitmap.Size) } finally { $graphics.Dispose() }
    $bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Png)
  } finally { $bitmap.Dispose() }
  $json=Join-Path $evidence ($name+'.json')
  $worker=Start-Process "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList @('-NoProfile','-File',('"'+$PSScriptRoot+'/ocr.ps1"'),'-Image',('"'+$image+'"'),'-Result',('"'+$json+'"'),'-DeadlineUtc',[DateTime]::UtcNow.AddSeconds(15).ToString('o')) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $evidence ($name+'-ocr-error.txt')) -RedirectStandardOutput (Join-Path $evidence ($name+'-ocr-output.txt'))
  if(-not $worker.WaitForExit(17000)) { $worker.Kill(); throw 'Native OCR readiness timeout.' }
  $ocr=Get-Content $json -Raw | ConvertFrom-Json
  if($ocr.status -ne 'recognized') { throw ('Native OCR unavailable: '+$ocr.error) }
  $ocr | Add-Member -NotePropertyName window -NotePropertyValue $window
  return $ocr
}
function ClickWord($Ocr,[string]$Text) {
  $match=@($Ocr.words | Where-Object text -CEQ $Text)
  if($match.Count -ne 1) { throw "No unique visible $Text control; inspect retained screenshot." }
  $w=$Ocr.window; $p=$match[0]
  if(-not [ReceiverNative]::ClickScreen([IntPtr]::new($w.Hwnd),[int]($w.Left+$p.x+$p.width/2),[int]($w.Top+$p.y+$p.height/2))) { throw 'Application click failed.' }
  Start-Sleep -Milliseconds 600
}
function ClickIpAddressTab($Ocr) {
  $address=@($Ocr.words | Where-Object text -CEQ 'Address')
  $ip=@($Ocr.words | Where-Object text -CEQ 'IP' | Where-Object {
    $p=$_
    @($address | Where-Object { [Math]::Abs($_.y-$p.y) -lt 5 -and $_.x -gt $p.x -and $_.x -lt $p.x+60 }).Count -eq 1
  })
  if($ip.Count -ne 1) { throw 'No unique rendered IP Address tab; no click.' }
  $w=$Ocr.window; $p=$ip[0]
  if(-not [ReceiverNative]::ClickScreen([IntPtr]::new($w.Hwnd),[int]($w.Left+$p.x+$p.width/2),[int]($w.Top+$p.y+$p.height/2))) { throw 'IP Address tab click failed.' }
  Start-Sleep -Milliseconds 600
}
function ClickTerminalDone($Ocr) {
  $advanced=@($Ocr.words | Where-Object text -CEQ 'Advanced')
  $done=@($Ocr.words | Where-Object text -CEQ 'Done' | Where-Object {
    $p=$_
    @($advanced | Where-Object { [Math]::Abs($_.y-$p.y) -lt 12 -and $_.x -lt $p.x }).Count -eq 1
  })
  if($done.Count -ne 1) { throw 'No unique terminal Done beside Advanced.' }
  $p=$done[0]; $w=$Ocr.window
  if(-not [ReceiverNative]::ClickScreen([IntPtr]::new($w.Hwnd),[int]($w.Left+$p.x+$p.width/2),[int]($w.Top+$p.y+$p.height/2))) { throw 'Terminal Done click failed.' }
  Start-Sleep -Milliseconds 600
}
function SelectFile([string]$Path) {
  $ocr=Snapshot 'select-send'
  ClickWord $ocr 'Send'
  $ocr=Snapshot 'send-page'
  ClickWord $ocr 'File'
  Start-Sleep -Seconds 1
  $dialogs=@([ReceiverNative]::All() | Where-Object { $_.Visible -and $_.ClassName -eq '#32770' -and $_.Pid -eq $app.Id })
  if($dialogs.Count -ne 1) { throw 'Native Windows file picker did not open.' }
  [void][ReceiverNative]::Activate([IntPtr]::new($dialogs[0].Hwnd))
  [Windows.Forms.Clipboard]::SetText($Path)
  [Windows.Forms.SendKeys]::SendWait('%n')
  [Windows.Forms.SendKeys]::SendWait('^v')
  [Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 1
  $ocr=Snapshot 'selected-file'
  if($ocr.text -notmatch 'Files.*1') { throw 'Actual file selection did not show one selected file.' }
}
function SendToReceiver([string]$Ip) {
  $ocr=Snapshot 'target-page'
  $device=@($ocr.words | Where-Object text -CEQ 'Ubuntu2230')
  if($device.Count -eq 1) { ClickWord $ocr 'Ubuntu2230'; return }
  $nearby=@($ocr.words | Where-Object text -CEQ 'Nearby')
  $devices=@($ocr.words | Where-Object text -CEQ 'devices')
  if($nearby.Count -ne 1 -or $devices.Count -ne 1) { throw 'Nearby devices header unavailable.' }
  # Verify the manual icon through its rendered tooltip before clicking it.
  $manualX=[int]($devices[0].x+$devices[0].width+90)
  $manualY=[int]($nearby[0].y+$nearby[0].height/2)
  [Windows.Forms.Cursor]::Position=[Drawing.Point]::new($ocr.window.Left+$manualX,$ocr.window.Top+$manualY)
  Start-Sleep -Seconds 2
  $hover=Snapshot 'manual-tooltip'
  if($hover.text -notmatch 'Manual sending') { throw 'Manual sending tooltip was not verified; no speculative icon click.' }
  [void][ReceiverNative]::ClickScreen([IntPtr]::new($hover.window.Hwnd),$hover.window.Left+$manualX,$hover.window.Top+$manualY)
  Start-Sleep -Milliseconds 600
  $dialog=Snapshot 'address-dialog'
  ClickIpAddressTab $dialog
  $mode=Snapshot 'ip-mode'
  # The retained original dialog places the field between its mode row and Example label.
  $hashtag=@($mode.words | Where-Object text -CEQ 'Hashtag')
  $example=@($mode.words | Where-Object text -CEQ 'Example:')
  if($hashtag.Count -ne 1 -or $example.Count -ne 1 -or $example[0].y-$hashtag[0].y -lt 60 -or $example[0].y-$hashtag[0].y -gt 140) { throw 'Input field anchors were not uniquely rendered.' }
  $fieldX=[int]($mode.window.Left+$example[0].x+100)
  $fieldY=[int]($mode.window.Top+($hashtag[0].y+$hashtag[0].height+$example[0].y)/2)
  if(-not [ReceiverNative]::ClickScreen([IntPtr]::new($mode.window.Hwnd),$fieldX,$fieldY)) { throw 'Native input field click failed.' }
  Start-Sleep -Milliseconds 500
  [ReceiverNative]::FocusState([IntPtr]::new($mode.window.Hwnd)) | Set-Content (Join-Path $evidence ('focus-'+$currentCase+'.txt'))
  if(-not [ReceiverNative]::HasKeyboardFocus([IntPtr]::new($mode.window.Hwnd))) { throw 'Original app does not own keyboard focus; no paste.' }
  [ReceiverNative]::TypeIpv4($Ip)
  Start-Sleep -Milliseconds 500
  $confirmation=Snapshot 'address-filled'
  if($confirmation.text -notmatch [regex]::Escape($Ip)) { throw 'Receiver IP was not visibly entered; no Confirm or Send.' }
  ClickWord $confirmation 'Confirm'
  Start-Sleep -Seconds 1
  [void](Snapshot 'after-send')
}
try {
  $exe=(Get-Content (Join-Path $evidence 'windows-executable.txt') -Raw).Trim()
  $app=Start-Process $exe -PassThru
  Start-Sleep -Seconds 5
  [void](Snapshot 'startup')
  Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | ConvertTo-Json | Set-Content (Join-Path $evidence 'windows-listeners.json')
  $startupDeadline=[DateTime]::UtcNow.AddSeconds(30)
  do {
    $listener=@(Get-NetTCPConnection -State Listen -LocalPort 41631 -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $app.Id)
    if($listener.Count -gt 0) { break }
    Start-Sleep -Seconds 1
  } until([DateTime]::UtcNow -ge $startupDeadline)
  if($listener.Count -eq 0) { throw 'Original Windows application has no owned listener; supported startup gate unmet.' }
  $linuxRoot=(& wsl -d Ubuntu-24.04 -u tester -- wslpath -a (Get-Location).Path.Replace('\','/')).Trim()
  $ip=(& wsl -d Ubuntu-24.04 -u tester -- bash -lc "hostname -I | cut -d' ' -f1").Trim()
  if($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'No valid WSL receiver IPv4 address.' }
  $ip | Set-Content (Join-Path $evidence 'target-ip.txt')
  $manifest=Get-Content C:/2230/manifest.json -Raw | ConvertFrom-Json
  foreach($case in $manifest) {
    $currentCase=$case.id
    # Preserve prior verified files, then restore the same empty Books destination.
    & wsl -d Ubuntu-24.04 -u tester -- bash -lc "mkdir -p /home/tester/2230-verified/$($case.id); find /home/tester/*/Books -maxdepth 1 -type f -exec mv -t /home/tester/2230-verified/$($case.id) -- {} +"
    if($LASTEXITCODE -ne 0) { throw 'Could not preserve preceding received files.' }
    # Arm the actual receiver UI before performing the real sender action.
    $guestArgs=@('-d','Ubuntu-24.04','-u','tester','--','bash',"$linuxRoot/support/diagnose_2230/receiver_control.sh","$linuxRoot/evidence/2230",$case.id,$case.bytes,$case.sha256)
    $receiver=Start-Process wsl.exe -ArgumentList $guestArgs -PassThru -NoNewWindow
    # Keep the native handle while the process runs so PowerShell can read its exit code.
    $receiverHandle=$receiver.Handle
    SelectFile $case.path
    SendToReceiver $ip
    if(-not $receiver.WaitForExit(330000)) { $receiver.Kill(); throw 'Receiver UI/control deadline expired.' }
    [void](Snapshot ($case.id+'-terminal'))
    $receiver.Refresh()
    $receiver.ExitCode | Set-Content (Join-Path $evidence ('controller-exit-'+$case.id+'.txt'))
    $resultPath=Join-Path $evidence ('cases/'+$case.id+'/receiver/result.env')
    if(-not (Test-Path $resultPath)) { throw 'Receiver did not retain a completed result.' }
    $result=Get-Content $resultPath
    $verified=($result -contains 'status=finished_and_hash_verified') -and ($result -contains 'accepted=1') -and ($result -contains 'finished=1') -and ($result -contains 'hash_match=1') -and ($result -contains 'recovery=home_rendered') -and ($result -contains 'video_validation_ok=1')
    if(-not $verified) { throw 'Actual app case lacks complete receiver evidence; inspect result before further input.' }
    $ocr=Snapshot 'return-home'
    ClickTerminalDone $ocr
  }
} catch {
  $_.Exception.ToString() | Set-Content (Join-Path $evidence 'sender-error.txt')
  throw
} finally {
  if($receiver -and -not $receiver.HasExited -and $currentCase) {
    & wsl -d Ubuntu-24.04 -u tester -- timeout 180 bash "$linuxRoot/support/diagnose_2230/cleanup_controller.sh" "$linuxRoot/evidence/2230" $currentCase
    if(-not $receiver.WaitForExit(10000)) {
      'WSL controller process did not finish after bounded Linux cleanup; inspect recording-closed.tsv.' | Set-Content (Join-Path $evidence 'cleanup-error.txt')
      $receiver.Kill()
    }
  }
  if($app -and -not $app.HasExited) { Stop-Process -Id $app.Id }
  Stop-Transcript
}
