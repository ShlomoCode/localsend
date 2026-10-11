param([string]$Action='snapshot',[int]$X=0,[int]$Y=0,[string]$Label='snapshot')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing,UIAutomationClient,UIAutomationTypes
Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class W3393 {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 public struct Rect { public int L,T,R,B; }
}
'@
$window=[W3393]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW','LocalSend')
if($window -eq [IntPtr]::Zero){throw 'No LocalSend window'}
$view=[W3393]::FindWindowEx($window,[IntPtr]::Zero,'FLUTTERVIEW',$null)
if($view -eq [IntPtr]::Zero){throw 'No Flutter view'}
if($Action -eq 'click'){
 [void][W3393]::SetForegroundWindow($window)
 $point=[IntPtr](($Y -shl 16) -bor $X)
 [void][W3393]::PostMessage($view,0x200,[IntPtr]::Zero,$point)
 [void][W3393]::PostMessage($view,0x201,[IntPtr]1,$point)
 [void][W3393]::PostMessage($view,0x202,[IntPtr]::Zero,$point)
 Start-Sleep -Milliseconds 800
}
$rect=New-Object W3393+Rect
[void][W3393]::GetWindowRect($window,[ref]$rect)
$image=[System.Drawing.Bitmap]::new($rect.R-$rect.L,$rect.B-$rect.T)
$graphics=[System.Drawing.Graphics]::FromImage($image)
$dc=$graphics.GetHdc()
try { $captured=[W3393]::PrintWindow($window,$dc,2) } finally {$graphics.ReleaseHdc($dc);$graphics.Dispose()}
try {if(-not $captured){throw 'Window capture failed'};$image.Save((Join-Path $PWD "evidence/$Label.png"))}finally{$image.Dispose()}
$element=[System.Windows.Automation.AutomationElement]::FromHandle($window)
$elements=$element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
@($elements|ForEach-Object{@{name=$_.Current.Name;role=$_.Current.ControlType.ProgrammaticName}})|ConvertTo-Json -Depth 4|Set-Content "evidence/$Label-ui.json"
@{action=$Action;x=$X;y=$Y;utc=[DateTime]::UtcNow.ToString('o');window=$window.ToInt64();view=$view.ToInt64()}|ConvertTo-Json|Set-Content "evidence/$Label-action.json"
