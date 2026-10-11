param([string]$ReleaseRoot,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class Desktop2861 {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int z,bool repaint);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
New-Item -ItemType Directory -Force $EvidenceDirectory|Out-Null
Start-Transcript "$EvidenceDirectory/transcript.txt"
$script:inputs=@()
function Capture([string]$name) {
 $bmp=New-Object System.Drawing.Bitmap(1215,738);$g=[System.Drawing.Graphics]::FromImage($bmp)
 $g.CopyFromScreen(0,0,0,0,$bmp.Size);$bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png)
 $g.Dispose();$bmp.Dispose();$script:p.Refresh()
 $r=New-Object Desktop2861+Rect;[Desktop2861]::GetClientRect($script:p.MainWindowHandle,[ref]$r)|Out-Null
 @{utc=[DateTime]::UtcNow.ToString('o');pid=$script:p.Id;window=$script:p.MainWindowHandle.ToInt64();foreground=[Desktop2861]::GetForegroundWindow().ToInt64();dpi=[Desktop2861]::GetDpiForWindow($script:p.MainWindowHandle);client=@{width=$r.right;height=$r.bottom}}|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/$name-state.json"
 try {$root=[System.Windows.Automation.AutomationElement]::FromHandle($script:p.MainWindowHandle);$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)|ForEach-Object{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;bounds=$_.Current.BoundingRectangle.ToString()}}|ConvertTo-Json -Depth 4|Set-Content "$EvidenceDirectory/$name-uia.json"}catch{$_|Out-String|Set-Content "$EvidenceDirectory/$name-uia-error.txt"}
}
function Click([int]$x,[int]$y,[string]$name) {
 $script:inputs+=@{action=$name;x=$x;y=$y;utc=[DateTime]::UtcNow.ToString('o')}
 [Desktop2861]::SetCursorPos($x,$y)|Out-Null;[Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 800
}
Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture|ConvertTo-Json|Set-Content "$EvidenceDirectory/environment.json"
@{imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;commit=$env:GITHUB_SHA;run=$env:GITHUB_RUN_ID;processor=$env:PROCESSOR_ARCHITECTURE;screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString();textScale=(Get-ItemProperty 'HKCU:/Software/Microsoft/Accessibility' -ErrorAction SilentlyContinue).TextScaleFactor;logPixels=(Get-ItemProperty 'HKCU:/Control Panel/Desktop' -ErrorAction SilentlyContinue).LogPixels}|ConvertTo-Json|Set-Content "$EvidenceDirectory/runner.json"
foreach($version in @('1.17.0','1.18.2')) {foreach($locale in @('en','uk')) {
 $name="$version-$locale";$source="$ReleaseRoot/$version";$folder="$EvidenceDirectory/$name-app"
 Copy-Item $source $folder -Recurse
 $exe=(Get-ChildItem $folder -Recurse -Filter localsend_app.exe|Select-Object -First 1).FullName
 $appdir=Split-Path $exe
 @{'flutter.ls_port'=53361;'flutter.ls_alias'='Bug2861';'flutter.ls_locale'=$locale;'flutter.ls_theme'='dark';'flutter.ls_save_window_placement'=$false}|ConvertTo-Json|Set-Content -Encoding UTF8 "$appdir/settings.json"
 Get-FileHash $exe -Algorithm SHA256|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-executable.json"
 $script:p=Start-Process $exe -WorkingDirectory $appdir -PassThru
 try {
  Start-Sleep -Seconds 15;$script:p.Refresh();if(!$script:p.MainWindowHandle){throw 'No app window'}
  [Desktop2861]::MoveWindow($script:p.MainWindowHandle,0,0,1215,738,$true)|Out-Null;[Desktop2861]::SetForegroundWindow($script:p.MainWindowHandle)|Out-Null
  Start-Sleep -Seconds 2;Capture "$name-initial"
  Click 110 243 'Settings rail';Capture "$name-settings-top"
  for($step=1;$step -le 4;$step++) {
   [Desktop2861]::SetCursorPos(750,620)|Out-Null;[Desktop2861]::mouse_event(2048,0,0,4294967176,[UIntPtr]::Zero)
   $script:inputs+=@{action='Settings scroll down 120';step=$step;utc=[DateTime]::UtcNow.ToString('o')}
   Start-Sleep -Milliseconds 800;Capture "$name-settings-scroll-$step"
  }
  Copy-Item "$appdir/settings.json" "$EvidenceDirectory/$name-profile.json"
 }catch{$_|Out-String|Set-Content "$EvidenceDirectory/$name-error.txt"}
 finally{if(!$script:p.HasExited){Stop-Process -Id $script:p.Id -Force};Start-Sleep -Seconds 2}
}}
$script:inputs|ConvertTo-Json -Depth 5|Set-Content "$EvidenceDirectory/inputs.json"
Stop-Transcript
