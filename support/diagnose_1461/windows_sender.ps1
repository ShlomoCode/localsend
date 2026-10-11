# Run only in an isolated cloud Windows desktop. No app binaries or profiles are changed.
# Atomically submit commands/<id>.json; wait for results/<id>.json before sending another.
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[int]$TimeoutSeconds=5400,[string]$ReceiverName='')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$commands=Join-Path $OutputDirectory 'commands'; $results=Join-Path $OutputDirectory 'results'
[void][IO.Directory]::CreateDirectory($commands); [void][IO.Directory]::CreateDirectory($results)
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$report=[ordered]@{status='starting';startedUtc=[DateTime]::UtcNow.ToString('o');release='1.14.0';artifactUrl='https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-windows-x86-64.zip';environmentScope='Actual OS is recorded below. Windows Server is supplementary to reported Windows 11. Loopback relay differs from LAN.';runner=$env:RUNNER_NAME;image=$env:ImageOS;os=$null;archive=$null;executable=$null;processId=$null;fixtures=@{};actions=@();errors=@();terminalError=$null;reporter10054Observed=$false;networkInterruption=$null;quit=$null}
$statusPath=Join-Path $OutputDirectory 'status.json'; $readyPath=Join-Path $OutputDirectory 'ready.json'
$app=$null; $appHwnd=[IntPtr]::Zero; $rule=$null; $sequence=0
function Json($path,$value) { [IO.File]::WriteAllText("$path.tmp",(ConvertTo-Json -InputObject $value -Depth 15),[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath "$path.tmp" -Destination $path -Force }
function Persist { Json $statusPath $report }
function Remaining([int]$maximum=30000) { $r=[int][Math]::Min($maximum,($deadline-[DateTime]::UtcNow).TotalMilliseconds); if($r -le 0){throw 'Diagnostic deadline expired.'}; return $r }
trap { $report.status='failed';$report.errors+=$_.Exception.ToString(); Persist; exit 1 }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class ReceiverWindow {
 public int Pid; public long Hwnd; public string Title, ClassName;
 public bool Visible; public int Left, Top, Width, Height;
}
public static class ReceiverNative {
 [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X,Y; }
 private delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] private static extern bool ScreenToClient(IntPtr hwnd,ref POINT point);
 [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll")] private static extern IntPtr ChildWindowFromPointEx(IntPtr hwnd,POINT point,uint flags);
 [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from,IntPtr to,ref POINT point,uint count);
 [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
 public static string Downloads() {
  Guid id=new Guid("374DE290-123F-4565-9164-39C4925E467B"); IntPtr path;
  int result=SHGetKnownFolderPath(ref id,0,IntPtr.Zero,out path);
  if(result!=0) Marshal.ThrowExceptionForHR(result);
  try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
 }
 public static ReceiverWindow[] All() {
  var result=new List<ReceiverWindow>();
  EnumWindows((hwnd,data)=>{
   uint pid; GetWindowThreadProcessId(hwnd,out pid); RECT rect; GetWindowRect(hwnd,out rect);
   var title=new StringBuilder(1024); var cls=new StringBuilder(256);
   GetWindowText(hwnd,title,title.Capacity); GetClassName(hwnd,cls,cls.Capacity);
   result.Add(new ReceiverWindow { Pid=(int)pid,Hwnd=hwnd.ToInt64(),Title=title.ToString(),ClassName=cls.ToString(),
    Visible=IsWindowVisible(hwnd),Left=rect.Left,Top=rect.Top,Width=rect.Right-rect.Left,Height=rect.Bottom-rect.Top });
   return true;
  },IntPtr.Zero); return result.ToArray();
 }
 public static bool Activate(IntPtr hwnd) { ShowWindow(hwnd,9); return SetForegroundWindow(hwnd); }
 public static bool ClickScreen(IntPtr app,int x,int y) {
  POINT point=new POINT { X=x,Y=y }; RECT rect;
  if(!IsWindowVisible(app)||!ScreenToClient(app,ref point)||!GetClientRect(app,out rect)||
   point.X<0||point.Y<0||point.X>=rect.Right||point.Y>=rect.Bottom) return false;
  IntPtr target=app;
  for(int depth=0;depth<4;depth++) {
   IntPtr child=ChildWindowFromPointEx(target,point,1);
   if(child==IntPtr.Zero||child==target) break;
   MapWindowPoints(target,child,ref point,1); target=child;
  }
  uint owner,childOwner; GetWindowThreadProcessId(app,out owner); GetWindowThreadProcessId(target,out childOwner);
  if(owner!=childOwner) return false;
  IntPtr packed=new IntPtr((point.Y<<16)|(point.X&0xFFFF));
  return PostMessage(target,0x0200,IntPtr.Zero,packed)&&PostMessage(target,0x0201,new IntPtr(1),packed)&&PostMessage(target,0x0202,IntPtr.Zero,packed);
 }
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class SenderControl {
 public long Hwnd,Parent; public int Pid,Id,Left,Top,Width,Height;
 public string ClassName,Text; public bool Visible,Enabled,FileNameAncestor;
}
public static class SenderInput {
 [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left,Top,Right,Bottom; }
 private delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] private static extern IntPtr GetParent(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd,StringBuilder text,int size);
 public static SenderControl[] Children(IntPtr root) {
  var controls=new List<SenderControl>();
  EnumChildWindows(root,(hwnd,data)=>{
   uint pid;GetWindowThreadProcessId(hwnd,out pid);RECT r;GetWindowRect(hwnd,out r);
   var text=new StringBuilder(32768);var cls=new StringBuilder(256);GetWindowText(hwnd,text,text.Capacity);GetClassName(hwnd,cls,cls.Capacity);
   bool filename=false;IntPtr parent=hwnd;
   for(int depth=0;depth<16&&parent!=IntPtr.Zero&&parent!=root;depth++){if(GetDlgCtrlID(parent)==1148)filename=true;parent=GetParent(parent);}
   controls.Add(new SenderControl {Hwnd=hwnd.ToInt64(),Parent=GetParent(hwnd).ToInt64(),Pid=(int)pid,Id=GetDlgCtrlID(hwnd),Left=r.Left,Top=r.Top,Width=r.Right-r.Left,Height=r.Bottom-r.Top,ClassName=cls.ToString(),Text=text.ToString(),Visible=IsWindowVisible(hwnd),Enabled=IsWindowEnabled(hwnd),FileNameAncestor=filename});return true;
  },IntPtr.Zero);return controls.ToArray();
 }
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wp,IntPtr lp);
 public static void Click(int x,int y) { SetCursorPos(x,y); mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero); }
}
'@
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$ocrWorker=Join-Path $OutputDirectory 'ocr-worker.ps1'
[IO.File]::WriteAllText($ocrWorker,@'
param([string]$Image,[string]$Result,[string]$DeadlineUtc)
$ErrorActionPreference='Stop'
$deadline=[DateTime]::Parse($DeadlineUtc).ToUniversalTime()
$report=@{status='unsupported';image=$Image;words=@()}
try {
 Add-Type -AssemblyName System.Runtime.WindowsRuntime
 [void][Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
 [void][Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
 [void][Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
 [void][Windows.Globalization.Language,Windows.Globalization,ContentType=WindowsRuntime]
 function Await($Operation,[Type]$Type) {
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $task=$method.MakeGenericMethod($Type).Invoke($null,@($Operation))
  $remaining=[int][Math]::Max(0,($deadline-[DateTime]::UtcNow).TotalMilliseconds)
  if($remaining -le 0 -or -not $task.Wait($remaining)) { throw 'Native OCR worker deadline expired.' }
  return $task.Result
 }
 $file=Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Image)) ([Windows.Storage.StorageFile])
 $stream=Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
 try {
  $decoder=Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap=Await ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,[Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)) ([Windows.Graphics.Imaging.SoftwareBitmap])
  try {
   $engine=[Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('en-US'))
   if($null -eq $engine) { throw 'Native Windows OCR en-US language is unavailable.' }
   $recognized=Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
   $report.status='recognized'; $report.text=$recognized.Text; $report.textAngle=$recognized.TextAngle
   foreach($line in $recognized.Lines) { foreach($word in $line.Words) {
    $r=$word.BoundingRect; $report.words+=@{text=$word.Text;x=$r.X;y=$r.Y;width=$r.Width;height=$r.Height}
   } }
  } finally { $bitmap.Dispose() }
 } finally { $stream.Dispose() }
} catch { $report.error=$_.Exception.ToString() }
[IO.File]::WriteAllText($Result,(ConvertTo-Json $report -Depth 8),[Text.UTF8Encoding]::new($false))
'@,[Text.UTF8Encoding]::new($false))
$uiaWorker=Join-Path $OutputDirectory 'uia-worker.ps1'
[IO.File]::WriteAllText($uiaWorker,@'
param([long]$Hwnd,[string]$Result,[string]$Operation='snapshot',[string]$Value)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new($Hwnd))
$elements=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
$tree=@()
function Finite([double]$v){if([double]::IsNaN($v) -or [double]::IsInfinity($v)){return $null};return $v}
foreach($e in $elements){try{$v=$e.Current;$b=$v.BoundingRectangle;$tree+=@{name=$v.Name;id=$v.AutomationId;type=$v.ControlType.ProgrammaticName;offscreen=$v.IsOffscreen;enabled=$v.IsEnabled;x=(Finite $b.X);y=(Finite $b.Y);width=(Finite $b.Width);height=(Finite $b.Height)}}catch{};if($tree.Count -ge 700){break}}
$r=@{tree=$tree;acted=$false}
[IO.File]::WriteAllText($Result,(ConvertTo-Json $r -Depth 8),[Text.UTF8Encoding]::new($false))
'@,[Text.UTF8Encoding]::new($false))
function Worker($script,$arguments,$result,[int]$timeout=20000){
 if(Test-Path $result){Remove-Item -LiteralPath $result}
 $stdout=$result+'.stdout.txt';$stderr=$result+'.stderr.txt'
 $process=Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'))+$arguments) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
 try{if(-not $process.WaitForExit((Remaining $timeout))){throw "Worker timeout: $script; inspect $stdout and $stderr"};if($process.ExitCode -ne 0 -or -not(Test-Path $result)){throw "Worker failed: $script; exit $($process.ExitCode); inspect $stdout and $stderr"};return Get-Content -LiteralPath $result -Raw | ConvertFrom-Json}finally{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}
}
function Window([IntPtr]$hwnd=$appHwnd){$w=@([ReceiverNative]::All()|Where-Object{$_.Hwnd -eq $hwnd.ToInt64() -and $_.Visible});if($w.Count -ne 1 -or $w[0].Width -lt 100){throw 'Owned visible window unavailable.'};return $w[0]}
function Focus([IntPtr]$hwnd=$appHwnd){[void][ReceiverNative]::Activate($hwnd);Start-Sleep -Milliseconds 200;if([ReceiverNative]::GetForegroundWindow() -ne $hwnd){throw 'Owned window is not foreground; input withheld.'}}
function Snapshot([string]$label,[IntPtr]$hwnd=$appHwnd){
 $script:sequence++;$name=('{0:D4}-{1}' -f $script:sequence,($label -replace '[^a-zA-Z0-9-]','-'));$w=Window $hwnd
 $bitmap=[Drawing.Bitmap]::new($w.Width,$w.Height)
 try{$g=[Drawing.Graphics]::FromImage($bitmap);try{$g.CopyFromScreen($w.Left,$w.Top,0,0,$bitmap.Size)}finally{$g.Dispose()};$path=Join-Path $OutputDirectory ($name+'.png');$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
 $ocrPath=Join-Path $OutputDirectory ($name+'-ocr.json');$uiaPath=Join-Path $OutputDirectory ($name+'-uia.json')
 $ocr=$null;$uia=$null
 try{$ocr=Worker $ocrWorker @('-Image',('"'+$path+'"'),'-Result',('"'+$ocrPath+'"'),'-DeadlineUtc',('"'+[DateTime]::UtcNow.AddMilliseconds((Remaining 15000)).ToString('o')+'"')) $ocrPath 15000}catch{$ocr=@{status='unsupported';error=$_.Exception.Message;text='';words=@()};Json $ocrPath $ocr}
 try{$uia=Worker $uiaWorker @('-Hwnd',$hwnd.ToInt64(),'-Result',('"'+$uiaPath+'"')) $uiaPath 10000}catch{$uia=@{tree=@();error=$_.Exception.Message};Json $uiaPath $uia}
 $s=@{utc=[DateTime]::UtcNow.ToString('o');window=$w;screenshot=$path;ocr=$ocr;uia=$uia;foreground=[ReceiverNative]::GetForegroundWindow().ToInt64()}
 $text=$ocr.text+' '+(($uia.tree.name)-join ' ')
 if($text -match '10054' -and $text -match 'Dio(Error|Exception)' -and $text -match 'SocketException'){$report.reporter10054Observed=$true;$report['reporterErrorDetails']=@{utc=$s.utc;text=$text;screenshot=$path}}
 Json (Join-Path $OutputDirectory ($name+'.json')) $s;return $s
}
function LabelBounds($s,[string]$label){
 $uia=@($s.uia.tree|Where-Object{$_.name -ceq $label -and -not $_.offscreen -and $_.enabled -and $_.width -gt 0})
 if($uia.Count -eq 1){return @{x=$uia[0].x;y=$uia[0].y;width=$uia[0].width;height=$uia[0].height;method='UIA bounds'}}
 $wanted=$label.Split(' ');$words=@($s.ocr.words);$found=@()
 for($i=0;$i -le $words.Count-$wanted.Count;$i++){$ok=$true;for($j=0;$j -lt $wanted.Count;$j++){if($words[$i+$j].text -cne $wanted[$j] -or [Math]::Abs($words[$i+$j].y-$words[$i].y) -gt $words[$i].height){$ok=$false;break}};if($ok){$group=@($words[$i..($i+$wanted.Count-1)]);$left=($group.x|Measure-Object -Minimum).Minimum;$top=($group.y|Measure-Object -Minimum).Minimum;$right=($group|ForEach-Object{$_.x+$_.width}|Measure-Object -Maximum).Maximum;$bottom=($group|ForEach-Object{$_.y+$_.height}|Measure-Object -Maximum).Maximum;$found+=@{x=$s.window.Left+$left;y=$s.window.Top+$top;width=$right-$left;height=$bottom-$top;method='Native OCR word bounds'}}}
 if($found.Count -ne 1){throw "Label not unique in live UI: $label ($($found.Count) OCR matches)"};return $found[0]
}
function Click([string]$label){
 Focus
 # Retry readiness observations only. Once a click is sent, this function never replays it.
 for($attempt=1;$attempt -le 3;$attempt++){
  $s=Snapshot ('before-'+$label+'-'+$attempt);$b=LabelBounds $s $label
  $verified=Snapshot ('verify-'+$label+'-'+$attempt);$current=LabelBounds $verified $label
  $sameBounds=$b.x -eq $current.x -and $b.y -eq $current.y -and $b.width -eq $current.width -and $b.height -eq $current.height
  $stable=$sameBounds -and (FreshPixels $s $b) -and (FreshPixels $verified $current)
  if(-not $stable){$report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='control-readiness-retry';label=$label;attempt=$attempt;sameBounds=$sameBounds;before=$s.screenshot;verification=$verified.screenshot};Persist;Start-Sleep -Milliseconds 250;continue}
  [SenderInput]::Click([int]($current.x+$current.width/2),[int]($current.y+$current.height/2));$report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');label=$label;bounds=$current;evidence=$s.screenshot;verification=$verified.screenshot;readinessAttempt=$attempt};Start-Sleep -Milliseconds 400;return
 }
 throw "Observed control did not stabilize within three readiness observations: $label. No input was sent."
}
function BitmapDigest([Drawing.Bitmap]$bitmap){
 $lock=$bitmap.LockBits([Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height),[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
 try{$bytes=[byte[]]::new([Math]::Abs($lock.Stride)*$bitmap.Height);[Runtime.InteropServices.Marshal]::Copy($lock.Scan0,$bytes,0,$bytes.Length);for($i=3;$i -lt $bytes.Length;$i+=4){$bytes[$i]=0};$hash=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')}finally{$hash.Dispose()}}finally{$bitmap.UnlockBits($lock)}
}
function FreshPixels($s,$bounds,[IntPtr]$hwnd=$appHwnd){
 $w=Window $hwnd
 if([ReceiverNative]::GetForegroundWindow() -ne $hwnd -or $w.Hwnd -ne $s.window.Hwnd -or $w.Left -ne $s.window.Left -or $w.Top -ne $s.window.Top -or $w.Width -ne $s.window.Width -or $w.Height -ne $s.window.Height){return $false}
 # Compare only the observed semantic label plus two pixels. A rotating logo or
 # blinking caret elsewhere in this window does not invalidate this control.
 $left=[int][Math]::Floor($bounds.x-$w.Left)-2;$top=[int][Math]::Floor($bounds.y-$w.Top)-2
 $right=[int][Math]::Ceiling($bounds.x-$w.Left+$bounds.width)+2;$bottom=[int][Math]::Ceiling($bounds.y-$w.Top+$bounds.height)+2
 if($left -lt 0 -or $top -lt 0 -or $right -gt $w.Width -or $bottom -gt $w.Height -or $right -le $left -or $bottom -le $top){return $false}
 $region=[Drawing.Rectangle]::new($left,$top,$right-$left,$bottom-$top)
 $full=[Drawing.Bitmap]::new($s.screenshot);$old=$null;$fresh=$null
 try{$old=$full.Clone($region,[Drawing.Imaging.PixelFormat]::Format32bppArgb);$fresh=[Drawing.Bitmap]::new($region.Width,$region.Height);$g=[Drawing.Graphics]::FromImage($fresh);try{$g.CopyFromScreen($w.Left+$left,$w.Top+$top,0,0,$fresh.Size)}finally{$g.Dispose()};return (BitmapDigest $old) -eq (BitmapDigest $fresh)}finally{if($old){$old.Dispose()};if($fresh){$fresh.Dispose()};$full.Dispose()}
}
function Favorites {
 try{Click 'Favorites';return}catch{$report.actions+=@{name='Favorites semantic lookup unavailable';error=$_.Exception.Message}}
 Focus;$s=Snapshot 'favorites-hover-start';$row=LabelBounds $s 'Nearby devices';$w=Window
 # Search the observed toolbar row. A matching tooltip authorizes only its retained hover target.
 $y=[int]($row.y+$row.height/2);$start=[int]($row.x+$row.width+8);$end=$w.Left+$w.Width-20;$count=0
 for($x=$start;$x -le $end -and $count -lt 48;$x+=12){$count++;Focus;[void][SenderInput]::SetCursorPos($x,$y);$report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='toolbar-hover';x=$x;y=$y};Persist;Start-Sleep -Milliseconds 900;$observed=Snapshot ('hover-'+$count)
  try{$tooltip=LabelBounds $observed 'Favorites'}catch{continue}
  if([ReceiverNative]::GetForegroundWindow() -ne $appHwnd){throw 'Foreground changed during hover.'}
  if(-not (FreshPixels $observed $tooltip)){continue}
  [SenderInput]::Click($x,$y);$report.actions+=@{name='Favorites tooltip hover target';x=$x;y=$y;tooltip=$tooltip;evidence=$observed.screenshot};Start-Sleep -Milliseconds 500;return
 };throw 'No observed Favorites tooltip within bounded toolbar hover search.'
}
function Fixture([string]$key){if($key -notin @('control','failed')){throw 'fixture must be control or failed.'};return $report.fixtures[$key]}
function Handles([string]$label,$fixture){
 $raw=Join-Path $OutputDirectory ($label+'-handle.txt');$exe=Join-Path $OutputDirectory 'sysinternals/handle64.exe'
 $process=Start-Process $exe -ArgumentList @('-accepteula','-nobanner','-a',('"'+$fixture.path+'"')) -RedirectStandardOutput $raw -RedirectStandardError ($raw+'.stderr') -PassThru -WindowStyle Hidden
 try{if(-not $process.WaitForExit((Remaining 15000))){throw 'handle.exe exceeded deadline.'};return @{raw=$raw;stderr=$raw+'.stderr';exitCode=$process.ExitCode;processes=@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue|Select-Object Id,ProcessName,StartTime);utc=[DateTime]::UtcNow.ToString('o')}}finally{if(-not $process.HasExited){$process.Kill()}}
}
function Probe($command){
 $f=Fixture $command.fixture;$phase=$command.phase
 if($phase -notin @('before-selection','during-upload','after-success','after-terminal-error','after-quit')){throw 'Invalid probe phase.'}
 $app.Refresh();$alive=-not $app.HasExited
 if($phase -eq 'before-selection' -and $f.selected){throw 'Before-selection control must precede native selection.'}
 if($phase -ne 'after-quit' -and -not $alive){throw 'Alive-app probe requires same sender process.'}
 if($phase -eq 'after-quit' -and $alive){throw 'After-quit probe requires observed exit.'}
 $view=$null;if($alive){Focus;$view=Snapshot ('probe-'+$phase)}
 if($phase -eq 'during-upload'){$text=$view.ocr.text+' '+(($view.uia.tree.name)-join ' ');if($text -notmatch 'Sending' -or $text -match 'Finished'){throw 'Active Sending state not observed.'}}
 if($phase -eq 'after-terminal-error'){
  $terminalDeadline=[DateTime]::UtcNow.AddSeconds(180)
  do{$text=$view.ocr.text+' '+(($view.uia.tree.name)-join ' ');if($text -match 'Finished with error'){break};Start-Sleep -Milliseconds 1000;Focus;$view=Snapshot 'waiting-terminal-error'}while([DateTime]::UtcNow -lt $terminalDeadline)
  if($text -notmatch 'Finished with error'){throw 'Terminal sender error not observed; probe withheld.'}
  $report.terminalError=@{utc=$view.utc;text=$text;screenshot=$view.screenshot}
  if(-not $report.networkInterruption){throw 'Record controller interruption evidence before this probe.'}
 }
 if($phase -eq 'after-success'){$text=$view.ocr.text+' '+(($view.uia.tree.name)-join ' ');if($text -notmatch 'Finished' -or $text -match 'Finished with error'){throw 'Successful terminal sender state not observed.'}}
 $label=$command.id+'-'+$phase+'-'+$command.fixture;$before=Handles ($label+'-before') $f
 $hash=(Get-FileHash -LiteralPath $f.path -Algorithm SHA256).Hash.ToLowerInvariant();if($hash -ne $f.sha256){throw 'Source changed before probe.'}
 $out=@{phase=$phase;fixture=$command.fixture;processId=$app.Id;appAlive=$alive;sourceHash=$hash;handlesBefore=$before;rename=@{};delete=@{};restored=$false;senderUi=$view}
 if($phase -eq 'during-upload'){
  # A read-only exclusive open detects sharing without moving/deleting an active source.
  $out.rename=@{attempted=$false;reason='Active-transfer control preserves source pathname.'};$out.delete=$out.rename
  $exclusive=$null
  try{$exclusive=[IO.File]::Open($f.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$out.exclusiveOpen=@{success=$true}}catch{$out.exclusiveOpen=@{success=$false;error=$_.Exception.ToString();hresult=$_.Exception.HResult}}finally{if($exclusive){$exclusive.Dispose()}}
  $out.restored=$true;return $out
 }
 $renamed=$f.path+'.probe-rename';$backup=$f.path+'.probe-backup'
 if((Test-Path $renamed) -or (Test-Path $backup)){throw 'Probe backup collision.'}
 Copy-Item -LiteralPath $f.path -Destination $backup
 try{
  try{Move-Item -LiteralPath $f.path -Destination $renamed;$out.rename=@{success=$true};Move-Item -LiteralPath $renamed -Destination $f.path}catch{$out.rename=@{success=$false;error=$_.Exception.ToString();hresult=$_.Exception.HResult};if(Test-Path $renamed){Move-Item -LiteralPath $renamed -Destination $f.path}}
  try{Remove-Item -LiteralPath $f.path;$out.delete=@{success=$true};Copy-Item -LiteralPath $backup -Destination $f.path}catch{$out.delete=@{success=$false;error=$_.Exception.ToString();hresult=$_.Exception.HResult}}
 }finally{
  if(-not(Test-Path $f.path)){if(Test-Path $renamed){Move-Item -LiteralPath $renamed -Destination $f.path}else{Copy-Item -LiteralPath $backup -Destination $f.path}}
  $restored=(Get-FileHash -LiteralPath $f.path -Algorithm SHA256).Hash.ToLowerInvariant();$out.restored=$restored -eq $hash
  if($out.restored){Remove-Item -LiteralPath $backup}else{throw 'Source restoration hash mismatch; backup retained.'}
 }
 $out.handlesAfter=Handles ($label+'-after') $f;return $out
}
function NativePicker([IntPtr]$hwnd,[string]$path,[string]$id){
 $dialog=Window $hwnd;if($dialog.Pid -ne $app.Id -or $dialog.ClassName -ne '#32770'){throw 'Picker is not the owned native dialog.'}
 $children=@([SenderInput]::Children($hwnd));$evidence=@{dialog=$dialog;before=$children;typed=$null;after=$null;method='Observed native Edit HWND mouse focus, ordinary keyboard input, GetWindowText verification, observed native Open mouse click'}
 $record=Join-Path $OutputDirectory ($id+'-picker-native.json');Json $record $evidence
 $edits=@($children|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Edit' -and $_.FileNameAncestor -and $_.Width -gt 0})
 $buttons=@($children|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Button' -and $_.Id -eq 1 -and $_.Text -match '^(&)?Open$'})
 if($edits.Count -ne 1 -or $buttons.Count -ne 1){throw 'Native File name Edit (under ID 1148) and Open Button (ID 1) must be unique; inspect retained HWND evidence.'}
 Focus $hwnd;$edit=$edits[0];[SenderInput]::Click([int]($edit.Left+$edit.Width/2),[int]($edit.Top+$edit.Height/2))
 [System.Windows.Forms.SendKeys]::SendWait('^a')
 $escaped=[regex]::Replace($path,'([+^%~(){}\[\]])','{$1}')
 [System.Windows.Forms.SendKeys]::SendWait($escaped);Start-Sleep -Milliseconds 200
 $after=@([SenderInput]::Children($hwnd));$actual=@($after|Where-Object{$_.Hwnd -eq $edit.Hwnd -and $_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Edit' -and $_.FileNameAncestor})
 $evidence.typed=$actual;$evidence.after=$after;Json $record $evidence
 if($actual.Count -ne 1 -or $actual[0].Text -cne $path){throw 'Actual native File name text differs from fixture path; Open withheld.'}
 $snapshot=Snapshot 'native-picker-path-verified' $hwnd
 $open=@([SenderInput]::Children($hwnd)|Where-Object{$_.Hwnd -eq $buttons[0].Hwnd -and $_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Button' -and $_.Id -eq 1 -and $_.Text -match '^(&)?Open$'})
 if($open.Count -ne 1){throw 'Observed native Open control changed before click.'};$button=$open[0]
 if($button.Left -ne $buttons[0].Left -or $button.Top -ne $buttons[0].Top -or $button.Width -ne $buttons[0].Width -or $button.Height -ne $buttons[0].Height){throw 'Native Open geometry changed; input withheld.'}
 $bounds=@{x=$button.Left;y=$button.Top;width=$button.Width;height=$button.Height}
 if(-not(FreshPixels $snapshot $bounds $hwnd)){throw 'Native Open pixels or dialog ownership changed before input.'}
 [SenderInput]::Click([int]($button.Left+$button.Width/2),[int]($button.Top+$button.Height/2))
 $report.actions+=@{name='native-picker-open';utc=[DateTime]::UtcNow.ToString('o');nativeEvidence=$record;screenshot=$snapshot.screenshot;fileName=$path;button=$button}
 return @{acted=$true;nativeEvidence=$record;screenshot=$snapshot.screenshot}
}
function Execute($c){
 switch($c.action){
  'screenshot' { Focus; return Snapshot ('command-'+$c.id) }
  'click' { if(-not $c.label){throw 'click needs exact label.'};Click $c.label;return Snapshot ('after-'+$c.id) }
  'add-favorite' {
   Click 'Send';Favorites;Click 'Add';Focus;$s=Snapshot 'favorite-add-dialog'
   [void](LabelBounds $s 'Add to favorites');[void](LabelBounds $s 'IP Address');[void](LabelBounds $s 'Port')
   # 1.14.0 FavoriteEditDialog autofocuses IP. Tab order is IP -> Port.
   # Retain the dialog and typed input; no profile injection or protocol registration replaces the UI.
   [System.Windows.Forms.SendKeys]::SendWait('^a127.0.0.1{TAB}^a53318')
   $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='favorite IP autofocus and source-defined Tab to Port';ip='127.0.0.1';port=53318;evidence=$s.screenshot}
   Click 'Confirm';Start-Sleep -Milliseconds 1200
   return Snapshot 'favorite-confirmed'
  }
  'select' {
   $f=Fixture $c.fixture;Focus;$s=Snapshot 'before-selection'
   $names=$s.ocr.text+' '+(($s.uia.tree.name)-join ' ')
   if($names -match 'Finished'){Click 'Done'}
   # 1.14 Favorites dialog uses Cancel to return to the Send tab.
   $s=Snapshot 'selection-navigation';$names=$s.ocr.text+' '+(($s.uia.tree.name)-join ' ')
   if($names -match 'Favorites' -and $names -match 'Cancel'){Click 'Cancel'}
   # The initial tab switch is done by add-favorite. A subsequent selection is on the same Send tab.
   try{Click 'File'}catch{Click 'Add';Click 'File'}
   $end=[DateTime]::UtcNow.AddSeconds(15);$picker=@()
   do{$picker=@([ReceiverNative]::All()|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.ClassName -eq '#32770'});if($picker.Count -eq 1){break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
   if($picker.Count -ne 1){throw 'Native file picker owned by the sender was not observed.'}
   $hwnd=[IntPtr]::new($picker[0].Hwnd);Focus $hwnd;$before=Snapshot 'native-picker-before' $hwnd
   $picked=NativePicker $hwnd $f.path $c.id
   if(-not $picked.acted){throw 'Native picker did not invoke Open.'}
   Start-Sleep -Milliseconds 800;Focus;$after=Snapshot 'source-selected';$text=$after.ocr.text+' '+(($after.uia.tree.name)-join ' ')
   if($text -notmatch 'Files: 1'){throw 'Selection of exactly one file was not observed.'}
   $f.selected=$true;$report.actions+=@{name='native-file-selection';fixture=$c.fixture;path=$f.path;picker=$before.screenshot;after=$after.screenshot};return $after
  }
  'send' {
   $label=$ReceiverName;if($c.receiverName){$label=[string]$c.receiverName}
   # Selecting the favorite recipient in single-recipient mode starts the real send request.
   if($label){try{Click $label}catch{Favorites;Click $label}}else{
    Favorites
    # The manually added favorite was discovered through 127.0.0.1:53318. Its observed IP is stable even when the Android alias is generated.
    try{Click '(127.0.0.1)';$label='(127.0.0.1)'}catch{Click '127.0.0.1';$label='127.0.0.1'}
   }
   $send=@{started=$true;utc=[DateTime]::UtcNow.ToString('o');receiverName=$label;endpoint='127.0.0.1:53318';processId=$app.Id}
   Json (Join-Path $OutputDirectory 'send-started.json') $send;return $send
  }
  'record-interruption' {
   if($c.kind -notin @('normal-network-interruption','synthetic-relay-close') -or -not $c.evidence){throw 'Provide kind and retained controller interruption evidence.'}
   $report.networkInterruption=@{kind=$c.kind;evidence=$c.evidence;utc=[DateTime]::UtcNow.ToString('o');qualifiesForReporterWorkflow=$c.kind -eq 'normal-network-interruption'};return $report.networkInterruption
  }
  'probe' { return Probe $c }
  'quit' {
   Focus;$before=Snapshot 'before-quit';[System.Windows.Forms.SendKeys]::SendWait('%{F4}')
   # Close may minimize to tray. Do not silently convert that into a normal application exit.
   if(-not $app.WaitForExit((Remaining 10000))){throw 'Alt+F4 did not exit (possibly minimize-to-tray); after-quit gate remains unmet. Use settings UI to disable Minimize to tray, or explicit terminate supplementary action.'}
   $report.quit=@{method='normal Alt+F4';processId=$app.Id;exitCode=$app.ExitCode;utc=[DateTime]::UtcNow.ToString('o');evidence=$before.screenshot};return $report.quit
  }
  'terminate' {
   # Supplementary process-lifetime comparison, explicitly distinct from normal Quit.
   Stop-Process -Id $app.Id -Force;$app.WaitForExit();$report.quit=@{method='forced process termination; supplementary';processId=$app.Id;utc=[DateTime]::UtcNow.ToString('o')};return $report.quit
  }
  'stop' { $report.status='stopped';return @{stopped=$true} }
  default { throw "Unknown command action: $($c.action)" }
 }
}
try {
 if(Test-Path $readyPath){throw 'Output directory already has ready.json; use a fresh isolated directory.'}
 if(@(Get-ChildItem $commands -Filter '*.json').Count -gt 0){throw 'Fresh output directory must have no queued commands.'}
 $report.os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64'){throw 'Official artifact requires x64 Windows.'}
 if(@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue).Count -gt 0){throw 'Another LocalSend exists; require isolated job.'}
 $archive=Join-Path $OutputDirectory 'LocalSend-1.14.0-windows-x86-64.zip'
 Invoke-WebRequest $report.artifactUrl -OutFile $archive -TimeoutSec 120
 $report.archive=@{path=$archive;bytes=(Get-Item $archive).Length;sha256=(Get-FileHash $archive -Algorithm SHA256).Hash}
 if($report.archive.bytes -lt 1000000){throw 'Official ZIP unexpectedly small.'}
 $release=Join-Path $OutputDirectory 'release';Expand-Archive -LiteralPath $archive -DestinationPath $release
 $executables=@(Get-ChildItem $release -Recurse -File|Where-Object{$_.Name -in @('localsend_app.exe','LocalSend.exe')})
 if($executables.Count -ne 1){throw 'Expected one official executable.'};$exe=$executables[0]
 $report.executable=@{path=$exe.FullName;fileVersion=$exe.VersionInfo.FileVersion;sha256=(Get-FileHash $exe.FullName -Algorithm SHA256).Hash}
 $sysZip=Join-Path $OutputDirectory 'Handle.zip';Invoke-WebRequest 'https://download.sysinternals.com/files/Handle.zip' -OutFile $sysZip -TimeoutSec 120
 Expand-Archive -LiteralPath $sysZip -DestinationPath (Join-Path $OutputDirectory 'sysinternals')
 $report.handleTool=@{url='https://download.sysinternals.com/files/Handle.zip';zipSha256=(Get-FileHash $sysZip -Algorithm SHA256).Hash;exeSha256=(Get-FileHash (Join-Path $OutputDirectory 'sysinternals/handle64.exe') -Algorithm SHA256).Hash;eula='-accepteula explicitly authorized diagnostic observation'}
 # A 1MiB deterministic block repeated yields separate 1MiB control and 256MiB failed fixtures.
 $block=[byte[]]::new(1048576);for($i=0;$i -lt $block.Length;$i++){$block[$i]=[byte]($i%256)}
 foreach($entry in @(@{key='control';blocks=1},@{key='failed';blocks=256})){
  $path=Join-Path $OutputDirectory ('1461-'+$entry.key+'-'+$entry.blocks+'MiB.bin');$stream=[IO.File]::Create($path)
  try{for($n=0;$n -lt $entry.blocks;$n++){$stream.Write($block,0,$block.Length)}}finally{$stream.Dispose()}
  $report.fixtures[$entry.key]=@{path=$path;bytes=(Get-Item $path).Length;sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();selected=$false;pattern='byte at offset i = i mod 256'}
 }
 $rule='LocalSend1461-'+[Guid]::NewGuid().ToString('N');New-NetFirewallRule -Name $rule -DisplayName $rule -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any|Out-Null
 $app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru;$report.processId=$app.Id
 $until=[DateTime]::UtcNow.AddSeconds(60);$windows=@()
 do{Start-Sleep -Milliseconds 500;$app.Refresh();if($app.HasExited){throw 'Official sender exited at startup.'};$windows=@([ReceiverNative]::All()|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Width -gt 300})}until($windows.Count -gt 0 -or [DateTime]::UtcNow -ge $until)
 if($windows.Count -ne 1){throw 'Single sender window unavailable.'};$appHwnd=[IntPtr]::new($windows[0].Hwnd);Focus;$initial=Snapshot 'ready'
 $report.status='ready';Persist
 Json $readyPath @{ready=$true;utc=[DateTime]::UtcNow.ToString('o');processId=$app.Id;fixtures=$report.fixtures;commands=$commands;results=$results;status=$statusPath;initial=$initial.screenshot;interface='commands/<id>.json -> results/<id>.json; successful command status passed; one pending command at a time'}
 $seen=@{}
 while([DateTime]::UtcNow -lt $deadline -and $report.status -ne 'stopped'){
  foreach($file in @(Get-ChildItem $commands -Filter '*.json'|Sort-Object Name)){
   if($seen.ContainsKey($file.Name)){continue};$seen[$file.Name]=$true;$c=$null
   try{$c=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json;if($c.id -notmatch '^[a-zA-Z0-9_-]{1,64}$' -or $file.BaseName -cne $c.id){throw 'Command id must match safe filename.'}
    Json (Join-Path $results ($c.id+'.json')) @{id=$c.id;status='running';startedUtc=[DateTime]::UtcNow.ToString('o')}
    $result=Execute $c;Json (Join-Path $results ($c.id+'.json')) @{id=$c.id;action=$c.action;status='passed';utc=[DateTime]::UtcNow.ToString('o');result=$result}
   }catch{$err=$_.Exception.ToString();$report.errors+=@{command=$file.Name;error=$err};$id=$file.BaseName;Json (Join-Path $results ($id+'.json')) @{id=$id;status='failed';utc=[DateTime]::UtcNow.ToString('o');error=$err}}
   Persist
  };Start-Sleep -Milliseconds 250
 }
 if($report.status -ne 'stopped'){throw 'Controller deadline expired.'}
}catch{$report.status='failed';$report.errors+=$_.Exception.ToString();if($app -and -not $app.HasExited){try{Focus;[void](Snapshot 'failure')}catch{}}}
finally{
 if($app -and -not $app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue;$report.cleanup='Forced process cleanup is not normal Quit evidence.'}
 if($rule){Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue}
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o');Persist
 # Keep ready.json as durable identity evidence; status.json is authoritative after stop.
}
if($report.status -eq 'failed'){exit 1}
