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
 $bmp = New-Object System.Drawing.Bitmap($b.Width,$b.Height)
 $g = [System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size)
 $path = "$EvidenceDirectory/$name.png"
 $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
 $g.Dispose(); $bmp.Dispose()
 & "C:/Program Files/Tesseract-OCR/tesseract.exe" $path "$EvidenceDirectory/$name" -l eng --psm 11 tsv 2> "$EvidenceDirectory/$name-ocr-error.txt"
 Get-Content "$EvidenceDirectory/$name.tsv" | Select-Object -Last 80 | Write-Host
}
function Click([int]$x,[int]$y) {
 [Desktop2381]::SetCursorPos($x,$y) | Out-Null
 [Desktop2381]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [Desktop2381]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 800
}
function Word([string]$word,[string]$snap) {
 $rows = Import-Csv "$EvidenceDirectory/$snap.tsv" -Delimiter "`t"
 $row = $rows | Where-Object { $_.text -eq $word } | Select-Object -First 1
 if (-not $row) { throw "OCR word $word missing from $snap" }
 Click ([int]$row.left + [int]$row.width/2) ([int]$row.top + [int]$row.height/2)
}
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture | ConvertTo-Json | Set-Content "$EvidenceDirectory/environment.json"
$nic = Get-NetIPInterface -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -match "Loopback"} | Select-Object -First 1
foreach ($ip in @("10.0.20.2","100.95.193.205")) {
 New-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -IPAddress $ip -PrefixLength 16 -SkipAsSource $true -PolicyStore ActiveStore | Out-Null
}
Get-NetIPAddress | ConvertTo-Json -Depth 4 | Set-Content "$EvidenceDirectory/interfaces.json"
$apps = @{}
foreach ($item in @(@{name="receiver";port=53317;alias="PeerAlpha"},@{name="sender";port=53318;alias="SourceBeta"})) {
 $folder = "$EvidenceDirectory/$($item.name)-app"
 Copy-Item (Split-Path $Executable) $folder -Recurse
 $settings = @{"flutter.ls_port"=$item.port;"flutter.ls_alias"=$item.alias;"flutter.ls_locale"="en";"flutter.ls_save_window_placement"=$false}
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
# Pause at the actual Send screen to determine the favorite toolbar location.
foreach ($name in @("sender","receiver")) {
 $stored = Get-Content "$EvidenceDirectory/$name-app/settings.json" -Raw | ConvertFrom-Json
 $stored.PSObject.Properties.Remove("flutter.ls_security_context")
 $stored.PSObject.Properties.Remove("flutter.ls_show_token")
 $stored | ConvertTo-Json -Depth 10 | Set-Content "$EvidenceDirectory/$name-settings.json"
}
Stop-Process -Id $apps.sender.Id,$apps.receiver.Id -Force
Remove-Item "$EvidenceDirectory/sender-app","$EvidenceDirectory/receiver-app" -Recurse -Force
Stop-Transcript
