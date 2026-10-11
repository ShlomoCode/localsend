param([string]$Executable,[string]$CandidateExecutable,[bool]$ReverseFavorites=$false,[bool]$FallbackControl=$false,[bool]$DistinctOnly=$false,[string]$EvidenceDirectory)
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
 $sg.DrawImage($bmp,0,0,1984,1440)
 $scaled.Save("$EvidenceDirectory/$name-ocr.png",[System.Drawing.Imaging.ImageFormat]::Png)
 $sg.Dispose(); $scaled.Dispose(); $bmp.Dispose()

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
  for ($x=510;$x -lt 640;$x++) {
   $pixel=$bmp.GetPixel($x,$y)
   if ($pixel.R -lt 30 -and $pixel.G -gt 80 -and $pixel.G -lt 145 -and $pixel.B -gt 60 -and $pixel.B -lt 140) {
    $minX=[Math]::Min($minX,$x);$maxX=[Math]::Max($maxX,$x)
    $minY=[Math]::Min($minY,$y);$maxY=[Math]::Max($maxY,$y);$count++
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
  for($x=540;$x -lt 700;$x++) {
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
foreach($item in @(@{name="receiver";port=53317},@{name="sender";port=53318})) {
 $folder="$EvidenceDirectory/$($item.name)-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 @{"flutter.ls_port"=$item.port;"flutter.ls_alias"=$item.name;"flutter.ls_locale"="en";"flutter.ls_save_window_placement"=$false} | ConvertTo-Json | Set-Content -Encoding UTF8 "$folder/settings.json"
 $p=Start-Process "$folder/localsend_app.exe" -WorkingDirectory $folder -PassThru
 Start-Sleep -Seconds 10
 $p.Refresh()
 if(!$p.MainWindowHandle) {throw "Missing $($item.name) window"}
 [Desktop2381]::MoveWindow($p.MainWindowHandle,0,0,1000,760,$true) | Out-Null
 [Desktop2381]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
 Start-Sleep -Seconds 2
 Screenshot "$($item.name)-initial"
 $apps[$item.name]=$p
}
$sender=$apps.sender
$dpiGraphics=[System.Drawing.Graphics]::FromHwnd($sender.MainWindowHandle)
@{dpiX=$dpiGraphics.DpiX;dpiY=$dpiGraphics.DpiY;initialWindowWidth=1000;initialWindowHeight=760} | ConvertTo-Json | Set-Content "$EvidenceDirectory/display-scale.json"
$dpiGraphics.Dispose()
Word "Send" "sender-initial"
Screenshot "sender-send"
Click 576 212
Screenshot "favorites-empty"
$snap="favorites-empty"
for($i=1;$i -le 12;$i++) {
 PrimaryButton $snap
 Screenshot "add-$i"
 Click 500 400
 Paste "127.0.0.$i"
 Click 500 490
 [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DELETE 12}")
 [System.Windows.Forms.SendKeys]::SendWait("53317")
 Click 500 310
 Paste ("Peer{0:d2}" -f $i)
 Screenshot "filled-$i"
 PrimaryButton "filled-$i"
 Start-Sleep -Seconds 2
 $snap="favorites-$i"
 Screenshot $snap
 $stored=Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
 if(@($stored.'flutter.ls_favorites').Count -ne $i) {throw "Favorite $i was not created through UI"}
 if($i -eq 2) {
  [Desktop2381]::SetCursorPos(450,360) | Out-Null
  [Desktop2381]::mouse_event(0x800,0,0,([uint32]4294966576),[UIntPtr]::Zero)
  Start-Sleep -Seconds 1
  Screenshot "short-control-after-wheel"
 }
}
@($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json}) | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/ui-created-favorites.json"
foreach($size in @(@{name="report-sized";width=883;height=610},@{name="larger";width=1000;height=760})) {
 [Desktop2381]::MoveWindow($sender.MainWindowHandle,0,0,$size.width,$size.height,$true) | Out-Null
 Start-Sleep -Seconds 2
 $clientRect=New-Object Desktop2381+Rect
 $windowRect=New-Object Desktop2381+Rect
 [Desktop2381]::GetClientRect($sender.MainWindowHandle,[ref]$clientRect) | Out-Null
 [Desktop2381]::GetWindowRect($sender.MainWindowHandle,[ref]$windowRect) | Out-Null
 @{requested=$size;client=$clientRect;window=$windowRect} | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/$($size.name)-bounds.json"
 Screenshot "$($size.name)-before-wheel"
 [Desktop2381]::SetCursorPos(440,300) | Out-Null
 for($n=0;$n -lt 6;$n++) {
  [Desktop2381]::mouse_event(0x800,0,0,([uint32]4294967176),[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 200
 }
 Start-Sleep -Seconds 1
 Screenshot "$($size.name)-after-wheel"
 Write-Host "INPUT wheel-to-end x=440 y=300 notches=24 delta=-120 utc=$((Get-Date).ToUniversalTime().ToString('o'))"
 for($n=0;$n -lt 24;$n++) {
  [Desktop2381]::mouse_event(0x800,0,0,([uint32]4294967176),[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 100
 }
 Start-Sleep -Seconds 1
 Screenshot "$($size.name)-after-wheel-to-end"
 # Drag at the visible right edge of the dialog. Images determine whether a scrollbar exists.
 Click 576 240
 [Desktop2381]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [Desktop2381]::SetCursorPos(576,480) | Out-Null
 [Desktop2381]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Seconds 1
 Screenshot "$($size.name)-after-edge-drag"
}
$lastRows=Import-Csv "$EvidenceDirectory/larger-after-edge-drag.tsv" -Delimiter "`t"
$lastPeer=$lastRows | Where-Object {$_.text -eq "Peer12"} | Select-Object -First 1
$lastPeerIp=$lastRows | Where-Object {$_.text -like '*127.0.0.12*'} | Select-Object -First 1
@{lastRowVisible=($null -ne $lastPeer -or $null -ne $lastPeerIp);lastRowOcr=$lastPeer;lastRowIpOcr=$lastPeerIp;input="six wheel notches, 24 more to end, then edge drag"} | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/last-row-observation.json"
if($lastPeer -or $lastPeerIp) {
 $lastRowY=if($lastPeer){([int]$lastPeer.top + [int]$lastPeer.height/2)/2 + 10}else{([int]$lastPeerIp.top + [int]$lastPeerIp.height/2)/2 - 10}
 FavoritePencil "larger-after-edge-drag" $lastRowY
 Screenshot "last-row-edit"
 [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
 Start-Sleep -Seconds 1
 Screenshot "last-row-edit-dismissed"
}
Screenshot "long-list-before-cancel"
Word "Cancel" "long-list-before-cancel"
Screenshot "long-list-cancel-result"
Click 576 212
Screenshot "long-list-reopened"
PrimaryButton "long-list-reopened"
Screenshot "add-after-long-list"
Word "Cancel" "add-after-long-list"
Screenshot "add-after-long-list-cancel-result"
foreach($p in $apps.Values) {Stop-Process -Id $p.Id -Force}
Stop-Transcript
