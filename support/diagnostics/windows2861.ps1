param([string]$ReleaseRoot,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @"
using System;using System.Runtime.InteropServices;
public static class Desktop2861 {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct DevMode {
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string device;
 public ushort spec,driver,size,extra;public uint fields;public int x,y;public uint orientation,fixedOutput;public short color,duplex,yResolution,ttOption,collate;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string form;
 public ushort logPixels;public uint bits,width,height,flags,frequency,icmMethod,icmIntent,mediaType,dither,reserved1,reserved2,panningWidth,panningHeight;
 }
 public static DevMode NewMode() { return new DevMode { size=(ushort)Marshal.SizeOf(typeof(DevMode)), extra=0 }; }
 public static string ModeLayout() { return "size="+Marshal.SizeOf(typeof(DevMode))+",dmSize="+Marshal.OffsetOf(typeof(DevMode),"size")+",fields="+Marshal.OffsetOf(typeof(DevMode),"fields")+",width="+Marshal.OffsetOf(typeof(DevMode),"width")+",height="+Marshal.OffsetOf(typeof(DevMode),"height"); }
 public static object PrepareDisplay() {
  var d=NewMode(); int inputSize=d.size;bool ok=EnumDisplaySettings(null,-1,ref d);int error=Marshal.GetLastWin32Error();
  int returnedSize=d.size;uint previousWidth=d.width,previousHeight=d.height;int test=-999,apply=-999;
  if(ok) { d.width=1920;d.height=1080;d.fields=0x180000;test=ChangeDisplaySettings(ref d,2);if(test==0)apply=ChangeDisplaySettings(ref d,0); }
  return new {inputSize,returnedSize,ok,error,previousWidth,previousHeight,test,apply};
 }
 public static object StringIdentity(string value) { return new { isNull=value==null,length=value==null?-1:value.Length }; }
 [DllImport("user32.dll",EntryPoint="EnumDisplaySettingsW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] public static extern bool EnumDisplaySettings(string device,int mode,ref DevMode d);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DevMode d,int flags);
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
# Prepare only this disposable cloud desktop before launching any application.
[Desktop2861]::ModeLayout()|Set-Content "$EvidenceDirectory/mode-layout.txt"
[Desktop2861]::StringIdentity($null)|ConvertTo-Json|Set-Content "$EvidenceDirectory/powershell-null-binding.json"
[Desktop2861]::PrepareDisplay()|ConvertTo-Json|Set-Content "$EvidenceDirectory/display-setup.json"
Start-Sleep -Seconds 3
$desktop=[System.Windows.Automation.AutomationElement]::RootElement
$setupInputs=@()
for($attempt=0;$attempt -lt 8;$attempt++) {
 $setupBmp=New-Object System.Drawing.Bitmap(1920,1080);$setupG=[System.Drawing.Graphics]::FromImage($setupBmp);$setupG.CopyFromScreen(0,0,0,0,$setupBmp.Size);$setupBmp.Save("$EvidenceDirectory/setup-$attempt.png",[System.Drawing.Imaging.ImageFormat]::Png);$setupG.Dispose();$setupBmp.Dispose()
 $elements=$desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 $elements|ForEach-Object{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;bounds=$_.Current.BoundingRectangle.ToString()}}|ConvertTo-Json|Set-Content "$EvidenceDirectory/setup-uia-$attempt.json"
 $privacy=$elements|Where-Object{$_.Current.Name -eq 'Microsoft account' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window}|Select-Object -First 1
 if($privacy){
  # The retained 1920x1080 setup-7 screenshot shows the privacy wizard's Next/Accept button at these bounds.
  $setupInputs+=@{action='Privacy visible Next/Accept';x=1435;y=849;utc=[DateTime]::UtcNow.ToString('o')}
  [Desktop2861]::SetCursorPos(1435,849)|Out-Null;[Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Seconds 2;continue
 }
 $ok=$elements|Where-Object{$_.Current.Name -eq 'OK' -and !$_.Current.IsOffscreen}|Select-Object -First 1
 if($ok){
  $properties=$elements|Where-Object{$_.Current.Name -eq 'System Properties'}|Select-Object -First 1
  if($properties){[Desktop2861]::SetForegroundWindow([IntPtr]$properties.Current.NativeWindowHandle)|Out-Null;Start-Sleep -Milliseconds 500}
  $bounds=$ok.Current.BoundingRectangle;[Desktop2861]::SetCursorPos([int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))|Out-Null;[Desktop2861]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Desktop2861]::mouse_event(4,0,0,0,[UIntPtr]::Zero);Start-Sleep -Seconds 1;continue
 }
 $next=$elements|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -in @('Next','Accept')}|Select-Object -First 1
 if(!$next){break}
 try{([System.Windows.Automation.InvokePattern]$next.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()}catch{break}
 Start-Sleep -Seconds 1
}
$setupInputs|ConvertTo-Json|Set-Content "$EvidenceDirectory/setup-inputs.json"
[System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
if([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width -lt 1215){throw 'Desktop smaller than original screenshot; do not run report scenario'}
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
Get-ChildItem 'C:/Windows/Fonts' -Filter '*seg*'|Get-FileHash -Algorithm SHA256|ConvertTo-Json|Set-Content "$EvidenceDirectory/segoe-fonts.json"
foreach($version in @('1.17.0','1.18.2','current')) {foreach($locale in @('en','uk','fr')) {
 $name="$version-$locale";$source="$ReleaseRoot/$version";$folder="$EvidenceDirectory/$name-app"
 Copy-Item $source $folder -Recurse
 $exe=(Get-ChildItem $folder -Recurse -Filter localsend_app.exe|Select-Object -First 1).FullName
 $appdir=Split-Path $exe
 @{'flutter.ls_port'=53361;'flutter.ls_alias'='Bug2861';'flutter.ls_locale'=$locale;'flutter.ls_theme'='dark';'flutter.ls_save_window_placement'=$false}|ConvertTo-Json|Set-Content -Encoding UTF8 "$appdir/settings.json"
 Get-FileHash $exe -Algorithm SHA256|ConvertTo-Json|Set-Content "$EvidenceDirectory/$name-executable.json"
 New-NetFirewallRule -DisplayName "Bug2861 $name inbound" -Direction Inbound -Program $exe -Action Allow -Profile Any|Out-Null
 $script:p=Start-Process $exe -WorkingDirectory $appdir -PassThru
 try {
  Start-Sleep -Seconds 15;$script:p.Refresh();if(!$script:p.MainWindowHandle){throw 'No app window'}
  [Desktop2861]::MoveWindow($script:p.MainWindowHandle,0,0,1215,738,$true)|Out-Null;[Desktop2861]::SetForegroundWindow($script:p.MainWindowHandle)|Out-Null
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
  Click 100 85 'Foreground LocalSend logo'
  Start-Sleep -Seconds 2;Capture "$name-initial"
  if([Desktop2861]::GetForegroundWindow() -ne $script:p.MainWindowHandle){throw 'LocalSend not foreground; scenario not reached'}
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
