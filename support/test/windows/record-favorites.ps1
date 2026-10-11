param([string]$Executable,[string]$CandidateExecutable,[bool]$ReverseFavorites=$false,[bool]$FallbackControl=$false,[bool]$DistinctOnly=$false,[string]$EvidenceDirectory,[string]$Ffmpeg)
$ErrorActionPreference = "Stop"
if($FallbackControl) {
 if(-not $CandidateExecutable) {throw "Fallback control requires the verified candidate build"}
 $Executable=$CandidateExecutable
 $CandidateExecutable=""
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Desktop2381 {
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int left,top,right,bottom;}
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect rect);
 [StructLayout(LayoutKind.Sequential)] public struct WindowPoint {public int x,y;}
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(WindowPoint point);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,System.Text.StringBuilder value,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h,uint message,IntPtr wParam,string value);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h,uint message,IntPtr wParam,System.Text.StringBuilder value);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder value,int size);
 public static string NativeFilename(string value) {
  var h=WindowFromPoint(new WindowPoint {x=400,y=442});
  var name=new System.Text.StringBuilder(128);GetClassName(h,name,name.Capacity);
  if(name.ToString()!="Edit") throw new Exception("Filename point is not a native Edit control: "+name);
  SendMessage(h,12,IntPtr.Zero,value);
  // GetWindowText cannot retrieve another process's Edit contents. WM_GETTEXT
  // is the documented cross-process control-text API and returns displayed text.
  var actual=new System.Text.StringBuilder(2048);SendMessage(h,13,(IntPtr)actual.Capacity,actual);
  return actual.ToString();
 }
 [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] public struct MouseInput {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] public struct InputUnion {[FieldOffset(0)] public KeyboardInput keyboard;[FieldOffset(0)] public MouseInput mouse;}
 [StructLayout(LayoutKind.Sequential)] public struct Input {public uint type;public InputUnion union;}
 [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint count,Input[] inputs,int size);
 public static void Text(string value) {
  foreach(char character in value) {
   var input = new Input {type=1,union=new InputUnion {keyboard=new KeyboardInput {scan=character,flags=4}}};
   if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1) throw new Exception("SendInput Unicode key down failed");
   System.Threading.Thread.Sleep(80);
   input.union.keyboard.flags=6;
   if(SendInput(1,new[]{input},Marshal.SizeOf(typeof(Input)))!=1) throw new Exception("SendInput Unicode key up failed");
   System.Threading.Thread.Sleep(80);
  }
 }
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int z,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
}
"@
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
Start-Transcript "$EvidenceDirectory/transcript.txt"
function Screenshot([string]$name) {
 $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
 $bmp = New-Object System.Drawing.Bitmap(992,720)
 $g = [System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen(0,0,0,0,$bmp.Size)
 $path = "$EvidenceDirectory/$name.png"
 $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
 @{screenshot=$name;timestampUtc=(Get-Date).ToUniversalTime().ToString("o")} | ConvertTo-Json | Set-Content "$EvidenceDirectory/$name-observation.json"
 $g.Dispose()
 $scaled = New-Object System.Drawing.Bitmap(1984,1440)
 $sg = [System.Drawing.Graphics]::FromImage($scaled)
 $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
 # OCR-only grayscale/threshold transformation; original screenshot is untouched.
 $matrix=New-Object System.Drawing.Imaging.ColorMatrix
 $matrix.Matrix00=0.299; $matrix.Matrix01=0.299; $matrix.Matrix02=0.299
 $matrix.Matrix10=0.587; $matrix.Matrix11=0.587; $matrix.Matrix12=0.587
 $matrix.Matrix20=0.114; $matrix.Matrix21=0.114; $matrix.Matrix22=0.114
 $attributes=New-Object System.Drawing.Imaging.ImageAttributes
 $attributes.SetColorMatrix($matrix)
 $attributes.SetThreshold(0.75)
 $rect=New-Object System.Drawing.Rectangle -ArgumentList 0,0,1984,1440
 $sg.DrawImage($bmp,$rect,0,0,992,720,[System.Drawing.GraphicsUnit]::Pixel,$attributes)
 $scaled.Save("$EvidenceDirectory/$name-ocr.png",[System.Drawing.Imaging.ImageFormat]::Png)
 $attributes.Dispose(); $sg.Dispose(); $scaled.Dispose(); $bmp.Dispose()

 # Tesseract emits benign clipping warnings for content at a scroll viewport edge.
 $previousPreference=$ErrorActionPreference
 $ErrorActionPreference="Continue"
 & "C:/Program Files/Tesseract-OCR/tesseract.exe" $EvidenceDirectory/$name-ocr.png "$EvidenceDirectory/$name" -l eng --psm 11 tsv 2> "$EvidenceDirectory/$name-ocr-error.txt"
 $ocrExit=$LASTEXITCODE
 $ErrorActionPreference=$previousPreference
 if ($ocrExit -ne 0) {throw "OCR failed for $name with exit $ocrExit"}
 Import-Csv "$EvidenceDirectory/$name.tsv" -Delimiter "`t" | Where-Object {$_.text} | Select-Object left,top,width,height,text | Format-Table | Out-String | Write-Host
}
function Click([int]$x,[int]$y) {
 Write-Host "INPUT click x=$x y=$y utc=$((Get-Date).ToUniversalTime().ToString('o'))"
 [Desktop2381]::SetCursorPos($x,$y) | Out-Null
 [Desktop2381]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [Desktop2381]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 800
}
function Paste([string]$value) {
 # Native Unicode keyboard events avoid modifier loss in the legacy SendKeys backend.
 [Desktop2381]::Text($value)
 Start-Sleep -Milliseconds 600
}
function FillNativeFilename([string]$path,[string]$snapshot) {
 # Use the native file picker's standard edit-control API. Read back the exact
 # displayed value before clicking real Open; keyboard focus can lose D:.
 Click 400 442
 $point=New-Object System.Windows.Point -ArgumentList 400,442
 $element=[System.Windows.Automation.AutomationElement]::FromPoint($point)
 $pattern=$null
 for($level=0;$level -lt 4 -and $element;$level++) {
  if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) {break}
  $element=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
 }
 $fullPath=(Resolve-Path $path).Path
 if($pattern) {
  $pattern.SetValue($fullPath)
  Start-Sleep -Milliseconds 500
  $actual=$pattern.Current.Value
  $inputApi="native UI Automation ValuePattern"
 } else {
  # Some hosted native dialogs expose no UI Automation ValuePattern. The
  # documented Win32 Edit-control API provides the same input/readback action.
  $actual=[Desktop2381]::NativeFilename($fullPath)
  $inputApi="native Win32 Edit WM_SETTEXT/WM_GETTEXT (class verified)"
 }
 @{inputApi=$inputApi;requested=$fullPath;displayed=$actual;timestampUtc=(Get-Date).ToUniversalTime().ToString("o")} | ConvertTo-Json | Set-Content "$EvidenceDirectory/$snapshot-filename-input.json"
 if($actual -cne $fullPath) {throw "Native filename control did not retain the exact fixture path"}
}
function Word([string]$word,[string]$snap) {
 $rows = Import-Csv "$EvidenceDirectory/$snap.tsv" -Delimiter "`t"
 $row = $rows | Where-Object { $_.text -eq $word } | Select-Object -First 1
 if (-not $row) {
  if ($word -eq "Cancel" -and $snap -eq "add-after-long-list") {
   # Actual current Add dialog Cancel visually verified in run 38133568384
   # at x448-491/y548-561 when OCR omits its teal text.
   Click 470 554
   return
  }
  if ($word -eq "Cancel" -and $snap -like "*favorites*") {
   # Two-row Favorites Cancel verified at x474-524/y477-495, including the wider exact-name dialog.
   $favoriteCount=@((Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json).'flutter.ls_favorites').Count
   Click 500 (485+28*[Math]::Max(0,$favoriteCount-2))
   return
  }
  if ($word -eq "Cancel" -and $snap -like "edit-confirmed*") {
   # Actual Edit dialog Cancel verified at x446-492/y574-590.
   Click 469 582
   return
  }
  throw "OCR word $word missing from $snap"
 }
 Click (([int]$row.left + [int]$row.width/2)/2) (([int]$row.top + [int]$row.height/2)/2)
}
function PrimaryButton([string]$snap) {
 $bmp = [System.Drawing.Bitmap]::FromFile("$EvidenceDirectory/$snap.png")
 $minX=992; $maxX=0; $minY=720; $maxY=0; $count=0
 for ($y=180;$y -lt 710;$y++) {
  $runStart=-1
  for ($x=450;$x -lt 800;$x++) {
   $pixel=$bmp.GetPixel($x,$y)
   if ($pixel.R -lt 30 -and $pixel.G -gt 80 -and $pixel.G -lt 145 -and $pixel.B -gt 60 -and $pixel.B -lt 140) {
    if($runStart -lt 0) {$runStart=$x}
   } else {
    if($runStart -ge 0 -and $x-$runStart -ge 60) {
     $minX=[Math]::Min($minX,$runStart);$maxX=[Math]::Max($maxX,$x-1)
     $minY=[Math]::Min($minY,$y);$maxY=[Math]::Max($maxY,$y);$count+=$x-$runStart
    }
    $runStart=-1
   }
  }
 }
 $bmp.Dispose()
 if ($count -lt 150) {throw "Primary filled button unavailable in $snap"}
 Write-Host "Primary button in ${snap}: $minX,$minY to $maxX,$maxY"
 Click (($minX+$maxX)/2) (($minY+$maxY)/2)
}
function FavoritePencil([string]$snap,[int]$rowY) {
 $bmp=[System.Drawing.Bitmap]::FromFile("$EvidenceDirectory/$snap.png")
 $rightmost=0
 for($y=$rowY-10;$y -le $rowY+10;$y++) {
  for($x=540;$x -lt 620;$x++) {
   $pixel=$bmp.GetPixel($x,$y)
   if($pixel.R -lt 70 -and $pixel.G -lt 85 -and $pixel.B -lt 85) {$rightmost=[Math]::Max($rightmost,$x)}
  }
 }
 $bmp.Dispose()
 if($rightmost -eq 0) {throw "No favorite pencil in $snap row $rowY"}
 Write-Host "Favorite pencil right edge in ${snap}: $rightmost"
 Click ($rightmost-8) $rowY
}
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture | ConvertTo-Json | Set-Content "$EvidenceDirectory/environment.json"
@{imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;architecture=$env:RUNNER_ARCH;run=$env:GITHUB_RUN_ID;virtualScreen=[string][System.Windows.Forms.SystemInformation]::VirtualScreen} | ConvertTo-Json | Set-Content "$EvidenceDirectory/runner.json"
Get-FileHash $Executable -Algorithm SHA256 | ConvertTo-Json | Set-Content "$EvidenceDirectory/executable-hash.json"
Get-ChildItem (Split-Path $Executable) -Recurse -File | Where-Object {$_.Extension -in @('.exe','.dll','.so')} | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content "$EvidenceDirectory/binary-hashes.json"
foreach($marker in @('source-commit.txt','candidate-diff.txt')) {
 $markerPath=Join-Path (Split-Path $Executable) $marker
 if(Test-Path $markerPath) {Copy-Item $markerPath "$EvidenceDirectory/$marker"}
}
$apps=@{}
foreach($item in @(@{name='receiver';port=53317},@{name='sender';port=53318})) {
 $folder="$EvidenceDirectory/$($item.name)-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 @{ 'flutter.ls_port'=$item.port; 'flutter.ls_alias'=$item.name; 'flutter.ls_locale'='en'; 'flutter.ls_https'=$false; 'flutter.ls_save_window_placement'=$false; 'flutter.ls_whats_new'='1.18.2' } | ConvertTo-Json | Set-Content -Encoding UTF8 "$folder/settings.json"
 $p=Start-Process "$folder/localsend_app.exe" -WorkingDirectory $folder -PassThru
 Start-Sleep -Seconds 10
 $p.Refresh()
 if(!$p.MainWindowHandle) {throw "Missing $($item.name) window"}
 [Desktop2381]::MoveWindow($p.MainWindowHandle,0,0,1000,760,$true) | Out-Null
 [Desktop2381]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
 $apps[$item.name]=$p
}
$sender=$apps.sender
$chapters=New-Object System.Collections.ArrayList
$psi=New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName=$Ffmpeg
$psi.Arguments="-y -loglevel error -f gdigrab -framerate 20 -draw_mouse 1 -offset_x 0 -offset_y 0 -video_size 1000x760 -i desktop -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p `"$EvidenceDirectory/raw.mp4`""
$psi.UseShellExecute=$false
$psi.RedirectStandardInput=$true
$capture=New-Object System.Diagnostics.Process
$capture.StartInfo=$psi
$capture.Start() | Out-Null
$started=Get-Date
function Chapter([string]$caption) {
 $chapters.Add(@{start=((Get-Date)-$started).TotalSeconds;caption=$caption}) | Out-Null
 Write-Host "CHAPTER $caption"
 Start-Sleep -Seconds 2
}
function Snap([string]$name) { Screenshot $name; Start-Sleep -Seconds 1 }
function Esc { [System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Start-Sleep -Milliseconds 800 }
function Field([string]$label,[string]$snapshot,[string]$value) {
 $row=Import-Csv "$EvidenceDirectory/$snapshot.tsv" -Delimiter "`t" | Where-Object {$_.text -eq $label} | Select-Object -First 1
 if(!$row) {throw "Field label $label unavailable in $snapshot"}
 Click 500 (([int]$row.top+[int]$row.height)/2+32)
 [System.Windows.Forms.SendKeys]::SendWait('{HOME}{DELETE 80}')
 Paste $value
}
function Scroll([bool]$down,[int]$count=16) {
 [Desktop2381]::SetCursorPos(430,300) | Out-Null
 $delta=if($down){[uint32]4294967176}else{[uint32]120}
 for($n=0;$n -lt $count;$n++) { [Desktop2381]::mouse_event(0x800,0,0,$delta,[UIntPtr]::Zero); Start-Sleep -Milliseconds 120 }
 Start-Sleep -Milliseconds 800
}
function Stored { Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json }
function AssertCount([int]$count) {if(@((Stored).'flutter.ls_favorites' | Where-Object {$_}).Count -ne $count) {throw "Expected $count persisted favorites"}}
function Pencil([string]$snapshot,[string]$name) {
 $row=Import-Csv "$EvidenceDirectory/$snapshot.tsv" -Delimiter "`t" | Where-Object {$_.text -eq $name} | Select-Object -First 1
 if(!$row) {throw "Favorite $name missing in $snapshot"}
 FavoritePencil $snapshot (([int]$row.top+[int]$row.height/2)/2+10)
}
function RequireText([string]$snapshot,[string]$word) {
 if(!(Import-Csv "$EvidenceDirectory/$snapshot.tsv" -Delimiter "`t" | Where-Object {$_.text -eq $word})) {throw "Input verification failed: $word not visible in $snapshot"}
}
function OpenFavorites([string]$snapshot) {
 $row=Import-Csv "$EvidenceDirectory/$snapshot.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'devices'} | Select-Object -First 1
 if(!$row) {throw "Nearby devices heading unavailable in $snapshot"}
 Click (([int]$row.left+[int]$row.width)/2+110) (([int]$row.top+[int]$row.height/2)/2)
}
try {
 Chapter 'Actual Windows app and real LocalSend peer - empty favorites'
 Snap 'home'
 Word 'Send' 'home'
 Snap 'send'
 Click 576 212
 Snap 'empty'
 AssertCount 0
 if($env:RECORD_GROUP -ne 'remaining') {
 Chapter 'Add a favorite through a real HTTP registration to the peer app'
 PrimaryButton 'empty'
 Snap 'add'
 Field 'Address' 'add' '127.0.0.1'
 Field 'Port' 'add' '53317'
 Snap 'add-filled'
 RequireText 'add-filled' '127.0.0.1'
 RequireText 'add-filled' '53317'
 PrimaryButton 'add-filled'
 Start-Sleep -Seconds 2
 Snap 'added'
 AssertCount 1
 Chapter 'Edit then Cancel - persisted name is unchanged'
 Pencil 'added' 'receiver'
 Snap 'edit-cancel'
 Field 'Device' 'edit-cancel' 'Cancelled name'
 Esc
 Snap 'cancelled'
 if(((Stored).'flutter.ls_favorites'[0] | ConvertFrom-Json).alias -ne 'receiver') {throw 'Cancelled edit changed persistence'}
 Chapter 'Edit and Confirm - custom favorite name is saved'
 Pencil 'cancelled' 'receiver'
 Snap 'edit-save'
 Field 'Device' 'edit-save' 'Saved peer'
 Snap 'edit-filled'
 PrimaryButton 'edit-filled'
 Start-Sleep -Seconds 1
 if(((Stored).'flutter.ls_favorites'[0] | ConvertFrom-Json).alias -ne 'Saved peer') {throw 'Edit did not save'}
 Esc
 Snap 'saved'
 Chapter 'Connect to the saved favorite - real peer registration succeeds'
 Word 'Saved' 'saved'
 Start-Sleep -Seconds 2
 Snap 'connected'
 if(!(Import-Csv "$EvidenceDirectory/connected.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'selection'})) {throw 'Successful favorite connection did not advance to Add to selection'}
 Esc
 Click 576 212
 Snap 'reopen'
 Chapter 'Delete favorite with confirmation - empty state returns'
 Pencil 'reopen' 'Saved'
 Snap 'delete-edit'
 Word 'Delete' 'delete-edit'
 Snap 'delete-confirmation'
 PrimaryButton 'delete-confirmation'
 Snap 'deleted'
 AssertCount 0
 }
 Chapter 'Failed addition to closed localhost port - open error details'
 $addStart=if($env:RECORD_GROUP -eq 'remaining'){'empty'}else{'deleted'}
 PrimaryButton $addStart
 Snap 'failed-add'
 Field 'Address' 'failed-add' '127.0.0.1'
 Field 'Port' 'failed-add' '53319'
 Snap 'failed-add-filled'
 RequireText 'failed-add-filled' '53319'
 PrimaryButton 'failed-add-filled'
 Start-Sleep -Seconds 2
 Snap 'failed-add-error'
 $err=Import-Csv "$EvidenceDirectory/failed-add-error.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'Error'} | Select-Object -First 1
 if(!$err) {throw 'Addition error missing'}
 Click (([int]$err.left+[int]$err.width)/2+24) (([int]$err.top+[int]$err.height/2)/2)
 Snap 'failed-add-details'
 RequireText 'failed-add-details' 'Close'
 Esc
 Chapter 'Recover from failed addition by correcting the peer port'
 Snap 'add-recovery'
 Field 'Port' 'add-recovery' '53317'
 Snap 'add-recovery-filled'
 RequireText 'add-recovery-filled' '53317'
 PrimaryButton 'add-recovery-filled'
 Start-Sleep -Seconds 2
 AssertCount 1
 Snap 'recovered-add'
 Chapter 'Diagnostic setup: persisted 12-entry list; actual UI and networking'
 Stop-Process -Id $sender.Id -Force
 $profile=Stored
 $live=$profile.'flutter.ls_favorites'[0] | ConvertFrom-Json
 $entries=@()
 for($i=1;$i -le 11;$i++) {
  $entries+=(@{id="seed-$i";fingerprint="offline-$i";ip='127.0.0.1';port=1;alias=('Offline {0:d2}' -f $i);customAlias=$true} | ConvertTo-Json -Compress)
 }
 $entries+=($live | ConvertTo-Json -Compress)
 $profile.'flutter.ls_favorites'=$entries
 $profile | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 "$EvidenceDirectory/sender-app/settings.json"
 $sender=Start-Process "$EvidenceDirectory/sender-app/localsend_app.exe" -WorkingDirectory "$EvidenceDirectory/sender-app" -PassThru
 $apps.sender=$sender
 Start-Sleep -Seconds 8
 $sender.Refresh()
 [Desktop2381]::MoveWindow($sender.MainWindowHandle,0,0,1000,760,$true) | Out-Null
 [Desktop2381]::SetForegroundWindow($sender.MainWindowHandle) | Out-Null
 Snap 'long-home'
 Word 'Send' 'long-home'
 Click 576 212
 Snap 'long-top'
 Chapter 'Long favorites list: scroll to bottom and back to top'
 Scroll $true
 Snap 'long-bottom'
 Scroll $false
 Snap 'long-top-again'
 Chapter 'Failed favorite connection: scroll down to the Error and info control'
 Word 'Offline' 'long-top-again'
 Start-Sleep -Seconds 2
 Scroll $true 24
 Snap 'long-error-bottom'
 $err=Import-Csv "$EvidenceDirectory/long-error-bottom.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'Error'} | Select-Object -First 1
 if(!$err) {throw 'Long-list connection error unreachable'}
 Click (([int]$err.left+[int]$err.width)/2+24) (([int]$err.top+[int]$err.height/2)/2)
 Snap 'connection-error-details'
 RequireText 'connection-error-details' 'Close'
 Esc
 Chapter 'Recover from failed favorite by selecting the real peer'
 Snap 'long-recovery'
 Word 'receiver' 'long-recovery'
 Start-Sleep -Seconds 2
 Snap 'long-connected'
 RequireText 'long-connected' 'selection'
 Esc
 Chapter 'Shorter native window: scroll and fixed Cancel / Add actions'
 Click 576 212
 [Desktop2381]::MoveWindow($sender.MainWindowHandle,0,0,883,610,$true) | Out-Null
 Start-Sleep -Seconds 2
 Snap 'small-top'
 Scroll $true 24
 Snap 'small-bottom'
 Word 'Cancel' 'small-bottom'
 Snap 'small-cancelled'
 # Windows Accessibility text scale is a diagnostic OS setting, applied before restart.
 Chapter 'Windows Accessibility text scale 150% (diagnostic OS setting)'
 Stop-Process -Id $sender.Id -Force
 New-Item 'HKCU:\Software\Microsoft\Accessibility' -Force | Out-Null
 Set-ItemProperty 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -Type DWord -Value 150
 $sender=Start-Process "$EvidenceDirectory/sender-app/localsend_app.exe" -WorkingDirectory "$EvidenceDirectory/sender-app" -PassThru
 $apps.sender=$sender
 Start-Sleep -Seconds 8
 $sender.Refresh()
 [Desktop2381]::MoveWindow($sender.MainWindowHandle,0,0,1000,760,$true) | Out-Null
 [Desktop2381]::SetForegroundWindow($sender.MainWindowHandle) | Out-Null
 Snap 'large-text-home'
 Word 'Send' 'large-text-home'
 Snap 'large-text-send'
 # Favorites icon lies next to Nearby devices, at the end of the heading.
 OpenFavorites 'large-text-send'
 [Desktop2381]::MoveWindow($sender.MainWindowHandle,0,0,883,610,$true) | Out-Null
 Snap 'large-text-top'
 RequireText 'large-text-top' 'Favorites'
 $normal=Import-Csv "$EvidenceDirectory/long-top.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'Favorites'} | Select-Object -First 1
 $large=Import-Csv "$EvidenceDirectory/large-text-top.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'Favorites'} | Select-Object -First 1
 @{normalTitleHeight=$normal.height;enlargedTitleHeight=$large.height;requestedWindowsTextScale=150} | ConvertTo-Json | Set-Content "$EvidenceDirectory/text-scale-observation.json"
 if([int]$large.height -lt [int]$normal.height*1.2) {throw 'Requested text scale did not visibly enlarge Favorites title'}
 Chapter 'Short window and enlarged text: failed favorite, scroll Error and open details'
 Word 'Offline' 'large-text-top'
 Start-Sleep -Seconds 2
 Scroll $true 24
 Snap 'large-text-bottom'
 RequireText 'large-text-bottom' 'Favorites'
 $err=Import-Csv "$EvidenceDirectory/large-text-bottom.tsv" -Delimiter "`t" | Where-Object {$_.text -eq 'Error'} | Select-Object -First 1
 if(!$err) {throw 'Enlarged-text error is unreachable'}
 Click (([int]$err.left+[int]$err.width)/2+24) (([int]$err.top+[int]$err.height/2)/2)
 Snap 'large-text-error-details'
 RequireText 'large-text-error-details' 'Close'
 Esc
 Chapter 'Recording complete - actual app UI, real HTTP peer, seeded long list'
 @{sourceCommit='ac81c35d3c623df398ded2704f06b7a5401dec86';recordingBranchCommit=$env:GITHUB_SHA;run=$env:GITHUB_RUN_ID;scenarioGroup=$env:RECORD_GROUP;network='Two actual LocalSend Windows apps, plaintext loopback HTTP, ports 53317 and 53318; closed ports 53319 and 1 for failure';diagnosticSetup='11 persisted offline favorites plus one UI-created real peer; native window resize; Windows Accessibility TextScaleFactor=150';mocks=$false;completed=$true} | ConvertTo-Json | Set-Content "$EvidenceDirectory/coverage.json"
} finally {
 $duration=((Get-Date)-$started).TotalSeconds
 $capture.StandardInput.WriteLine('q')
 if(!$capture.WaitForExit(15000)) {$capture.Kill()}
 foreach($p in $apps.Values) {if(!$p.HasExited){Stop-Process -Id $p.Id -Force}}
 $chapters | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/chapters.json"
 function Stamp([double]$seconds) { $ts=[TimeSpan]::FromSeconds($seconds); '{0:00}:{1:00}:{2:00},{3:000}' -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds,$ts.Milliseconds }
 $srt=@()
 for($i=0;$i -lt $chapters.Count;$i++) {
  $end=if($i+1 -lt $chapters.Count){$chapters[$i+1].start}else{$duration}
  $srt+=@(($i+1).ToString(),"$(Stamp $chapters[$i].start) --> $(Stamp $end)",$chapters[$i].caption,'')
 }
 $srt | Set-Content -Encoding UTF8 "$EvidenceDirectory/captions.srt"
 Push-Location $EvidenceDirectory
 & $Ffmpeg -y -loglevel error -i raw.mp4 -vf "pad=iw:ih+64:0:0:black,subtitles=captions.srt:force_style='FontSize=14,Outline=1,MarginV=12'" -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -movflags +faststart favorites-demo.mp4
 Pop-Location
 Stop-Transcript
}
