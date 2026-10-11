param([string]$Executable,[string]$EvidenceDirectory,[int]$Repeat=1,[string]$TextPayload='123456',[switch]$VideoSequence)
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
Get-ChildItem (Split-Path $Executable) -Filter *.dll|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json|Set-Content "$EvidenceDirectory/native-libraries.json"
Get-ChildItem (Join-Path (Split-Path $Executable) 'data') -Recurse -Filter app.so|Get-FileHash -Algorithm SHA256|ConvertTo-Json|Set-Content "$EvidenceDirectory/dart-aot.json"
Set-Content "$EvidenceDirectory/payload2277.txt" 'LocalSend issue 2277 exact navigation payload'
$results=@()
$cases=@()
for($trial=1;$trial -le $Repeat;$trial++){foreach($animations in @($false,$true)){if(!$VideoSequence -or !$animations){$cases+=@{animations=$animations;trial=$trial}}}}
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
  Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-listeners-initial.json"
  $stored=Get-Content "$folder/settings.json" -Raw|ConvertFrom-Json
  @{animations=$stored.'flutter.ls_enable_animations';port=$stored.'flutter.ls_port';locale=$stored.'flutter.ls_locale'}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-profile.json"
  if($stored.'flutter.ls_enable_animations' -ne $animations){throw 'Stored animations setting differs from the case'}
  Word 'Send' "$name-initial";Screenshot "$name-send"
  Word 'Text' "$name-send";Screenshot "$name-text-dialog"
  $prompt=Import-Csv "$EvidenceDirectory/$name-text-dialog.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'message'}|Select-Object -First 1
  if(!$prompt){throw 'Type message dialog missing'}
  Click 500 ([int]$prompt.top+50) 'Text-input-focus'
  $script:actions+=@{utc=[DateTime]::UtcNow.ToString('o');action='Type-text';text=$TextPayload;foreground=[Desktop2277]::GetForegroundWindow().ToInt64()}
  [System.Windows.Forms.SendKeys]::SendWait($TextPayload)
  Screenshot "$name-text-filled"
  # Confirm bounds x531-616/y434-470 verified in the first retained text-dialog screenshot.
  Click 574 452 'Confirm-text';Start-Sleep -Milliseconds 800
  Start-Sleep -Seconds 2;Screenshot "$name-selected"
  $nearby=Import-Csv "$EvidenceDirectory/$name-selected.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'Nearby'}|Select-Object -First 1
  if(!$nearby){throw 'Selected Send page missing Nearby devices'}
  # The gear at x616 is Send mode; x537 is the separate manual-address action.
  Click 616 ([int]$nearby.top+[int]$nearby.height/2) 'Send-mode-menu'
  Start-Sleep -Milliseconds 800;Screenshot "$name-send-mode-menu"
  Word 'Share' "$name-send-mode-menu";Start-Sleep -Seconds 5;Screenshot "$name-web-share"
  if($VideoSequence) {
   $rows=Import-Csv "$EvidenceDirectory/$name-web-share.tsv" -Delimiter "`t"
   $auto=$rows|Where-Object{$_.text -eq 'Automatically'}|Select-Object -First 1
   $request=$rows|Where-Object{$_.text -eq 'requests' -and [Math]::Abs([int]$_.top-[int]$auto.top) -lt 8}|Select-Object -First 1
   if(!$auto -or !$request){throw 'Cannot locate auto accept checkbox'}
   Click ([int]$request.left+[int]$request.width+26) ([int]$auto.top+[int]$auto.height/2) 'Enable-auto-accept-first-visit'
   Start-Sleep -Milliseconds 800;Screenshot "$name-web-share-auto-accept"
  }
  # A single click on the Material back arrow, whose location is checked in retained screenshot.
  Click 28 60 'Back-single'
  foreach($delay in @(100,500,1500,5000)) {Start-Sleep -Milliseconds $delay;Screenshot "$name-after-back-$delay"}
  $final=Get-Content "$EvidenceDirectory/$name-after-back-5000-state.json" -Raw|ConvertFrom-Json
  Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-listeners-final.json"
  $outcome=if($final.blackFraction -gt 0.95){'black-window'}elseif($final.words -contains 'Selection'){'returned-send'}else{'other-state'}
  $results+=@{case=$name;status='scenario-reached';outcome=$outcome;backCount=(@($script:actions|Where-Object{$_.action -eq 'Back-single'}).Count-$backBefore);pid=$final.pid;hwnd=$final.hwnd;exited=$final.exited;error=$null}
  if($VideoSequence) {
   if($outcome -ne 'returned-send'){throw 'Video sequence off visit did not return to Send'}
   $before="$name-after-back-5000"
   $name='live-animations-on-'+$case.trial
   $backBefore=@($script:actions|Where-Object{$_.action -eq 'Back-single'}).Count
   Word 'Settings' $before
   $animationRow=$null
   for($scroll=0;$scroll -lt 5;$scroll++) {
    Screenshot "$name-settings-$scroll"
    $animationRow=Import-Csv "$EvidenceDirectory/$name-settings-$scroll.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'Animations'}|Select-Object -First 1
    if($animationRow){break}
    $script:actions+=@{utc=[DateTime]::UtcNow.ToString('o');action='Scroll-settings';foreground=[Desktop2277]::GetForegroundWindow().ToInt64()}
    [Desktop2277]::SetCursorPos(700,600)|Out-Null
    [Desktop2277]::mouse_event(2048,0,0,4294966936,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 600
   }
   if(!$animationRow){throw 'Animations setting not visible'}
   # Center of the 150px settings control column at this retained 1000px window.
   Click 821 ([int]$animationRow.top+[int]$animationRow.height/2) 'Enable-animations-live'
   Start-Sleep -Seconds 2;Screenshot "$name-settings-enabled"
   $stored=Get-Content "$folder/settings.json" -Raw|ConvertFrom-Json
   if($stored.'flutter.ls_enable_animations' -ne $true){throw 'Live animation toggle did not persist'}
   @{animations=$stored.'flutter.ls_enable_animations';pid=$script:process.Id;hwnd=$script:process.MainWindowHandle.ToInt64()}|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-profile.json"
   Word 'Receive' "$name-settings-enabled";Screenshot "$name-receive"
   Word 'Send' "$name-receive";Screenshot "$name-selected"
   $nearby=Import-Csv "$EvidenceDirectory/$name-selected.tsv" -Delimiter "`t"|Where-Object{$_.text -eq 'Nearby'}|Select-Object -First 1
   if(!$nearby){throw 'Retained Send selection missing'}
   Click 616 ([int]$nearby.top+[int]$nearby.height/2) 'Send-mode-menu'
   Start-Sleep -Milliseconds 800;Screenshot "$name-send-mode-menu"
   Word 'Share' "$name-send-mode-menu";Start-Sleep -Seconds 5;Screenshot "$name-web-share"
   Click 28 60 'Back-single'
   foreach($delay in @(100,500,1500,5000)){Start-Sleep -Milliseconds $delay;Screenshot "$name-after-back-$delay"}
   $final=Get-Content "$EvidenceDirectory/$name-after-back-5000-state.json" -Raw|ConvertFrom-Json
   Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-listeners-final.json"
   $outcome=if($final.blackFraction -gt 0.95){'black-window'}elseif($final.words -contains 'Selection'){'returned-send'}else{'other-state'}
   $results+=@{case=$name;status='scenario-reached';outcome=$outcome;backCount=(@($script:actions|Where-Object{$_.action -eq 'Back-single'}).Count-$backBefore);pid=$final.pid;hwnd=$final.hwnd;exited=$final.exited;error=$null}
  }
 } catch {$results+=@{case=$name;status='harness-or-app-blocker';error=$_.Exception.ToString()}}
 finally {
  $script:actions|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/inputs.json"
  if(!$script:process.HasExited){Stop-Process -Id $script:process.Id -Force}
  Start-Sleep -Seconds 2
 }
}
$results|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/results.json"
Stop-Transcript
