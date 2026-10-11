param([string]$Executable,[string]$EvidenceDirectory,[int]$Repeat=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Desktop2277 {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int z,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
Start-Transcript "$EvidenceDirectory/transcript.txt"
$script:actions=@()
function Click([int]$x,[int]$y,[string]$label) {
 $script:actions+=@{utc=[DateTime]::UtcNow.ToString('o');action=$label;x=$x;y=$y;foreground=[Desktop2277]::GetForegroundWindow().ToInt64()}
 [Desktop2277]::SetCursorPos($x,$y)|Out-Null
 [Desktop2277]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [Desktop2277]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Screenshot([string]$name) {
 $bmp=New-Object System.Drawing.Bitmap(1000,760)
 $g=[System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen(0,0,0,0,$bmp.Size)
 $bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png)
 $dark=0;$count=0
 for($y=70;$y -lt 710;$y+=8) {for($x=25;$x -lt 975;$x+=8) {$p=$bmp.GetPixel($x,$y);$count++;if($p.R -lt 12 -and $p.G -lt 12 -and $p.B -lt 12){$dark++}}}
 $g.Dispose();$bmp.Dispose()
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
 & 'C:/Program Files/Tesseract-OCR/tesseract.exe' "$EvidenceDirectory/$name.png" "$EvidenceDirectory/$name" -l eng --psm 11 tsv 2> "$EvidenceDirectory/$name-ocr-errors.txt"
 $exitCode=$LASTEXITCODE;$ErrorActionPreference=$previous
 if($exitCode -ne 0){throw 'OCR failed'}
 $script:process.Refresh()
 @{utc=[DateTime]::UtcNow.ToString('o');pid=$script:process.Id;exited=$script:process.HasExited;hwnd=$script:process.MainWindowHandle.ToInt64();foreground=[Desktop2277]::GetForegroundWindow().ToInt64();blackFraction=$dark/$count;words=@(Import-Csv "$EvidenceDirectory/$name.tsv" -Delimiter "`t"|Where-Object{$_.text}|Select-Object -ExpandProperty text)}|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/$name-state.json"
}
function Word([string]$word,[string]$snap) {
 $row=Import-Csv "$EvidenceDirectory/$snap.tsv" -Delimiter "`t"|Where-Object{$_.text -eq $word}|Select-Object -First 1
 if(!$row){throw "Missing OCR word '$word' in $snap"}
 Click ([int]$row.left+[int]$row.width/2) ([int]$row.top+[int]$row.height/2) $word
 Start-Sleep -Milliseconds 800
}
Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture|ConvertTo-Json|Set-Content "$EvidenceDirectory/environment.json"
@{imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;commit=$env:GITHUB_SHA;run=$env:GITHUB_RUN_ID}|ConvertTo-Json|Set-Content "$EvidenceDirectory/runner.json"
Get-FileHash $Executable -Algorithm SHA256|ConvertTo-Json|Set-Content "$EvidenceDirectory/executable.json"
Set-Content "$EvidenceDirectory/payload2277.txt" 'LocalSend issue 2277 exact navigation payload'
$results=@()
$cases=@()
for($trial=1;$trial -le $Repeat;$trial++){foreach($animations in @($false,$true)){$cases+=@{animations=$animations;trial=$trial}}}
foreach($case in $cases) {
 $animations=$case.animations
 $backBefore=@($script:actions|Where-Object{$_.action -eq 'Back-single'}).Count
 $name=if($animations){'animations-on'}else{'animations-off'}
 if($Repeat -gt 1){$name+='-'+$case.trial}
 $folder="$EvidenceDirectory/$name-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 @{'flutter.ls_port'=53317;'flutter.ls_alias'='Bug2277';'flutter.ls_locale'='en';'flutter.ls_enable_animations'=$animations;'flutter.ls_save_window_placement'=$false}|ConvertTo-Json|Set-Content -Encoding UTF8 "$folder/settings.json"
 $env:BUG2277_TRACE="$EvidenceDirectory/$name-route-trace.txt"
 $script:process=Start-Process "$folder/localsend_app.exe" -WorkingDirectory $folder -PassThru
 try {
  Start-Sleep -Seconds 12;$script:process.Refresh()
  if(!$script:process.MainWindowHandle){throw 'No LocalSend window'}
  [Desktop2277]::MoveWindow($script:process.MainWindowHandle,0,0,1000,760,$true)|Out-Null
  [Desktop2277]::SetForegroundWindow($script:process.MainWindowHandle)|Out-Null
  Start-Sleep -Seconds 2;Screenshot "$name-initial"
  $stored=Get-Content "$folder/settings.json" -Raw|ConvertFrom-Json
  @{animations=$stored.'flutter.ls_enable_animations';port=$stored.'flutter.ls_port';locale=$stored.'flutter.ls_locale'}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-profile.json"
  if($stored.'flutter.ls_enable_animations' -ne $animations){throw 'Stored animations setting differs from the case'}
  Word 'Send' "$name-initial";Screenshot "$name-send"
  Word 'Text' "$name-send";Screenshot "$name-text-dialog"
  $prompt=Import-Csv "$EvidenceDirectory/$name-text-dialog.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'message'}|Select-Object -First 1
  if(!$prompt){throw 'Type message dialog missing'}
  Click 500 ([int]$prompt.top+50) 'Text-input-focus'
  [System.Windows.Forms.SendKeys]::SendWait('asdasd')
  Screenshot "$name-text-filled"
  # Confirm bounds x531-616/y434-470 verified in the first retained text-dialog screenshot.
  Click 574 452 'Confirm-text';Start-Sleep -Milliseconds 800
  Start-Sleep -Seconds 2;Screenshot "$name-selected"
  $nearby=Import-Csv "$EvidenceDirectory/$name-selected.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'Nearby'}|Select-Object -First 1
  if(!$nearby){throw 'Selected Send page missing Nearby devices'}
  # The gear at x616 is Send mode; x537 is the separate manual-address action.
  Click 616 ([int]$nearby.top+[int]$nearby.height/2) 'Send-mode-menu'
  Start-Sleep -Milliseconds 800;Screenshot "$name-send-mode-menu"
  Word 'link' "$name-send-mode-menu";Start-Sleep -Seconds 5;Screenshot "$name-web-share"
  # A single click on the Material back arrow, whose location is checked in retained screenshot.
  Click 28 60 'Back-single'
  foreach($delay in @(100,500,1500,5000)) {Start-Sleep -Milliseconds $delay;Screenshot "$name-after-back-$delay"}
  $final=Get-Content "$EvidenceDirectory/$name-after-back-5000-state.json" -Raw|ConvertFrom-Json
  $outcome=if($final.blackFraction -gt 0.95){'black-window'}elseif($final.words -contains 'Selection'){'returned-send'}else{'other-state'}
  $results+=@{case=$name;status='scenario-reached';outcome=$outcome;backCount=(@($script:actions|Where-Object{$_.action -eq 'Back-single'}).Count-$backBefore);pid=$final.pid;hwnd=$final.hwnd;exited=$final.exited;error=$null}
 } catch {$results+=@{case=$name;status='harness-or-app-blocker';error=$_.Exception.ToString()}}
 finally {
  $script:actions|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/inputs.json"
  if(!$script:process.HasExited){Stop-Process -Id $script:process.Id -Force}
  Start-Sleep -Seconds 2
 }
}
$results|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/results.json"
Stop-Transcript
