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


function Screen([string]$name) {
 $bmp=New-Object System.Drawing.Bitmap(1920,1080);$g=[System.Drawing.Graphics]::FromImage($bmp);$g.CopyFromScreen(0,0,0,0,$bmp.Size);$bmp.Save("$EvidenceDirectory/$name.png",[System.Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$bmp.Dispose()
}
foreach($scale in @(100,125,150)) {
 Start-Process 'ms-settings:easeofaccess-display';Start-Sleep -Seconds 8
 $elements=$desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 $slider=$elements|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Slider -and $_.Current.Name -eq 'Text size'}|Select-Object -First 1
 if(!$slider){throw 'Observed Text size slider unavailable'}
 $range=[System.Windows.Automation.RangeValuePattern]$slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
 $before=$range.Current.Value
 if($before -ne $scale) {
  $range.SetValue($scale);Start-Sleep -Seconds 1
  $elements=$desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $apply=$elements|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -eq 'Apply' -and $_.Current.IsEnabled}|Select-Object -First 1
  if(!$apply){throw 'Observed Apply button unavailable'}
  ([System.Windows.Automation.InvokePattern]$apply.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
  Start-Sleep -Seconds 12
 }
 $elements=$desktop.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 $slider=$elements|Where-Object{$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Slider -and $_.Current.Name -eq 'Text size'}|Select-Object -First 1
 $range=[System.Windows.Automation.RangeValuePattern]$slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
 $actual=(Get-ItemProperty 'HKCU:/Software/Microsoft/Accessibility' -ErrorAction SilentlyContinue).TextScaleFactor
 @{requested=$scale;before=$before;slider=$range.Current.Value;osTextScale=$actual;action='RangeValue.SetValue and visible Apply Invoke';utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content "$EvidenceDirectory/scale-$scale-setting.json"
 Screen "scale-$scale-setting"
 if($range.Current.Value -ne $scale -or ($actual -and $actual -ne $scale)){throw 'Windows text size did not apply'}
 # Close the observed Settings window through its accessibility window pattern.
 $settings=$elements|Where-Object{$_.Current.Name -eq 'Settings' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.NativeWindowHandle -ne 0}|Select-Object -First 1
 if($settings){try{([System.Windows.Automation.WindowPattern]$settings.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()}catch{[System.Windows.Forms.SendKeys]::SendWait('%{F4}')}}
 Start-Sleep -Seconds 2
 Stop-Transcript
 & "$PSScriptRoot/windows2861.ps1" -ReleaseRoot $ReleaseRoot -EvidenceDirectory "$EvidenceDirectory/scale-$scale" -Versions @('current') -Locales @('en','uk','fr')
 if($scale -eq 125){& "$PSScriptRoot/windows2861.ps1" -ReleaseRoot $ReleaseRoot -EvidenceDirectory "$EvidenceDirectory/scale-$scale-narrow" -Versions @('current') -Locales @('en','uk','fr') -WindowWidth 400}
 Start-Transcript "$EvidenceDirectory/transcript.txt" -Append
}
Stop-Transcript
