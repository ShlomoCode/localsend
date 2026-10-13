# Bounded native COM UIA pattern adapted from retained 3456/ui.ps1.
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot native.cs)
$tlbimp = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows" -Filter TlbImp.exe -Recurse | Select-Object -First 1
if (-not $tlbimp) { throw "ENV_BLOCK: native UIA importer missing" }
$interop = Join-Path $Evidence NativeUIA.dll
& $tlbimp.FullName "$env:WINDIR\System32\UIAutomationCore.dll" /namespace:Issue3536.UIA "/out:$interop" /silent 2>&1 | Out-File (Join-Path $Evidence uia-import.txt)
if ($LASTEXITCODE -ne 0) { throw "ENV_BLOCK: native UIA import failed" }
[Reflection.Assembly]::LoadFrom($interop) | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot controls.cs) -ReferencedAssemblies $interop
function Write-Event($Name,$Data) { @{Utc=[DateTime]::UtcNow.ToString("o");Stage=$script:Stage;Name=$Name;Data=$Data} | ConvertTo-Json -Depth 12 -Compress | Add-Content (Join-Path $Evidence events.jsonl) -Encoding UTF8 }
function Check-Budget { if ([DateTime]::UtcNow -ge $Deadline) { throw "ENV_BLOCK: absolute scenario deadline" } }
function Save-Desktop($Name) {
 $s=[System.Windows.Forms.SystemInformation]::VirtualScreen; $b=[System.Drawing.Bitmap]::new($s.Width,$s.Height);$g=[System.Drawing.Graphics]::FromImage($b)
 try {$g.CopyFromScreen($s.Location,[System.Drawing.Point]::Empty,$s.Size);$b.Save((Join-Path $Evidence "$Name.png"),[System.Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
}
function Assert-App($App,[long]$Hwnd=0) {
 Check-Budget
 $p=Get-Process -Id $App.Id -ErrorAction Stop
 if($p.Path -ne $App.Path -or $p.StartTime.ToUniversalTime().ToString("o") -ne $App.StartUtc){throw "ENV_BLOCK: app PID identity changed"}
 if($Hwnd -eq 0){$Hwnd=$App.Hwnd}
 return [long]$Hwnd
}
function Focus-App($App,[long]$Hwnd=0) {
 $h=Assert-App $App $Hwnd
 if([Tray3166Native]::Iconic([IntPtr]$h)){[Issue3456Native]::ShowWindow([IntPtr]$h,9)|Out-Null};[Issue3456Native]::SetForegroundWindow([IntPtr]$h)|Out-Null
 if([Issue3456Native]::GetForegroundWindow().ToInt64() -ne $h){throw "ENV_BLOCK: owned foreground unavailable"}
 Write-Event foreground @{App=$App;Hwnd=$h};return $h
}
function Snapshot($App,[long]$Hwnd=0) {
 $h=Assert-App $App $Hwnd
 $a=@([Controls3536]::Snapshot($h,$App.Id))
 Write-Event uia @{App=$App;RootHwnd=$h;Controls=$a};return $a
}
function Find-Control($App,$Name,[int]$Type=0,[long]$Hwnd=0,[int]$Seconds=10) {
 $end=[DateTime]::UtcNow.AddSeconds($Seconds)
 do {$a=@(Snapshot $App $Hwnd | Where-Object {$_.Name -eq $Name -and ($Type -eq 0 -or $_.Type -eq $Type)})
 if($a.Count -gt 1){throw "ENV_BLOCK: ambiguous named control $Name"};if($a.Count -eq 1){return $a[0]};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 Save-Desktop "$script:Stage-missing-control";throw "ENV_BLOCK: unavailable named control $Name"
}
function Click-Control($App,$Control,[long]$Hwnd=0) {
 $h=Focus-App $App $Hwnd
 if($Control.Pid -ne $App.Id){throw "ENV_BLOCK: click ownership mismatch"}
 $live=@(Snapshot $App $h|Where-Object {$_.Name -eq $Control.Name -and $_.Type -eq $Control.Type -and $_.Left -eq $Control.Left -and $_.Top -eq $Control.Top -and $_.Right -eq $Control.Right -and $_.Bottom -eq $Control.Bottom})
 if($live.Count -ne 1){throw "ENV_BLOCK: live uniquely bound input target changed"}
 $x=[int](($Control.Left+$Control.Right)/2);$y=[int](($Control.Top+$Control.Bottom)/2)
 if(-not [Issue3456Native]::SetCursorPos($x,$y)){throw "ENV_BLOCK: cursor input failed"}
 if([Issue3456Native]::GetForegroundWindow().ToInt64() -ne $h){throw "ENV_BLOCK: foreground stolen before mouse"}
 Write-Event mouse @{App=$App;Hwnd=$h;Control=$Control;X=$x;Y=$y}
 [Issue3456Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Issue3456Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 300
}
function Click-Name($App,$Name,[int]$Type=0) {Click-Control $App (Find-Control $App $Name $Type)}
function Type-Control($App,$Control,$Text,[long]$Hwnd=0) {
 Click-Control $App $Control $Hwnd
 $h=Assert-App $App $Hwnd
 if([Issue3456Native]::GetForegroundWindow().ToInt64() -ne $h){throw "ENV_BLOCK: foreground stolen before keys"}
 # Clipboard Unicode paste is native user input; the picker must read the exact path back.
 [Clipboard3536]::SetText($Text)
 Write-Event keys @{App=$App;Hwnd=$h;Control=$Control;Text=$Text;Method="Ctrl+A, Unicode clipboard, Ctrl+V"}
 [System.Windows.Forms.SendKeys]::SendWait("^a^v");Start-Sleep -Milliseconds 300
}
function Save-RecorderReceipt {$script:RecorderReceipt|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Evidence "recorder-$script:ClipName.json") -Encoding UTF8}
function Start-Clip($Name) {
 $script:ClipName=$Name;$out=Join-Path $Evidence "$Name.mp4";$resolved=(Get-Command ffmpeg.exe -ErrorAction Stop).Source
 $psi=[System.Diagnostics.ProcessStartInfo]::new($resolved,"-y -f gdigrab -framerate 10 -draw_mouse 1 -i desktop -t 10 -c:v libx264 -threads 2 -preset ultrafast -crf 25 -pix_fmt yuv420p -movflags +frag_keyframe+empty_moov `"$out`"")
 $psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
 $script:Recorder=[System.Diagnostics.Process]::Start($psi);$handle=$script:Recorder.Handle
 $script:RecorderReceipt=@{Pid=$script:Recorder.Id;Path=$script:Recorder.Path;ExpectedPath=$resolved;StartUtc=$script:Recorder.StartTime.ToUniversalTime().ToString("o");ClipPath=$out;MaximumSeconds=10;HandleAcquired=$handle -ne [IntPtr]::Zero;HandleValue=$handle.ToInt64();WaitBoolean=$null;HasExited=$null;ExitCodeValue=$null;ExitCodeType=$null;Finalized=$false;Status="CAPTURING";Errors=@()}
 Save-RecorderReceipt
 $script:RecorderLog=$script:Recorder.StandardError.ReadToEndAsync();Write-Event recording $script:RecorderReceipt;Start-Sleep -Milliseconds 500
}
function Stop-Clip {
 if(-not $script:Recorder){return}
 try{
  if(-not $script:Recorder.HasExited){$script:Recorder.StandardInput.WriteLine("q")}
  $script:RecorderReceipt.WaitBoolean=$script:Recorder.WaitForExit(6000)
  $script:RecorderReceipt.HasExited=$script:Recorder.HasExited
  if(-not $script:RecorderReceipt.WaitBoolean){$script:RecorderReceipt.Status="TIMED_OUT";$script:Recorder.Kill();throw "ENV_BLOCK: recorder failed finite normal stop"}
  $code=$script:Recorder.ExitCode
  if($null -ne $code){$script:RecorderReceipt.ExitCodeType=$code.GetType().FullName;$script:RecorderReceipt.ExitCodeValue=$code}
  if(-not $script:RecorderReceipt.HandleAcquired -or $script:RecorderReceipt.ExitCodeType -ne "System.Int32" -or $code -ne 0){throw "ENV_BLOCK: recorder normal exit unknown or nonzero"}
  $script:RecorderReceipt.Status="EXIT_ZERO";$script:RecorderReceipt.Finalized=$true
  $script:RecorderLog.GetAwaiter().GetResult()|Set-Content (Join-Path $Evidence "$script:ClipName-ffmpeg.txt")
 }catch{$script:RecorderReceipt.Errors+="$_";throw}finally{Save-RecorderReceipt;$script:Recorder=$null}
}
