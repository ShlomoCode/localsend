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
 [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr h,Point p,uint flags);
 [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from,IntPtr to,ref Point p,uint count);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
 public delegate bool EnumProc(IntPtr h,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc callback,IntPtr data);
 public struct Point { public int X,Y; }
 public static object[] Children(IntPtr parent) {
  var rows=new System.Collections.Generic.List<object>();
  EnumChildWindows(parent,(h,data)=>{uint pid;GetWindowThreadProcessId(h,out pid);var s=new StringBuilder(256);GetClassName(h,s,256);Rect r;GetWindowRect(h,out r);rows.Add(new{hwnd=h.ToInt64(),parent=GetParent(h).ToInt64(),pid=pid,cls=s.ToString(),rect=r});return true;},IntPtr.Zero);
  return rows.ToArray();
 }
 public struct Rect { public int L,T,R,B; }
}
'@
$window=[W3393]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW','LocalSend')
if($window -eq [IntPtr]::Zero){throw 'No LocalSend window'}
[W3393]::Children($window)|ConvertTo-Json -Depth 5|Set-Content "evidence/$Label-hwnd-tree.json"
$view=$window
$point=New-Object W3393+Point
$point.X=$X;$point.Y=$Y
for($depth=0;$depth -lt 8;$depth++){
 $child=[W3393]::ChildWindowFromPointEx($view,$point,1)
 if($child -eq [IntPtr]::Zero -or $child -eq $view){break}
 [void][W3393]::MapWindowPoints($view,$child,[ref]$point,1)
 $view=$child
}
$appPid=0u;$viewPid=0u
[void][W3393]::GetWindowThreadProcessId($window,[ref]$appPid)
[void][W3393]::GetWindowThreadProcessId($view,[ref]$viewPid)
if($appPid -ne $viewPid){throw 'Input target belongs to another process'}
$targetClass=[System.Text.StringBuilder]::new(256)
[void][W3393]::GetClassName($view,$targetClass,256)
if($Action -eq 'click'){
 [void][W3393]::SetForegroundWindow($window)
 $packed=[IntPtr](($point.Y -shl 16) -bor ($point.X -band 0xffff))
 if(-not [W3393]::PostMessage($view,0x200,[IntPtr]::Zero,$packed)){throw 'Mouse move failed'}
 if(-not [W3393]::PostMessage($view,0x201,[IntPtr]1,$packed)){throw 'Mouse down failed'}
 Start-Sleep -Milliseconds 80
 if(-not [W3393]::PostMessage($view,0x202,[IntPtr]::Zero,$packed)){throw 'Mouse up failed'}
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
@{action=$Action;x=$X;y=$Y;targetX=$point.X;targetY=$point.Y;targetClass=$targetClass.ToString();appPid=$appPid;targetPid=$viewPid;utc=[DateTime]::UtcNow.ToString('o');window=$window.ToInt64();view=$view.ToInt64()}|ConvertTo-Json|Set-Content "evidence/$Label-action.json"
