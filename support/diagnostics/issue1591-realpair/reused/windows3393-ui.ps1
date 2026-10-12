param([string]$Action='snapshot',[int]$X=0,[int]$Y=0,[string]$Label='snapshot',[switch]$RequireForeground,[switch]$UseControlSequence,[int]$ExpectedPid=0,[long]$ExpectedWindow=0,[string]$ExpectedFilename='',[switch]$AllowInfo)
$ErrorActionPreference='Stop'
function Write-DiagnosticPhase([string]$phase){
 @{utc=[DateTime]::UtcNow.ToString('o');phase=$phase}|ConvertTo-Json -Compress|Add-Content "evidence/$Label-phases.jsonl"
}
if(-not $global:Issue1591SendingUIAPrewarmed){
 $global:Issue1591SendingUIAPrewarmed=$true
 try{
  Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
  if(-not ('SendingUIA' -as [type])){Add-Type -ReferencedAssemblies @([System.Windows.Automation.AutomationElement].Assembly.Location,[System.Windows.Automation.ControlType].Assembly.Location,[System.Windows.Rect].Assembly.Location) @'
using System;using System.Collections.Generic;using System.Threading;using System.Windows.Automation;
public static class SendingUIA {
 public sealed class Node {public string Name;public int Pid;public bool Enabled;public bool Offscreen;public bool Invokable;public double X,Y,Width,Height;}
 public sealed class Result {public string Status="unavailable";public string Reason;public bool Attempted;public Node[] Before=new Node[0];public Node[] Fresh=new Node[0];public Node[] After=new Node[0];}
 static List<AutomationElement> Elements(AutomationElement root) {
  var rows=new List<AutomationElement>();var queue=new Queue<Tuple<AutomationElement,int>>();queue.Enqueue(Tuple.Create(root,0));
  while(queue.Count>0&&rows.Count<256) {var row=queue.Dequeue();rows.Add(row.Item1);if(row.Item2>=12)continue;
   for(var child=TreeWalker.ControlViewWalker.GetFirstChild(row.Item1);child!=null&&queue.Count+rows.Count<256;child=TreeWalker.ControlViewWalker.GetNextSibling(child))queue.Enqueue(Tuple.Create(child,row.Item2+1));}
  return rows;
 }
 static Node[] Describe(List<AutomationElement> elements) {
  var rows=new List<Node>();foreach(var element in elements){var c=element.Current;var b=c.BoundingRectangle;object pattern;
   rows.Add(new Node{Name=c.Name,Pid=c.ProcessId,Enabled=c.IsEnabled,Offscreen=c.IsOffscreen,Invokable=element.TryGetCurrentPattern(InvokePattern.Pattern,out pattern),X=b.X,Y=b.Y,Width=b.Width,Height=b.Height});}return rows.ToArray();
 }
 static bool Visible(Node n,int pid){return n.Pid==pid&&n.Enabled&&!n.Offscreen&&n.Width>0&&n.Height>0;}
 static int Candidate(Node[] rows,int pid,string filename) {
  bool title=false,footer=false;var files=new List<Node>();var errors=new List<Node>();
  foreach(var n in rows)if(Visible(n,pid)){title|=n.Name=="Sending files";if(n.Name!=null&&n.Name.Contains(filename))files.Add(n);footer|=n.Name=="Finished with error";if(n.Name=="Error")errors.Add(n);}
  if(!title||!footer||files.Count!=1||errors.Count!=1)return -1;
  var error=errors[0];var file=files[0];if(error.Y<file.Y+file.Height||error.Y-(file.Y+file.Height)>30||Math.Abs(error.X-file.X)>10)return -1;
  int selected=-1;
  for(int i=0;i<rows.Length;i++){var n=rows[i];if(Visible(n,pid)&&n.Invokable&&String.IsNullOrEmpty(n.Name)&&n.Width<=50&&n.Height<=50&&n.X>=error.X+error.Width&&n.X-(error.X+error.Width)<=30&&n.Y<error.Y+error.Height&&n.Y+n.Height>error.Y){if(selected!=-1)return -1;selected=i;}}
  return selected;
 }
 public static Result Observe(long hwnd,int pid,string filename,bool allowInfo) {
  var result=new Result();int inputState=0;var clock=System.Diagnostics.Stopwatch.StartNew();var thread=new Thread(()=>{try{
   var root=AutomationElement.FromHandle(new IntPtr(hwnd));if(root.Current.ProcessId!=pid)throw new InvalidOperationException("UIA root ownership differs");
   result.Before=Describe(Elements(root));var candidate=Candidate(result.Before,pid,filename);
   bool title=false,file=false,finished=false,error=false;foreach(var n in result.Before)if(Visible(n,pid)){title|=n.Name=="Sending files";file|=n.Name!=null&&n.Name.Contains(filename);finished|=n.Name=="Finished";error|=n.Name=="Finished with error";}
   result.Status=title&&file&&finished?"finished-observed":title&&file&&error?"transfer-error-observed":"text-unavailable-or-pending";
   if(!allowInfo){result.Reason="Read-only early observation; no input permitted";return;}
   if(candidate<0){result.Reason="No unique source-qualified transfer Error info InvokePattern; no input sent";return;}
   var fresh=Elements(root);result.Fresh=Describe(fresh);var current=Candidate(result.Fresh,pid,filename);
   if(current<0)throw new InvalidOperationException("Fresh Error info candidate absent or ambiguous");
   var a=result.Before[candidate];var b=result.Fresh[current];if(a.X!=b.X||a.Y!=b.Y||a.Width!=b.Width||a.Height!=b.Height)throw new InvalidOperationException("Qualified UIA bounds changed");
   object pattern;if(!fresh[current].TryGetCurrentPattern(InvokePattern.Pattern,out pattern))throw new InvalidOperationException("Fresh InvokePattern absent");
   if(clock.ElapsedMilliseconds>=1300||Interlocked.CompareExchange(ref inputState,1,0)!=0)throw new InvalidOperationException("Observation deadline reached before input; no input sent");
   result.Attempted=true;result.Status="invocation-indeterminate";((InvokePattern)pattern).Invoke();result.Status="info-invoked-awaiting-original-after-image";
   result.After=Describe(Elements(root));
  }catch(Exception e){result.Reason=e.GetType().Name+": "+e.Message;}});thread.IsBackground=true;thread.SetApartmentState(ApartmentState.MTA);thread.Start();
  if(!thread.Join(1500)){Interlocked.CompareExchange(ref inputState,2,0);return new Result{Status="UIA-deadline-indeterminate",Reason="UIA provider exceeded 1500ms; one request only, no replacement",Attempted=Volatile.Read(ref inputState)==1,Before=result.Before,Fresh=result.Fresh};}return result;
 }
}
'@}
  $global:Issue1591SendingUIAAvailable=$true
 }catch{$global:Issue1591SendingUIAAvailable=$false;$global:Issue1591SendingUIAReason=$_.Exception.Message}
 @{utc=[DateTime]::UtcNow.ToString('o');available=$global:Issue1591SendingUIAAvailable;reason=$global:Issue1591SendingUIAReason;authority='Assembly/type loading only; actual Flutter provider is not established'}|ConvertTo-Json|Set-Content 'evidence/sending-uia-prewarm.json'
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
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect rect);
 [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h,ref Point point);
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
 public static int[] FavoritesMatches(byte[] reference,byte[] image,int referenceStride,int imageStride) {
  const int cx=80,cy=165,cw=240,ch=145;
  var source=new int[400*500];var current=new int[400*500];
  for(int y=0;y<500;y++)for(int x=0;x<400;x++) {
   int a=y*referenceStride+x*4,b=y*imageStride+x*4;
   if(reference[a+3]!=255||image[b+3]!=255)throw new InvalidOperationException("Reference/current PNG is not uniformly opaque");
   source[y*400+x]=reference[a]|reference[a+1]<<8|reference[a+2]<<16;
   current[y*400+x]=image[b]|image[b+1]<<8|image[b+2]<<16;
  }
  var matches=new System.Collections.Generic.List<int>();
  int[] anchors={8*400+5,62*400+20,118*400+55,77*400+208};
  for(int y=0;y<=500-ch;y++)for(int x=0;x<=400-cw;x++) {
   bool equal=true;int start=y*400+x,original=cy*400+cx;
   foreach(int offset in anchors)if(current[start+offset]!=source[original+offset]){equal=false;break;}
   for(int dy=0;dy<ch&&equal;dy++)for(int dx=0;dx<cw;dx++)if(current[start+dy*400+dx]!=source[original+dy*400+dx]){equal=false;break;}
   if(equal){matches.Add(x);matches.Add(y);if(matches.Count>2)return matches.ToArray();}
  }
  return matches.ToArray();
 }
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
function Capture-OwnedWindow([IntPtr]$hwnd,[string]$path){
 $rect=New-Object W3393+Rect
 if(-not [W3393]::GetWindowRect($hwnd,[ref]$rect)){throw 'GetWindowRect failed'}
 $width=$rect.R-$rect.L;$height=$rect.B-$rect.T
 if($width -ne 400 -or $height -ne 500){throw "Unexpected captured window dimensions ${width}x${height}"}
 $bitmap=[System.Drawing.Bitmap]::new($width,$height,[System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
 try{
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try{$dc=$graphics.GetHdc();try{$captured=[W3393]::PrintWindow($hwnd,$dc,2)}finally{$graphics.ReleaseHdc($dc)}}finally{$graphics.Dispose()}
  if(-not $captured){throw 'PrintWindow failed'}
  $bitmap.Save((Join-Path $PWD $path),[System.Drawing.Imaging.ImageFormat]::Png)
 }finally{$bitmap.Dispose()}
 return $rect
}
function Assert-OwnedFavoritesWindow([IntPtr]$hwnd,[uint32]$ownerPid){
 if($hwnd -eq [IntPtr]::Zero -or -not [W3393]::IsWindowVisible($hwnd) -or -not [W3393]::IsWindowEnabled($hwnd)){throw 'Owned runner window absent, hidden or disabled'}
 $actualPid=0u;$thread=[W3393]::GetWindowThreadProcessId($hwnd,[ref]$actualPid)
 if($thread -eq 0 -or $actualPid -ne $ownerPid){throw 'Runner PID changed or native ownership query failed'}
 $cls=[System.Text.StringBuilder]::new(256);$title=[System.Text.StringBuilder]::new(512)
 if([W3393]::GetClassName($hwnd,$cls,256) -eq 0 -or [W3393]::GetWindowText($hwnd,$title,512) -eq 0){throw 'Native runner identity query failed'}
 if($cls.ToString() -ne 'FLUTTER_RUNNER_WIN32_WINDOW' -or $title.ToString() -ne 'LocalSend'){throw 'Runner identity changed'}
 $process=Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction Stop
 if(-not $process -or $process.Name -notmatch '^localsend'){throw 'Runner executable identity changed'}
 $launchReport=Get-Content 'evidence/release-ui-report.json' -Raw|ConvertFrom-Json
 if(-not $launchReport.executable.path -or -not $process.ExecutablePath -or $process.ExecutablePath -ine $launchReport.executable.path){throw 'Runner executable differs from owned launch report'}
 $children=@([W3393]::Children($hwnd));$views=@($children|Where-Object {$_.cls -eq 'FLUTTERVIEW' -and $_.pid -eq $ownerPid})
 if($views.Count -ne 1){throw 'Unique owned FLUTTERVIEW absent'}
 $view=[IntPtr]$views[0].hwnd;$viewScreenRect=New-Object W3393+Rect
 if(-not [W3393]::GetWindowRect($view,[ref]$viewScreenRect) -or $viewScreenRect.R-$viewScreenRect.L -ne 384 -or $viewScreenRect.B-$viewScreenRect.T -ne 461){throw 'Checked owned 384x461 FLUTTERVIEW absent'}
 if(-not [W3393]::IsWindowVisible($view) -or -not [W3393]::IsWindowEnabled($view)){throw 'Owned FLUTTERVIEW hidden or disabled'}
 $otherVisible=@([W3393]::OwnedWindows($ownerPid)|Where-Object {$_.visible -and $_.hwnd -ne $hwnd.ToInt64()})
 if($otherVisible.Count){throw 'Another owned visible window prevents input'}
 return @{view=$view;viewScreenRect=$viewScreenRect;children=$children;processName=$process.Name;executablePath=$process.ExecutablePath}
}
function Find-FavoritesTemplate([string]$imagePath,[string]$referencePath){
 $reference=[System.Drawing.Bitmap]::new($referencePath);$image=[System.Drawing.Bitmap]::new((Join-Path $PWD $imagePath))
 try{
  if($reference.Width -ne 400 -or $reference.Height -ne 500 -or $image.Width -ne 400 -or $image.Height -ne 500){throw 'Reference or current PNG dimensions differ from pinned 400x500'}
  # Reviewed original crop: title, complete peer alias/address, edit pencil, Error and orange information icon.
  $crop=@{x=80;y=165;width=240;height=145};$rectangle=[System.Drawing.Rectangle]::new(0,0,400,500)
  $referenceData=$null;$imageData=$null
  try{
   $referenceData=$reference.LockBits($rectangle,[System.Drawing.Imaging.ImageLockMode]::ReadOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
   $imageData=$image.LockBits($rectangle,[System.Drawing.Imaging.ImageLockMode]::ReadOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
   if($referenceData.Stride -le 0 -or $imageData.Stride -le 0){throw 'Unsupported native bitmap stride'}
   $referenceBytes=[byte[]]::new($referenceData.Stride*500);$imageBytes=[byte[]]::new($imageData.Stride*500)
   [Runtime.InteropServices.Marshal]::Copy($referenceData.Scan0,$referenceBytes,0,$referenceBytes.Length)
   [Runtime.InteropServices.Marshal]::Copy($imageData.Scan0,$imageBytes,0,$imageBytes.Length)
   $matches=[W3393]::FavoritesMatches($referenceBytes,$imageBytes,$referenceData.Stride,$imageData.Stride)
  }finally{if($imageData){$image.UnlockBits($imageData)};if($referenceData){$reference.UnlockBits($referenceData)}}
  if($matches.Length -ne 2){throw "Semantic Favorites template is absent or nonunique ($($matches.Length/2) observed matches)"}
  # Reference icon center was visually reviewed at original bitmap pixel (135,289).
  return @{crop=$crop;match=@{x=$matches[0];y=$matches[1]};bitmapPoint=@{x=$matches[0]+55;y=$matches[1]+124};referenceIconCenter=@{x=135;y=289};referenceIconBounds=@{left=127;top=281;right=143;bottom=297}}
 }finally{$image.Dispose();$reference.Dispose()}
}
function Capture-FavoritesError{
 $receipt=@{utc=[DateTime]::UtcNow.ToString('o');action='favorites-error';attempted=$false;status='evidence-unavailable';expectedPid=$ExpectedPid;expectedWindow=$ExpectedWindow;reference='reused/favorites-error-reference.png';referenceSha256='1fd999ee157f7a38a40419dab5565212e5d1fb04aa2c9f1d7cb77b1b578602be';referenceCrop=@{x=80;y=165;width=240;height=145};referenceIconCenter=@{x=135;y=289}}
 $prefix="evidence/$Label";$hwnd=[IntPtr]$ExpectedWindow
 $receipt.originals=@{before="$prefix-before.png";focusedBefore="$prefix-focused-before.png";after="$prefix-after.png"}
 try{
  if($ExpectedPid -le 0 -or $ExpectedWindow -le 0){throw 'Owned baseline PID/HWND missing'}
  $reference=Join-Path $PSScriptRoot 'favorites-error-reference.png'
  if((Get-FileHash -Algorithm SHA256 $reference).Hash.ToLowerInvariant() -ne $receipt.referenceSha256){throw 'Pinned Favorites reference hash mismatch'}
  $owned=Assert-OwnedFavoritesWindow $hwnd ([uint32]$ExpectedPid)
  $beforeRect=Capture-OwnedWindow $hwnd "$prefix-before.png"
  $receipt.beforeUtc=[DateTime]::UtcNow.ToString('o');$receipt.beforeRect=$beforeRect;$receipt.beforeTree=$owned.children;$receipt.executablePath=$owned.executablePath
  $receipt.beforeSha256=(Get-FileHash -Algorithm SHA256 "$prefix-before.png").Hash.ToLowerInvariant()
  $before=Find-FavoritesTemplate "$prefix-before.png" $reference;$receipt.beforeMatch=$before
  $front=[W3393]::GetForegroundWindow();$frontPid=0u;$frontThread=[W3393]::GetWindowThreadProcessId($front,[ref]$frontPid)
  $appPid=0u;$appThread=[W3393]::GetWindowThreadProcessId($hwnd,[ref]$appPid);$currentThread=[W3393]::GetCurrentThreadId();$attached=@()
  try{
   foreach($thread in (@($frontThread,$appThread)|Select-Object -Unique)){if($thread -ne 0 -and $thread -ne $currentThread -and [W3393]::AttachThreadInput($currentThread,$thread,$true)){$attached+=$thread}}
   $receipt.focusResult=[W3393]::SetForegroundWindow($hwnd)
   [void][W3393]::SetFocus($owned.view)
   $foreground=[W3393]::GetForegroundWindow();$foregroundPid=0u;[void][W3393]::GetWindowThreadProcessId($foreground,[ref]$foregroundPid)
   $receipt.foreground=@{hwnd=$foreground.ToInt64();pid=$foregroundPid}
   if($foreground -ne $hwnd -or $foregroundPid -ne $ExpectedPid){throw 'Owned runner foreground not verified'}
  }finally{foreach($thread in $attached){[void][W3393]::AttachThreadInput($currentThread,$thread,$false)}}
  $owned=Assert-OwnedFavoritesWindow $hwnd ([uint32]$ExpectedPid)
  $freshRect=Capture-OwnedWindow $hwnd "$prefix-focused-before.png"
  $receipt.focusedBeforeUtc=[DateTime]::UtcNow.ToString('o');$receipt.focusedRect=$freshRect;$receipt.focusedTree=$owned.children
  $receipt.focusedBeforeSha256=(Get-FileHash -Algorithm SHA256 "$prefix-focused-before.png").Hash.ToLowerInvariant()
  $match=Find-FavoritesTemplate "$prefix-focused-before.png" $reference;$receipt.focusedMatch=$match
  $liveRect=New-Object W3393+Rect
  if(-not [W3393]::GetWindowRect($hwnd,[ref]$liveRect) -or $liveRect.L -ne $freshRect.L -or $liveRect.T -ne $freshRect.T -or $liveRect.R -ne $freshRect.R -or $liveRect.B -ne $freshRect.B){throw 'Window moved after qualified capture'}
  $liveViewRect=New-Object W3393+Rect
  if(-not [W3393]::GetWindowRect($owned.view,[ref]$liveViewRect) -or $liveViewRect.L -ne $owned.viewScreenRect.L -or $liveViewRect.T -ne $owned.viewScreenRect.T -or $liveViewRect.R -ne $owned.viewScreenRect.R -or $liveViewRect.B -ne $owned.viewScreenRect.B){throw 'FLUTTERVIEW moved after qualified capture'}
  $screen=New-Object W3393+Point;$screen.X=$liveRect.L+$match.bitmapPoint.x;$screen.Y=$liveRect.T+$match.bitmapPoint.y
  $runnerPoint=New-Object W3393+Point;$runnerPoint.X=$screen.X;$runnerPoint.Y=$screen.Y
  if(-not [W3393]::ScreenToClient($hwnd,[ref]$runnerPoint)){throw 'ScreenToClient failed'}
  $runnerRect=New-Object W3393+Rect
  if(-not [W3393]::GetClientRect($hwnd,[ref]$runnerRect) -or $runnerPoint.X -lt 0 -or $runnerPoint.Y -lt 0 -or $runnerPoint.X -ge $runnerRect.R -or $runnerPoint.Y -ge $runnerRect.B){throw 'Mapped point outside runner client'}
  $target=[W3393]::ChildWindowFromPointEx($hwnd,$runnerPoint,1)
  if($target -ne $owned.view){throw 'Qualified point does not hit unique FLUTTERVIEW'}
  $viewPoint=New-Object W3393+Point;$viewPoint.X=$screen.X;$viewPoint.Y=$screen.Y
  if(-not [W3393]::ScreenToClient($target,[ref]$viewPoint)){throw 'FLUTTERVIEW ScreenToClient failed'}
  $viewRect=New-Object W3393+Rect
  if(-not [W3393]::GetClientRect($target,[ref]$viewRect) -or $viewPoint.X -lt 0 -or $viewPoint.Y -lt 0 -or $viewPoint.X -ge $viewRect.R -or $viewPoint.Y -ge $viewRect.B){throw 'Mapped point outside FLUTTERVIEW client'}
  $targetPid=0u;$targetThread=[W3393]::GetWindowThreadProcessId($target,[ref]$targetPid);$targetClass=[System.Text.StringBuilder]::new(256)
  if($targetThread -eq 0 -or $targetPid -ne $ExpectedPid -or [W3393]::GetClassName($target,$targetClass,256) -eq 0 -or $targetClass.ToString() -ne 'FLUTTERVIEW'){throw 'Mapped target PID/class changed or query failed'}
  $receipt.mapping=@{bitmap=$match.bitmapPoint;screen=@{x=$screen.X;y=$screen.Y};runnerClient=@{x=$runnerPoint.X;y=$runnerPoint.Y};viewClient=@{x=$viewPoint.X;y=$viewPoint.Y};runnerClientRect=$runnerRect;viewClientRect=$viewRect;viewScreenRect=$liveViewRect;targetHwnd=$target.ToInt64();targetPid=$targetPid;targetClass=$targetClass.ToString()}
  if([W3393]::GetForegroundWindow() -ne $hwnd){throw 'Foreground changed before input'}
  $packed=[IntPtr](($viewPoint.Y -shl 16) -bor ($viewPoint.X -band 0xffff))
  $receipt.attempted=$true;$receipt.inputUtc=[DateTime]::UtcNow.ToString('o')
  $posted=[W3393]::ControlClick($target,$packed);$receipt.posted=$posted
  if($posted -contains $false){throw 'One or more ordinary mouse messages failed'}
  Start-Sleep -Milliseconds 800
  $receipt.status='input-posted-awaiting-after-image'
 }catch{$receipt.reason=$_.Exception.Message}finally{
  try{
   $afterPid=0u;[void][W3393]::GetWindowThreadProcessId($hwnd,[ref]$afterPid)
   if($afterPid -ne $ExpectedPid -or $afterPid -eq 0){throw 'Owned HWND/PID absent for after image'}
   $receipt.afterRect=Capture-OwnedWindow $hwnd "$prefix-after.png";$receipt.afterUtc=[DateTime]::UtcNow.ToString('o')
   $receipt.afterSha256=(Get-FileHash -Algorithm SHA256 "$prefix-after.png").Hash.ToLowerInvariant()
   $receipt.afterTree=(Assert-OwnedFavoritesWindow $hwnd ([uint32]$ExpectedPid)).children
   if($receipt.status -eq 'input-posted-awaiting-after-image'){$receipt.status='after-image-retained-for-readable-dialog-review'}
  }catch{$receipt.afterCaptureError=$_.Exception.Message;$receipt.status='evidence-unavailable';if(-not $receipt.reason){$receipt.reason=$receipt.afterCaptureError}}
  $receipt|ConvertTo-Json -Depth 10|Set-Content "$prefix-receipt.json"
 }
 if($receipt.status -ne 'after-image-retained-for-readable-dialog-review'){throw "Favorites ErrorDialog evidence unavailable: $($receipt.reason)"}
}
function Capture-SendingOutcome{
 $prefix="evidence/$Label";$hwnd=[IntPtr]$ExpectedWindow
 $receipt=@{utc=[DateTime]::UtcNow.ToString('o');action='sending-outcome';expectedPid=$ExpectedPid;expectedWindow=$ExpectedWindow;filename=$ExpectedFilename;allowInfo=[bool]$AllowInfo;attempted=$false;status='evidence-unavailable';uiaLimitMs=1500}
 try{
  if($ExpectedPid -le 0 -or $ExpectedWindow -le 0 -or -not $ExpectedFilename){throw 'Owned sender identity/file absent'}
  $owned=Assert-OwnedFavoritesWindow $hwnd ([uint32]$ExpectedPid)
  $receipt.executablePath=$owned.executablePath;$receipt.beforeRect=Capture-OwnedWindow $hwnd "$prefix-before.png";$receipt.beforeUtc=[DateTime]::UtcNow.ToString('o')
  $receipt.beforeSha256=(Get-FileHash -Algorithm SHA256 "$prefix-before.png").Hash.ToLowerInvariant()
  if($global:Issue1591SendingUIAAvailable){$observed=[SendingUIA]::Observe($ExpectedWindow,$ExpectedPid,$ExpectedFilename,[bool]$AllowInfo);$receipt.uia=$observed;$receipt.attempted=$observed.Attempted;$receipt.status=$observed.Status}
  else{$receipt.status='UIA-unavailable';$receipt.reason=$global:Issue1591SendingUIAReason}
 }catch{$receipt.reason=$_.Exception.Message}finally{
  try{
   $afterOwned=Assert-OwnedFavoritesWindow $hwnd ([uint32]$ExpectedPid)
   $receipt.afterRect=Capture-OwnedWindow $hwnd "$prefix-after.png";$receipt.afterUtc=[DateTime]::UtcNow.ToString('o');$receipt.afterTree=$afterOwned.children
   $receipt.afterSha256=(Get-FileHash -Algorithm SHA256 "$prefix-after.png").Hash.ToLowerInvariant()
  }catch{$receipt.afterCaptureError=$_.Exception.Message}
  $receipt|ConvertTo-Json -Depth 12|Set-Content "$prefix-receipt.json"
 }
 # Opaque UIA does not suppress the original pixels or claim a sender result.
 if($receipt.status -eq 'evidence-unavailable' -or $receipt.afterCaptureError){throw 'Owned sender outcome pixels unavailable'}
}
if($Action -eq 'favorites-error'){Capture-FavoritesError;return}
if($Action -eq 'sending-outcome'){Capture-SendingOutcome;return}
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
