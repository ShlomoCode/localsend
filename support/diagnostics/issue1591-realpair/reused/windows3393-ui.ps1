param([string]$Action='snapshot',[int]$X=0,[int]$Y=0,[string]$Label='snapshot',[switch]$RequireForeground,[switch]$UseControlSequence)
$ErrorActionPreference='Stop'
function Write-DiagnosticPhase([string]$phase){
 @{utc=[DateTime]::UtcNow.ToString('o');phase=$phase}|ConvertTo-Json -Compress|Add-Content "evidence/$Label-phases.jsonl"
}
Write-DiagnosticPhase 'before-drawing-assembly'
Add-Type -AssemblyName System.Drawing
Write-DiagnosticPhase 'before-native-type-compilation'
if(-not ('W3393' -as [type])){Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class W3393 {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
 [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr h,Point p,uint flags);
 [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from,IntPtr to,ref Point p,uint count);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 public delegate bool EnumProc(IntPtr h,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc callback,IntPtr data);
 public struct Point { public int X,Y; }
 public static bool[] ControlClick(IntPtr target,IntPtr point) {
  bool move=PostMessage(target,0x0200,IntPtr.Zero,point);
  bool down=PostMessage(target,0x0201,new IntPtr(1),point);
  bool up=PostMessage(target,0x0202,IntPtr.Zero,point);
  return new[]{move,down,up};
 }
 public static object[] Children(IntPtr parent) {
  var rows=new System.Collections.Generic.List<object>();
  EnumChildWindows(parent,(h,data)=>{uint pid;GetWindowThreadProcessId(h,out pid);var s=new StringBuilder(256);GetClassName(h,s,256);Rect r;GetWindowRect(h,out r);rows.Add(new{hwnd=h.ToInt64(),parent=GetParent(h).ToInt64(),pid=pid,cls=s.ToString(),rect=r});return true;},IntPtr.Zero);
  return rows.ToArray();
 }
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr data);
 public static object[] OwnedWindows(uint targetPid) {
  var rows=new System.Collections.Generic.List<object>();
  EnumWindows((h,data)=>{uint pid;GetWindowThreadProcessId(h,out pid);if(pid==targetPid){var cls=new StringBuilder(256);var title=new StringBuilder(512);GetClassName(h,cls,256);GetWindowText(h,title,512);rows.Add(new{hwnd=h.ToInt64(),pid=pid,cls=cls.ToString(),title=title.ToString(),visible=IsWindowVisible(h),enabled=IsWindowEnabled(h)});}return true;},IntPtr.Zero);
  return rows.ToArray();
 }
 public struct Rect { public int L,T,R,B; }
}
'@
}
Write-DiagnosticPhase 'before-find-window'
$window=[W3393]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW','LocalSend')
if($window -eq [IntPtr]::Zero){throw 'No LocalSend window'}
Write-DiagnosticPhase 'before-child-enumeration'
[W3393]::Children($window)|ConvertTo-Json -Depth 5|Set-Content "evidence/$Label-hwnd-tree.json"
Write-DiagnosticPhase 'after-child-enumeration'
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
$focusEvidence=$null
$focusFailed=$false
$foregroundInfo=$null
$inputEvidence=$null
if($Action -eq 'click'){
 Write-DiagnosticPhase 'before-foreground-observation'
 $beforeForeground=[W3393]::GetForegroundWindow()
 $beforePid=0u
 $foregroundThread=[W3393]::GetWindowThreadProcessId($beforeForeground,[ref]$beforePid)
 $foregroundTitle=[System.Text.StringBuilder]::new(512)
 $foregroundClass=[System.Text.StringBuilder]::new(256)
 [void][W3393]::GetWindowText($beforeForeground,$foregroundTitle,512)
 [void][W3393]::GetClassName($beforeForeground,$foregroundClass,256)
 $foregroundProcess=Get-CimInstance Win32_Process -Filter "ProcessId = $beforePid" -ErrorAction SilentlyContinue
 $foregroundInfo=@{hwnd=$beforeForeground.ToInt64();pid=$beforePid;title=$foregroundTitle.ToString();class=$foregroundClass.ToString();processName=$foregroundProcess.Name;executablePath=$foregroundProcess.ExecutablePath;parentPid=$foregroundProcess.ParentProcessId}
 $appThread=[W3393]::GetWindowThreadProcessId($window,[ref]$appPid)
 $currentThread=[W3393]::GetCurrentThreadId()
 $attachedThreads=@()
 $attachmentAttempts=@()
 if($RequireForeground){
  foreach($thread in (@($foregroundThread,$appThread)|Select-Object -Unique)){
   if($thread -ne 0 -and $thread -ne $currentThread){
    $attached=[W3393]::AttachThreadInput($currentThread,$thread,$true)
    $attachmentAttempts+=@{from=$currentThread;to=$thread;success=$attached}
    if($attached){$attachedThreads+=$thread}
   }
  }
 }
 try{
  $foregroundResult=[W3393]::SetForegroundWindow($window)
  $previousFocus=if($RequireForeground){[W3393]::SetFocus($view)}else{[IntPtr]::Zero}
  $clickForeground=[W3393]::GetForegroundWindow()
  $clickPid=0u;[void][W3393]::GetWindowThreadProcessId($clickForeground,[ref]$clickPid)
  $focusFailed=$RequireForeground -and ($clickPid -ne $appPid -or $clickForeground -ne $window)
  $focusEvidence=@{required=[bool]$RequireForeground;beforeHwnd=$beforeForeground.ToInt64();beforePid=$beforePid;attachmentAttempts=$attachmentAttempts;attachedThreads=$attachedThreads;setForegroundResult=$foregroundResult;previousFocus=$previousFocus.ToInt64();beforeClickHwnd=$clickForeground.ToInt64();beforeClickPid=$clickPid;verified=(-not $focusFailed)}
 }finally{
  foreach($thread in $attachedThreads){[void][W3393]::AttachThreadInput($currentThread,$thread,$false)}
 }
 if(-not $focusFailed){
 Write-DiagnosticPhase 'before-input'
 $packed=[IntPtr](($point.Y -shl 16) -bor ($point.X -band 0xffff))
 if($UseControlSequence){
  $posted=[W3393]::ControlClick($view,$packed)
  $inputEvidence=@{method='Control C# consecutive PostMessage';intervalMs=0;posted=$posted}
  if($posted -contains $false){throw 'Control input message failed'}
 }else{
 if(-not [W3393]::PostMessage($view,0x200,[IntPtr]::Zero,$packed)){throw 'Mouse move failed'}
 if(-not [W3393]::PostMessage($view,0x201,[IntPtr]1,$packed)){throw 'Mouse down failed'}
 Start-Sleep -Milliseconds 80
 if(-not [W3393]::PostMessage($view,0x202,[IntPtr]::Zero,$packed)){throw 'Mouse up failed'}
 $inputEvidence=@{method='PowerShell spaced PostMessage';intervalMs=80}
 }
 Start-Sleep -Milliseconds 800
 Write-DiagnosticPhase 'after-input'
 }
}
$rect=New-Object W3393+Rect
Write-DiagnosticPhase 'before-window-capture'
[void][W3393]::GetWindowRect($window,[ref]$rect)
$image=[System.Drawing.Bitmap]::new($rect.R-$rect.L,$rect.B-$rect.T)
$graphics=[System.Drawing.Graphics]::FromImage($image)
$dc=$graphics.GetHdc()
try { $captured=[W3393]::PrintWindow($window,$dc,2) } finally {$graphics.ReleaseHdc($dc);$graphics.Dispose()}
try {if(-not $captured){throw 'Window capture failed'};$image.Save((Join-Path $PWD "evidence/$Label.png"))}finally{$image.Dispose()}
Write-DiagnosticPhase 'after-window-capture'
@{captured=$false;reason='Accessibility collection disabled for diagnostic CLR isolation; earlier captures exposed only FLUTTERVIEW pane'}|ConvertTo-Json|Set-Content "evidence/$Label-ui.json"
$foreground=[W3393]::GetForegroundWindow()
$foregroundPid=0u;[void][W3393]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)
@{action=$Action;x=$X;y=$Y;targetX=$point.X;targetY=$point.Y;targetClass=$targetClass.ToString();appPid=$appPid;targetPid=$viewPid;utc=[DateTime]::UtcNow.ToString('o');window=$window.ToInt64();view=$view.ToInt64();foregroundBefore=$foregroundInfo;focus=$focusEvidence;input=$inputEvidence;foregroundHwnd=$foreground.ToInt64();foregroundPid=$foregroundPid;ownedWindows=[W3393]::OwnedWindows($appPid)}|ConvertTo-Json -Depth 6|Set-Content "evidence/$Label-action.json"
Write-DiagnosticPhase 'complete'
if($focusFailed){throw 'Original LocalSend foreground could not be established; File click was not sent'}
