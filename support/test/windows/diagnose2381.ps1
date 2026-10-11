param([string]$Executable,[string]$EvidenceDirectory)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Desktop2381 {
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
function Word([string]$word,[string]$snap) {
 $rows = Import-Csv "$EvidenceDirectory/$snap.tsv" -Delimiter "`t"
 $row = $rows | Where-Object { $_.text -eq $word } | Select-Object -First 1
 if (-not $row) {
  if ($word -eq "Cancel" -and $snap -like "favorites*") {
   # Two-row Favorites Cancel verified at x474-524/y477-495, including the wider exact-name dialog.
   Click 500 485
   return
  }
  throw "OCR word $word missing from $snap"
 }
 Click (([int]$row.left + [int]$row.width/2)/2) (([int]$row.top + [int]$row.height/2)/2)
}
function PrimaryButton([string]$snap) {
 $bmp = [System.Drawing.Bitmap]::FromFile("$EvidenceDirectory/$snap.png")
 $minX=992; $maxX=0; $minY=720; $maxY=0; $count=0
 for ($y=180;$y -lt 650;$y++) {
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
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture | ConvertTo-Json | Set-Content "$EvidenceDirectory/environment.json"
if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
 Install-WindowsFeature Hyper-V-PowerShell | Out-String | Write-Host
}
foreach ($network in @(@{name="bug2381-home";ip="10.0.20.2"},@{name="bug2381-netbird";ip="100.95.193.205"})) {
 New-VMSwitch -Name $network.name -SwitchType Internal | Out-Null
 $nic = Get-NetAdapter -Name "vEthernet ($($network.name))"
 Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
 New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $network.ip -PrefixLength 16 -SkipAsSource $false -PolicyStore ActiveStore | Out-Null
}
Start-Sleep -Seconds 3
Get-NetIPAddress | ConvertTo-Json -Depth 4 | Set-Content "$EvidenceDirectory/interfaces.json"
Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceDescription,ifIndex,Status | ConvertTo-Json | Set-Content "$EvidenceDirectory/adapters.json"
$apps = @{}
foreach ($item in @(@{name="receiver";port=53317;alias="PeerAlpha"},@{name="sender";port=53318;alias="SourceBeta"})) {
 $folder = "$EvidenceDirectory/$($item.name)-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 $settings = @{"flutter.ls_port"=$item.port;"flutter.ls_alias"=$item.alias;"flutter.ls_locale"="en";"flutter.ls_save_window_placement"=$false;"flutter.ls_advanced_settings"=$true;"flutter.ls_network_whitelist"=@("10.0.20.2","100.95.193.205")}
 $settings | ConvertTo-Json | Set-Content -Encoding UTF8 "$folder/settings.json"
 $p = Start-Process "$folder/localsend_app.exe" -WorkingDirectory $folder -PassThru
 Start-Sleep -Seconds 12
 $p.Refresh()
 if (!$p.MainWindowHandle) { throw "Missing $($item.name) window; exited=$($p.HasExited)" }
 [Desktop2381]::MoveWindow($p.MainWindowHandle,0,0,1000,760,$true) | Out-Null
 [Desktop2381]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
 Start-Sleep -Seconds 2
 Screenshot "$($item.name)-initial"
 $apps[$item.name]=$p
}
# Establish network controls before submitting either real UI favorite.
Get-NetIPAddress | Select-Object InterfaceAlias,InterfaceIndex,IPAddress,PrefixLength,AddressState,SkipAsSource | ConvertTo-Json | Set-Content "$EvidenceDirectory/source-addresses-before-ui.json"
Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceAlias,InterfaceIndex,DestinationPrefix,NextHop,RouteMetric | ConvertTo-Json | Set-Content "$EvidenceDirectory/routes-before-ui.json"
$selectedRoutes=@()
foreach ($ip in @("10.0.20.2","100.95.193.205")) {
 try {$selectedRoutes+=@{remote=$ip;selection=@(Find-NetRoute -RemoteIPAddress $ip | Select-Object InterfaceAlias,InterfaceIndex,IPAddress,DestinationPrefix,NextHop,AddressState,SkipAsSource);error=$null}}
 catch {$selectedRoutes+=@{remote=$ip;selection=@();error=$_.Exception.Message}}
}
$selectedRoutes | ConvertTo-Json -Depth 6 | Set-Content "$EvidenceDirectory/selected-routes-before-ui.json"
Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -in @(53317,53318)} | Select-Object LocalAddress,LocalPort,RemoteAddress,State,OwningProcess | ConvertTo-Json | Set-Content "$EvidenceDirectory/listeners-before-ui.json"
$preControls=@()
foreach($ip in @("127.0.0.1","10.0.20.2","100.95.193.205")) {
 $tcp=New-Object System.Net.Sockets.TcpClient
 try {$task=$tcp.ConnectAsync($ip,53317);$ready=$task.Wait(5000);$preControls+=@{ip=$ip;connected=($ready -and $tcp.Connected);localEndpoint=[string]$tcp.Client.LocalEndPoint;error=$null}}
 catch {$preControls+=@{ip=$ip;connected=$false;localEndpoint=$null;error=$_.Exception.ToString()}}
 finally {$tcp.Dispose()}
}
$preControls | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/tcp-controls-before-ui.json"
if (@($preControls | Where-Object {-not $_.connected}).Count -gt 0) {throw "Pre-UI TCP controls failed; source/route diagnostics retained"}
$sender = $apps.sender
[Desktop2381]::SetForegroundWindow($sender.MainWindowHandle) | Out-Null
Word "Send" "sender-initial"
Screenshot "sender-send"
# The favorite icon was visually located at (576,212) in the retained release screenshot.
Click 576 212
Screenshot "favorites-empty"
foreach ($favorite in @(@{ip="10.0.20.2";alias="My Desktop (Home Lan)"},@{ip="100.95.193.205";alias="My Desktop (NetBird)"})) {
 $snapshot = if ($favorite.ip -eq "10.0.20.2") {"favorites-empty"} else {"favorites-first"}
 PrimaryButton $snapshot
 Screenshot "add-$($favorite.ip)"
 Click 500 400
 Paste $favorite.ip
 Click 500 490
 [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DELETE 12}")
 Start-Sleep -Milliseconds 200
 [System.Windows.Forms.SendKeys]::SendWait("53317")
 Click 500 310
 Paste $favorite.alias
 Screenshot "filled-$($favorite.ip)"
 PrimaryButton "filled-$($favorite.ip)"
 Start-Sleep -Seconds 3
 $listSnapshot = if ($favorite.ip -eq "10.0.20.2") {"favorites-first"} else {"favorites-second"}
 Screenshot $listSnapshot
 $storedNow = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
 $expected = if($favorite.ip -eq "10.0.20.2") {1} else {2}
 if (@($storedNow.'flutter.ls_favorites').Count -lt $expected -or -not $storedNow.'flutter.ls_favorites') {
  Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -in @(53317,53318)} | Select-Object LocalAddress,LocalPort,RemoteAddress,State,OwningProcess | ConvertTo-Json | Set-Content "$EvidenceDirectory/listeners-at-favorite-error.json"
  $controls=@()
  foreach($ip in @("127.0.0.1","10.0.20.2","100.95.193.205")) {
   $tcp=New-Object System.Net.Sockets.TcpClient
   try {$task=$tcp.ConnectAsync($ip,53317);$ready=$task.Wait(5000);$controls+=@{ip=$ip;connected=($ready -and $tcp.Connected);error=$null}}
   catch {$controls+=@{ip=$ip;connected=$false;error=$_.Exception.Message}}
   finally {$tcp.Dispose()}
  }
  $controls | ConvertTo-Json | Set-Content "$EvidenceDirectory/tcp-controls.json"
  Click 435 517
  Screenshot "favorite-error-details"
  throw "Favorite submit did not reach the Favorites list; diagnostics retained"
 }

}
$stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
$favorites = @($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json})
$favorites | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/favorites-before-scan.json"
if ($favorites.Count -ne 2 -or $favorites[0].alias -ne "My Desktop (Home Lan)" -or $favorites[1].alias -ne "My Desktop (NetBird)") {throw "UI input did not store the intended favorite names"}
if ($favorites[0].fingerprint -ne $favorites[1].fingerprint) {throw "Favorites do not refer to the same real peer identity"}
Word "Cancel" "favorites-second"

Click 497 212
Start-Sleep -Seconds 8
Screenshot "nearby-after-add"
Click 576 212
Screenshot "favorites-after-scan"
$stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
@($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json}) | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/favorites-after-scan.json"
# The two Edit pencil centers were verified on the actual two-row Favorites dialog.
foreach ($edit in @(@{alias="My Desktop (Home Lan)";y=358;ip="10.0.20.2"},@{alias="My Desktop (NetBird)";y=414;ip="100.95.193.205"})) {
 Click 588 $edit.y
 $editSnapshot="edit-$($edit.ip)"
 Screenshot $editSnapshot
 # The Edit name field is x384-616/y257-305 in run 38104091779.
 Click 500 280
 [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DELETE 100}")
 Paste $edit.alias
 Screenshot "edit-filled-$($edit.ip)"
 PrimaryButton "edit-filled-$($edit.ip)"
 Start-Sleep -Seconds 2
 Screenshot "edit-confirmed-$($edit.ip)"
 # Editing to the same stored name does not set customAlias. For the second
 # favorite, first apply a distinct intermediate name through the same UI.
 $stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
 $edited=@($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json}) | Where-Object {$_.ip -eq $edit.ip}
 if (-not $edited.customAlias) {
  Click 500 280
  [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DELETE 100}")
  Paste "$($edit.alias) temp"
  Screenshot "edit-intermediate-$($edit.ip)"
  PrimaryButton "edit-intermediate-$($edit.ip)"
  Click 500 280
  [System.Windows.Forms.SendKeys]::SendWait("{HOME}{DELETE 100}")
  Paste $edit.alias
  Screenshot "edit-restored-$($edit.ip)"
  PrimaryButton "edit-restored-$($edit.ip)"
 }
 Word "Cancel" "edit-confirmed-$($edit.ip)"
 Screenshot "favorites-edited-$($edit.ip)"
}
$stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
$customFavorites=@($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json})
$customFavorites | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/favorites-custom-before-scan.json"
if (@($customFavorites | Where-Object {-not $_.customAlias}).Count -gt 0) {throw "Actual UI Edit did not set both custom aliases"}
Word "Cancel" "favorites-edited-100.95.193.205"
Screenshot "nearby-after-edit"
Click 497 212
Start-Sleep -Seconds 8
Screenshot "nearby-custom-after-scan"
Click 576 212
Screenshot "favorites-custom-after-scan"
$stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
@($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json}) | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/favorites-custom-after-scan.json"
Word "Cancel" "favorites-custom-after-scan"
Click 103 245
Screenshot "settings-top"
$found=$false
for ($step=0;$step -lt 9;$step++) {
 $snapshot = if($step -eq 0) {"settings-top"} else {"settings-scroll-$step"}
 $rows=Import-Csv "$EvidenceDirectory/$snapshot.tsv" -Delimiter "`t"
 if ($rows | Where-Object {$_.text -eq "Filtered"}) {
  Word "Filtered" $snapshot
  Screenshot "network-whitelist-ui"
  $found=$true
  break
 }
 [Desktop2381]::SetCursorPos(800,500) | Out-Null
 [Desktop2381]::mouse_event(0x0800,0,0,4294966816,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 700
 Screenshot "settings-scroll-$($step+1)"
}
if (-not $found) {throw "Whitelist UI was not reached"}
Get-NetIPAddress | ConvertTo-Json -Depth 4 | Set-Content "$EvidenceDirectory/interfaces-after-ui.json"


foreach ($name in @("sender","receiver")) {
 $stored = Get-Content "$EvidenceDirectory/$name-app/settings.json" -Raw | ConvertFrom-Json
 $stored.PSObject.Properties.Remove("flutter.ls_security_context")
 $stored.PSObject.Properties.Remove("flutter.ls_show_token")
 $stored | ConvertTo-Json -Depth 10 | Set-Content "$EvidenceDirectory/$name-settings.json"
}
Stop-Process -Id $apps.sender.Id,$apps.receiver.Id -Force
Start-Sleep -Seconds 3
Remove-Item "$EvidenceDirectory/sender-app","$EvidenceDirectory/receiver-app" -Recurse -Force -ErrorAction Continue
Stop-Transcript
