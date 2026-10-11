param([string]$Executable,[string]$EvidenceDirectory)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Desktop2381 {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int z,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
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

 & "C:/Program Files/Tesseract-OCR/tesseract.exe" $EvidenceDirectory/$name-ocr.png "$EvidenceDirectory/$name" -l eng --psm 11 tsv 2> "$EvidenceDirectory/$name-ocr-error.txt"
 Import-Csv "$EvidenceDirectory/$name.tsv" -Delimiter "`t" | Where-Object {$_.text} | Select-Object left,top,width,height,text | Format-Table | Out-String | Write-Host
}
function Click([int]$x,[int]$y) {
 [Desktop2381]::SetCursorPos($x,$y) | Out-Null
 [Desktop2381]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [Desktop2381]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 800
}
function Paste([string]$value) {
 [System.Windows.Forms.Clipboard]::SetText($value)
 [System.Windows.Forms.SendKeys]::SendWait("^v")
 Start-Sleep -Milliseconds 600
}
function Word([string]$word,[string]$snap) {
 $rows = Import-Csv "$EvidenceDirectory/$snap.tsv" -Delimiter "`t"
 $row = $rows | Where-Object { $_.text -eq $word } | Select-Object -First 1
 if (-not $row) { throw "OCR word $word missing from $snap" }
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
$nic = Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -match "Loopback"} | Select-Object -First 1
foreach ($ip in @("10.0.20.2","100.95.193.205")) {
 New-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -IPAddress $ip -PrefixLength 16 -SkipAsSource $true -PolicyStore ActiveStore | Out-Null
}
Get-NetIPAddress | ConvertTo-Json -Depth 4 | Set-Content "$EvidenceDirectory/interfaces.json"
Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceDescription,ifIndex,Status | ConvertTo-Json | Set-Content "$EvidenceDirectory/adapters.json"
$apps = @{}
foreach ($item in @(@{name="receiver";port=53317;alias="PeerAlpha"},@{name="sender";port=53318;alias="SourceBeta"})) {
 $folder = "$EvidenceDirectory/$($item.name)-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 $settings = @{"flutter.ls_port"=$item.port;"flutter.ls_alias"=$item.alias;"flutter.ls_locale"="en";"flutter.ls_save_window_placement"=$false;"flutter.ls_network_whitelist"=@("10.0.20.2","100.95.193.205")}
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
$sender = $apps.sender
[Desktop2381]::SetForegroundWindow($sender.MainWindowHandle) | Out-Null
Word "Send" "sender-initial"
Screenshot "sender-send"
# The favorite icon was visually located at (576,212) in the retained release screenshot.
Click 576 212
Screenshot "favorites-empty"
foreach ($favorite in @(@{ip="10.0.20.2";alias="Home LAN"},@{ip="100.95.193.205";alias="NetBird LAN"})) {
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
 Screenshot $(if ($favorite.ip -eq "10.0.20.2") {"favorites-first"} else {"favorites-second"})
}
$stored = Get-Content "$EvidenceDirectory/sender-app/settings.json" -Raw | ConvertFrom-Json
$favorites = @($stored.'flutter.ls_favorites' | ForEach-Object {$_ | ConvertFrom-Json})
$favorites | ConvertTo-Json -Depth 5 | Set-Content "$EvidenceDirectory/favorites-before-scan.json"
if ($favorites.Count -ne 2 -or $favorites[0].alias -ne "Home LAN" -or $favorites[1].alias -ne "NetBird LAN") {throw "UI input did not store the intended favorite names"}
if ($favorites[0].fingerprint -ne $favorites[1].fingerprint) {throw "Favorites do not refer to the same real peer identity"}
Word "Cancel" "favorites-second"

Click 497 212
Start-Sleep -Seconds 8
Screenshot "nearby-after-add"
Click 576 212
Screenshot "favorites-after-scan"

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
