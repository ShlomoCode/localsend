# Run only in an isolated cloud Windows desktop. App binaries stay unchanged;
# explicitly requested ports use the release's supported portable preferences.
# Atomically submit commands/<id>.json; wait for results/<id>.json before sending another.
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[int]$TimeoutSeconds=5400,[string]$ReceiverName='',[string]$FfmpegPath='')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$commands=Join-Path $OutputDirectory 'commands'; $results=Join-Path $OutputDirectory 'results'
[void][IO.Directory]::CreateDirectory($commands); [void][IO.Directory]::CreateDirectory($results)
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$report=[ordered]@{status='starting';startedUtc=[DateTime]::UtcNow.ToString('o');release='1.14.0';artifactUrl='https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0-windows-x86-64.zip';environmentScope='Actual OS is recorded below. Windows Server is supplementary to reported Windows 11. Loopback relay differs from LAN.';runner=$env:RUNNER_NAME;image=$env:ImageOS;os=$null;archive=$null;executable=$null;processId=$null;fixtures=@{};actions=@();errors=@();terminalError=$null;reporter10054Observed=$false;networkInterruption=$null;quit=$null}
$statusPath=Join-Path $OutputDirectory 'status.json'; $readyPath=Join-Path $OutputDirectory 'ready.json'
$app=$null; $appHwnd=[IntPtr]::Zero; $rule=$null; $sequence=0;$appStartedTicks=$null;$recorder=$null
$receiverHost='127.0.0.1';$receiverPort=53318;$receptionPort=53317;$failedFixtureBytes=[long]268435456
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
public class SenderTextObservation {
 public long Hwnd,MessageResult; public int Pid,TimeoutMs,Win32Error;
 public bool Success,TimedOut,Truncated; public string Text,Error;
 public SenderControl Control;
}
public class SenderShortcutObservation {
 public int Pid,VirtualKey,InputSize,Win32Error,CleanupWin32Error;
 public uint Inserted,CleanupInserted;
 public bool ForegroundOwned,KeysInitiallyUp,Accepted;
 public string Error;
}
public static class SenderInput {
 [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT { public ushort Vk,Scan; public uint Flags,Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
 [StructLayout(LayoutKind.Sequential)] private struct HARDWAREINPUT { public uint Message; public ushort Low,High; }
 [StructLayout(LayoutKind.Explicit)] private struct INPUTUNION {
  [FieldOffset(0)] public KEYBDINPUT Keyboard;
  [FieldOffset(0)] public MOUSEINPUT Mouse;
  [FieldOffset(0)] public HARDWAREINPUT Hardware;
 }
 [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint Type; public INPUTUNION Data; }
 [DllImport("user32.dll",SetLastError=true)] private static extern uint SendInput(uint count,[In] INPUT[] inputs,int size);
 [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
 private static INPUT Key(ushort key,bool up) { return new INPUT { Type=1,Data=new INPUTUNION { Keyboard=new KEYBDINPUT { Vk=key,Flags=up?2u:0u } } }; }
 public static SenderShortcutObservation ControlShortcut(IntPtr hwnd,int expectedPid,ushort key) {
  var result=new SenderShortcutObservation { Pid=expectedPid,VirtualKey=key,InputSize=Marshal.SizeOf(typeof(INPUT)) };
  if(key!=0x41&&key!=0x43){result.Error="Only explicit VK_A and VK_C shortcuts are supported.";return result;}
  if(result.InputSize!=(IntPtr.Size==8?40:28)){result.Error="Unexpected native INPUT ABI size; no input sent.";return result;}
  uint owner;GetWindowThreadProcessId(hwnd,out owner);
  result.ForegroundOwned=GetForegroundWindow()==hwnd&&owner==(uint)expectedPid&&IsWindowVisible(hwnd);
  if(!result.ForegroundOwned){result.Error="Original app does not own the foreground window; no input sent.";return result;}
  result.KeysInitiallyUp=true;
  foreach(int check in new int[] {0x10,0x11,0x12,0x5B,0x5C,key})if((GetAsyncKeyState(check)&0x8000)!=0)result.KeysInitiallyUp=false;
  if(!result.KeysInitiallyUp){result.Error="Shortcut or modifier key already down; no input sent.";return result;}
  SetLastError(0);
  result.Inserted=SendInput(4,new INPUT[] {Key(0x11,false),Key(key,false),Key(key,true),Key(0x11,true)},result.InputSize);
  result.Win32Error=Marshal.GetLastWin32Error();
  if(result.Inserted!=4){
   // Never retry the shortcut. Release only the keys that this attempt could
   // have pressed; retain any uncertain cleanup as infrastructure failure.
   if(result.Inserted>0){SetLastError(0);result.CleanupInserted=SendInput(2,new INPUT[] {Key(key,true),Key(0x11,true)},result.InputSize);result.CleanupWin32Error=Marshal.GetLastWin32Error();}
   result.Error="SendInput did not insert all four shortcut events; action and modifier cleanup are not credited.";return result;
  }
  result.Accepted=true;return result;
 }
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
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,UIntPtr wParam,StringBuilder lParam,uint flags,uint timeout,out UIntPtr result);
 [DllImport("kernel32.dll")] private static extern void SetLastError(uint error);
 public static SenderTextObservation ReadEdit(IntPtr root,SenderControl expected,int timeoutMs) {
  var observation=new SenderTextObservation {Hwnd=expected.Hwnd,Pid=expected.Pid,TimeoutMs=timeoutMs,Text=""};
  SenderControl actual=null;
  foreach(var control in Children(root))if(control.Hwnd==expected.Hwnd)actual=control;
  observation.Control=actual;
  if(actual==null||actual.Pid!=expected.Pid||actual.Id!=expected.Id||actual.Parent!=expected.Parent||actual.ClassName!="Edit"||!actual.FileNameAncestor||!actual.Visible||!actual.Enabled||actual.Left!=expected.Left||actual.Top!=expected.Top||actual.Width!=expected.Width||actual.Height!=expected.Height){observation.Error="Native Edit ownership, ancestry or geometry changed; WM_GETTEXT withheld.";return observation;}
  if(timeoutMs<1||timeoutMs>2000){observation.Error="WM_GETTEXT requires a 1..2000ms bound.";return observation;}
  var text=new StringBuilder(32768);UIntPtr result;
  SetLastError(0);
  // WM_GETTEXT is marshalled by Windows between processes. Abort on hang or exit;
  // block reentrancy while the bounded read is in progress (SMTO flags 0x23).
  IntPtr outcome=SendMessageTimeout(new IntPtr(actual.Hwnd),0x000D,new UIntPtr((uint)text.Capacity),text,0x23,(uint)timeoutMs,out result);
  int error=Marshal.GetLastWin32Error();
  observation.Success=outcome!=IntPtr.Zero;observation.Win32Error=error;observation.MessageResult=(long)result.ToUInt64();
  observation.TimedOut=!observation.Success&&error==1460;
  observation.Truncated=observation.Success&&result.ToUInt64()>=(ulong)(text.Capacity-1);
  observation.Text=text.ToString();
  if(!observation.Success)observation.Error=error==0?"WM_GETTEXT timed out or failed without a Win32 error.":new System.ComponentModel.Win32Exception(error).Message;
  return observation;
 }
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
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class SenderObservedWindow {
 public long Hwnd; public uint Pid,ThreadId; public string ClassName;
}
public class SenderGuiObservation {
 public uint AppThreadId,AppPid,ControllerThreadId,FocusThreadId,Flags;
 public int Size,Win32Error,CaretLeft,CaretTop,CaretRight,CaretBottom;
 public bool Success; public string Error,CaretCoordinates="client coordinates of caret HWND; no OS caret does not exclude a Flutter-rendered caret";
 public long AppLayout,ControllerLayout,FocusLayout;
 public uint ControlScan,AScan,CScan;
 public SenderObservedWindow Foreground,Active,Focus,Capture,MenuOwner,MoveSize,Caret;
}
public static class SenderObservationNative {
 [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] private struct GUITHREADINFO {
  public uint Size,Flags; public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret; public RECT CaretRect;
 }
 [DllImport("user32.dll",SetLastError=true)] private static extern bool GetGUIThreadInfo(uint threadId,ref GUITHREADINFO info);
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd,StringBuilder text,int size);
 [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint threadId);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern uint MapVirtualKeyEx(uint code,uint mapType,IntPtr layout);
 [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
 [DllImport("kernel32.dll")] private static extern void SetLastError(uint error);
 private static SenderObservedWindow Describe(IntPtr hwnd) {
  var result=new SenderObservedWindow {Hwnd=hwnd.ToInt64()};
  if(hwnd!=IntPtr.Zero){uint pid;result.ThreadId=GetWindowThreadProcessId(hwnd,out pid);result.Pid=pid;var name=new StringBuilder(256);GetClassName(hwnd,name,name.Capacity);result.ClassName=name.ToString();}
  return result;
 }
 public static SenderGuiObservation Read(IntPtr app) {
  uint pid;uint thread=GetWindowThreadProcessId(app,out pid);
  var result=new SenderGuiObservation {AppThreadId=thread,AppPid=pid,ControllerThreadId=GetCurrentThreadId(),Size=Marshal.SizeOf(typeof(GUITHREADINFO)),Foreground=Describe(GetForegroundWindow())};
  result.ControllerLayout=GetKeyboardLayout(result.ControllerThreadId).ToInt64();
  if(thread==0){result.Error="App window thread unavailable; GUI-thread/layout queries withheld. Win32Error is not observed for this local rejection.";return result;}
  result.AppLayout=GetKeyboardLayout(thread).ToInt64();
  // MAPVK_VK_TO_VSC_EX is a read-only layout query, not dispatched-message evidence.
  var layout=new IntPtr(result.AppLayout);result.ControlScan=MapVirtualKeyEx(0x11,4,layout);result.AScan=MapVirtualKeyEx(0x41,4,layout);result.CScan=MapVirtualKeyEx(0x43,4,layout);
  var info=new GUITHREADINFO {Size=(uint)result.Size};SetLastError(0);result.Success=GetGUIThreadInfo(thread,ref info);result.Win32Error=Marshal.GetLastWin32Error();
  if(result.Success){result.Flags=info.Flags;result.Active=Describe(info.Active);result.Focus=Describe(info.Focus);result.Capture=Describe(info.Capture);result.MenuOwner=Describe(info.MenuOwner);result.MoveSize=Describe(info.MoveSize);result.Caret=Describe(info.Caret);result.CaretLeft=info.CaretRect.Left;result.CaretTop=info.CaretRect.Top;result.CaretRight=info.CaretRect.Right;result.CaretBottom=info.CaretRect.Bottom;result.FocusThreadId=result.Focus.ThreadId;if(result.FocusThreadId!=0)result.FocusLayout=GetKeyboardLayout(result.FocusThreadId).ToInt64();}
  return result;
 }
}
'@
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
function Window([IntPtr]$hwnd=$appHwnd){
 $app.Refresh();if($app.HasExited -or ($appStartedTicks -and $app.StartTime.ToUniversalTime().Ticks -ne $appStartedTicks)){throw 'Original sender process identity unavailable.'}
 $w=@([ReceiverNative]::All()|Where-Object{$_.Hwnd -eq $hwnd.ToInt64() -and $_.Pid -eq $app.Id -and $_.Visible});if($w.Count -ne 1 -or $w[0].Width -lt 100){throw 'Owned visible window unavailable.'};return $w[0]
}
function Focus([IntPtr]$hwnd=$appHwnd){[void][ReceiverNative]::Activate($hwnd);Start-Sleep -Milliseconds 200;if([ReceiverNative]::GetForegroundWindow() -ne $hwnd){throw 'Owned window is not foreground; input withheld.'}}
function InputObservation([string]$label,[bool]$rawFrame=$false){
 # Read-only receipts: no activation, worker, OCR, UIA, extra input or polling.
 try{
 $script:sequence++;$name=('{0:D4}-{1}' -f $script:sequence,($label -replace '[^a-zA-Z0-9-]','-'))
 $receipt=[ordered]@{startedUtc=[DateTime]::UtcNow.ToString('o');processId=$app.Id;expectedProcessStartedTicks=$appStartedTicks;rawFrameRequested=$rawFrame;before=$null;after=$null;beforeNative=$null;afterNative=$null;captureOwnershipQualified=$false;errors=@();inputConfiguration=@{mode='VK';control=0x11;targets=@(0x41,0x43);scan=0;downFlags=0;upFlags=2;events='Control down, target down, target up, Control up';scope='Configured INPUT only; not OS-dispatched scan metadata'}}
 try{$receipt['before']=Window;$receipt['beforeProcessStartedTicks']=$app.StartTime.ToUniversalTime().Ticks;$receipt['beforeNative']=[SenderObservationNative]::Read($appHwnd)}catch{$receipt.errors+=$_.Exception.Message}
 if($rawFrame -and $receipt.before){
  $bitmap=$null;$g=$null
  try{$w=$receipt.before;$bitmap=[Drawing.Bitmap]::new($w.Width,$w.Height);$g=[Drawing.Graphics]::FromImage($bitmap);$g.CopyFromScreen($w.Left,$w.Top,0,0,$bitmap.Size);$path=Join-Path $OutputDirectory ($name+'.png');$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$receipt['screenshot']=$path;$receipt['capturedUtc']=[DateTime]::UtcNow.ToString('o')}catch{$receipt.errors+=$_.Exception.Message}finally{if($g){$g.Dispose()};if($bitmap){$bitmap.Dispose()}}
 }
 try{$receipt['after']=Window;$receipt['afterNative']=[SenderObservationNative]::Read($appHwnd);$receipt['processStartedTicks']=$app.StartTime.ToUniversalTime().Ticks}catch{$receipt.errors+=$_.Exception.Message}
 if($receipt.Contains('screenshot') -and $receipt.before -and $receipt.after -and $receipt.beforeNative -and $receipt.afterNative){
  $b=$receipt.before;$a=$receipt.after
  $receipt.captureOwnershipQualified=$b.Hwnd -eq $a.Hwnd -and $b.Left -eq $a.Left -and $b.Top -eq $a.Top -and $b.Width -eq $a.Width -and $b.Height -eq $a.Height -and $receipt.beforeNative.AppPid -eq $app.Id -and $receipt.afterNative.AppPid -eq $app.Id -and $receipt.beforeNative.Foreground.Hwnd -eq $appHwnd.ToInt64() -and $receipt.afterNative.Foreground.Hwnd -eq $appHwnd.ToInt64() -and $receipt.beforeProcessStartedTicks -eq $appStartedTicks -and $receipt.processStartedTicks -eq $appStartedTicks
 }
 try{
  if(-not $script:inputObservationRuntime){
  $assembly=[Windows.Forms.SendKeys].Assembly;$location=$assembly.Location
  $script:inputObservationRuntime=@{observedUtc=[DateTime]::UtcNow.ToString('o');powershell=$PSVersionTable.PSVersion.ToString();framework=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription;clr=[Environment]::Version.ToString();apartment=[Threading.Thread]::CurrentThread.GetApartmentState().ToString();winFormsAssembly=$assembly.FullName;winFormsLocation=$location;winFormsSha256=if($location -and [IO.File]::Exists($location)){(Get-FileHash -LiteralPath $location -Algorithm SHA256).Hash}else{$null}}
  }
  $receipt['runtime']=$script:inputObservationRuntime
 }catch{$receipt.errors+=$_.Exception.Message}
 $receipt['endedUtc']=[DateTime]::UtcNow.ToString('o');$report.actions+=@{name='read-only input observation';label=$label;receipt=$receipt}
 try{Json (Join-Path $OutputDirectory ($name+'.json')) $receipt;Persist}catch{$receipt.errors+=$_.Exception.Message}
 }catch{$report.actions+=@{name='read-only input observation error';label=$label;error=$_.Exception.Message}}
}
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
 if($label -eq 'Done'){$uia=@($uia|Where-Object{$_.type -eq 'ControlType.Button'})}
 if($uia.Count -eq 1){return @{x=$uia[0].x;y=$uia[0].y;width=$uia[0].width;height=$uia[0].height;method='UIA bounds'}}
 $wanted=$label.Split(' ');$words=@($s.ocr.words);$found=@()
 for($i=0;$i -le $words.Count-$wanted.Count;$i++){$ok=$true;for($j=0;$j -lt $wanted.Count;$j++){if($words[$i+$j].text -cne $wanted[$j] -or [Math]::Abs($words[$i+$j].y-$words[$i].y) -gt $words[$i].height){$ok=$false;break}};if($ok){$group=@($words[$i..($i+$wanted.Count-1)]);$left=($group.x|Measure-Object -Minimum).Minimum;$top=($group.y|Measure-Object -Minimum).Minimum;$right=($group|ForEach-Object{$_.x+$_.width}|Measure-Object -Maximum).Maximum;$bottom=($group|ForEach-Object{$_.y+$_.height}|Measure-Object -Maximum).Maximum;$found+=@{x=$s.window.Left+$left;y=$s.window.Top+$top;width=$right-$left;height=$bottom-$top;method='Native OCR word bounds'}}}
 if($found.Count -eq 0 -and $label -notmatch '\s'){
  # Native OCR can split one word (E16: Po + rt). Reconstruct only exact
  # characters in consecutive left-to-right tokens on the same tight baseline.
  for($i=0;$i -lt $words.Count;$i++){
   $text='';$parts=@();$previous=$null
   for($j=$i;$j -lt $words.Count -and $j-$i -lt $label.Length;$j++){
    $word=$words[$j];if(-not $word.text -or $word.width -le 0 -or $word.height -le 0){break}
    if($previous){
     $smallHeight=[Math]::Min($previous.height,$word.height);$gap=$word.x-($previous.x+$previous.width)
     if($gap -lt 0 -or $gap -gt [Math]::Max(2,$smallHeight*0.35) -or [Math]::Abs(($word.y+$word.height)-($previous.y+$previous.height)) -gt [Math]::Max(2,$smallHeight*0.2) -or [Math]::Abs($word.height-$previous.height) -gt [Math]::Max(2,$smallHeight*0.2)){break}
    }
    $text+=$word.text;$parts+=@($word)
    if(-not $label.StartsWith($text,[StringComparison]::Ordinal)){break}
    if($parts.Count -gt 1 -and $text -ceq $label){
     $left=$parts[0].x;$top=($parts.y|Measure-Object -Minimum).Minimum;$right=$word.x+$word.width;$bottom=($parts|ForEach-Object {$_.y+$_.height}|Measure-Object -Maximum).Maximum
     $found+=@{x=$s.window.Left+$left;y=$s.window.Top+$top;width=$right-$left;height=$bottom-$top;method='Exact native OCR adjacent fragments';fragments=$parts};break
    }
    $previous=$word
   }
  }
  if($found.Count -gt 0){Json (Join-Path $OutputDirectory ('label-fragments-'+$sequence+'-'+($label -replace '[^a-zA-Z0-9-]','-')+'.json')) @{label=$label;screenshot=$s.screenshot;window=$s.window;candidates=$found;contract='Exact concatenation only; consecutive tokens, nonnegative tight gap, matching baseline and height; no spelling substitution'} }
 }
 if($label -eq 'Done'){
  # v1.14.0 ProgressPage puts its actionable Done beside Advanced in the
  # bottom card; a separate file-row status also says Done. Observe both labels
  # on that card row and reject the status-row occurrence.
  $advanced=@($s.ocr.words|Where-Object{$_.text -ceq 'Advanced' -and $_.y -gt $s.window.Height*0.6})
  if($advanced.Count -eq 1){$anchor=$advanced[0];$found=@($found|Where-Object{$_.x -gt $s.window.Left+$anchor.x+$anchor.width -and [Math]::Abs($_.y-($s.window.Top+$anchor.y)) -le [Math]::Max($_.height,$anchor.height)})}
 }
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
function ControlShortcut([string]$key){
 if($key -notin @('A','C')){throw 'Only Select All and Copy shortcuts are supported.'}
 $before=Window;if([ReceiverNative]::GetForegroundWindow() -ne $appHwnd){throw 'Original sender is not foreground; shortcut withheld.'}
 $virtualKey=if($key -eq 'A'){0x41}else{0x43}
 $native=[SenderInput]::ControlShortcut($appHwnd,$app.Id,[ushort]$virtualKey)
 $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='ordinary native Control shortcut';key=$key;window=$before;native=$native};Persist
 if(-not $native.Accepted){throw "Native Control shortcut infrastructure failure: $($native.Error)"}
}
function FavoriteFieldReadback([string]$expected,[string]$field){
 if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'Favorite clipboard readback requires an explicitly STA sender controller; infrastructure admission failed.'}
 Focus;InputObservation ('favorite-'+$field+'-after-existing-focus');$before=Window;$marker='localsend1461-readback-'+[Guid]::NewGuid().ToString('N')
 [Windows.Forms.Clipboard]::SetText($marker)
 if([Windows.Forms.Clipboard]::GetText() -cne $marker){throw 'Fresh clipboard marker was not established; favorite readback withheld.'}
 ControlShortcut 'A'
 if((Window).Hwnd -ne $before.Hwnd -or [ReceiverNative]::GetForegroundWindow() -ne $appHwnd){throw 'Original favorite window lost foreground between Select All and Copy; copy withheld.'}
 ControlShortcut 'C'
 $copyDeadline=[DateTime]::UtcNow.AddMilliseconds((Remaining 2000));$actual=$marker
 do{$actual=[Windows.Forms.Clipboard]::GetText();if($actual -cne $marker){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $copyDeadline)
 $copyObservedUtc=[DateTime]::UtcNow;$withinDeadline=$copyObservedUtc -lt $copyDeadline
 $after=Window
 $observation=@{utc=$copyObservedUtc.ToString('o');field=$field;expected=$expected;actual=$actual;marker=$marker;markerReplaced=$actual -cne $marker;withinCopyDeadline=$withinDeadline;processId=$app.Id;before=$before;after=$after;foreground=[ReceiverNative]::GetForegroundWindow().ToInt64();method='Explicit native VK_CONTROL+VK_A Select All then VK_CONTROL+VK_C Copy on the source-defined focused field; fresh clipboard marker prevents stale acceptance'}
 $report.actions+=@{name='favorite focused-field readback';observation=$observation};Persist
 if(-not $withinDeadline -or $actual -ceq $marker -or $actual -cne $expected -or $before.Hwnd -ne $after.Hwnd -or [ReceiverNative]::GetForegroundWindow() -ne $appHwnd){try{InputObservation ('favorite-'+$field+'-failed-readback') $true}catch{$report.actions+=@{name='failed-readback observation error';error=$_.Exception.Message}};throw "Actual focused favorite field readback failed: $field"}
 return $observation
}
function Fixture([string]$key){if($key -notin @('control','failed')){throw 'fixture must be control or failed.'};return $report.fixtures[$key]}
function Handles([string]$label,$fixture){
 $raw=Join-Path $OutputDirectory ($label+'-handle.txt');$exe=Join-Path $OutputDirectory 'sysinternals/handle64.exe'
 $process=Start-Process $exe -ArgumentList @('-accepteula','-nobanner','-a',('"'+$fixture.path+'"')) -RedirectStandardOutput $raw -RedirectStandardError ($raw+'.stderr') -PassThru -WindowStyle Hidden
 try{
  if(-not $process.WaitForExit((Remaining 15000))){throw 'handle.exe exceeded deadline.'}
  $ownedMatches=@();$observedPid=$null
  foreach($line in [IO.File]::ReadLines($raw)){
   $pidMatch=[regex]::Match($line,'(?i)\bpid:\s*([0-9]+)(?:\s|$)');if($pidMatch.Success){$observedPid=[int]$pidMatch.Groups[1].Value}
   $fileMatch=[regex]::Match($line,'(?i)\b(?:type:\s*)?File\s+(?:\([^)]*\)\s+)?(?:[0-9a-f]+:\s+)?(?<name>.+?)\s*$')
   if($observedPid -eq $app.Id -and $fileMatch.Success -and [string]::Equals($fileMatch.Groups['name'].Value,$fixture.path,[StringComparison]::OrdinalIgnoreCase)){
    $ownedMatches+=@{processId=$observedPid;type='File';path=$fileMatch.Groups['name'].Value;rawLine=$line}
   }
  }
  $app.Refresh();$sameProcess=-not $app.HasExited -and $app.StartTime.ToUniversalTime().Ticks -eq $appStartedTicks
  return @{raw=$raw;stderr=$raw+'.stderr';exitCode=$process.ExitCode;processes=@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue|Select-Object Id,ProcessName,StartTime);utc=[DateTime]::UtcNow.ToString('o');ownedHandleConfirmed=$process.ExitCode -eq 0 -and $sameProcess -and $ownedMatches.Count -gt 0;ownedHandleMatches=$ownedMatches;ownerProcessIdentityCurrent=$sameProcess;matching='Human handle output must identify original sender PID and File type with exact full fixture path (Windows case-insensitive); unknown formats do not qualify.'}
 }finally{if(-not $process.HasExited){$process.Kill()}}
}
function NetworkProof([string]$id){
 $app.Refresh();if($app.HasExited -or $app.StartTime.ToUniversalTime().Ticks -ne $appStartedTicks){throw 'Network proof requires the original live sender process.'}
 $proof=@{observedUtc=[DateTime]::UtcNow.ToString('o');processId=$app.Id;processStartedUtc=$report.processStartedUtc;receiverHost=$receiverHost;receiverPort=$receiverPort;connections=@();paths=@();qualifiesDirectPeer=$false;scope='Actual app-owned established TCP and OS route observations only; no network mutations.'}
 $path=Join-Path $OutputDirectory ($id+'-network-proof.json')
 $owned=@(Get-NetTCPConnection -ErrorAction Stop | Where-Object {$_.OwningProcess -eq $app.Id -and $_.RemoteAddress -eq $receiverHost -and $_.RemotePort -eq $receiverPort -and $_.State -eq 'Established'})
 $proof.connections=@($owned | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess,CreationTime)
 Json $path $proof
 if([Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($receiverHost)) -or $owned.Count -eq 0){throw 'Direct-peer proof needs a nonloopback receiver and an actual established app-owned TCP connection.'}
 if(@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.IPAddress -eq $receiverHost}).Count -gt 0){throw 'Direct-peer receiver address belongs to the Windows sender itself.'}
 foreach($connection in $owned){
  $local=[Net.IPAddress]::Parse($connection.LocalAddress)
  if([Net.IPAddress]::IsLoopback($local) -or $local.Equals([Net.IPAddress]::Any)){throw 'Actual sender TCP local address is loopback or unspecified.'}
  $addresses=@(Get-NetIPAddress -IPAddress $connection.LocalAddress -ErrorAction Stop)
  $indexes=@($addresses.InterfaceIndex | Select-Object -Unique)
  if($indexes.Count -ne 1){throw 'Actual sender TCP address does not identify one interface.'}
  $index=[int]$indexes[0]
  $best=@(Find-NetRoute -RemoteIPAddress $receiverHost -LocalIPAddress $connection.LocalAddress -ErrorAction Stop)
  if(@($best | Where-Object {$_.DestinationPrefix -and $_.InterfaceIndex -eq $index}).Count -eq 0){throw 'Receiver route did not match the actual app socket interface.'}
  $proof.paths+=@{localAddress=$connection.LocalAddress;interfaceIndex=$index;observedUtc=[DateTime]::UtcNow.ToString('o');
   addresses=@($addresses | Select-Object IPAddress,PrefixLength,InterfaceIndex,InterfaceAlias,AddressState);
   selectedRoute=@($best | Select-Object IPAddress,DestinationPrefix,NextHop,InterfaceIndex,InterfaceAlias,RouteMetric);
   interface=@(Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop | Select-Object InterfaceIndex,InterfaceAlias,ConnectionState,NlMtu,InterfaceMetric);
   adapter=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {$_.ifIndex -eq $index} | Select-Object Name,InterfaceDescription,ifIndex,Status,LinkSpeed,MacAddress)}
  Json $path $proof
 }
 $app.Refresh();if($app.HasExited -or $app.StartTime.ToUniversalTime().Ticks -ne $appStartedTicks){throw 'Sender process changed during network observation.'}
 $current=@(Get-NetTCPConnection -ErrorAction Stop | Where-Object {$_.OwningProcess -eq $app.Id -and $_.RemoteAddress -eq $receiverHost -and $_.RemotePort -eq $receiverPort -and $_.State -eq 'Established'})
 $retained=@($current | Where-Object {$connection=$_;@($owned | Where-Object {$_.LocalAddress -eq $connection.LocalAddress -and $_.LocalPort -eq $connection.LocalPort}).Count -gt 0})
 $proof['connectionsAtFinish']=@($retained | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess,CreationTime);Json $path $proof
 if($retained.Count -eq 0){throw 'No observed app-owned peer TCP tuple remained established through network proof.'}
 $proof.qualifiesDirectPeer=$true;$proof['finishedUtc']=[DateTime]::UtcNow.ToString('o');Json $path $proof
 return $proof
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
 $label=$command.id+'-'+$phase+'-'+$command.fixture
 $out=@{phase=$phase;fixture=$command.fixture;processId=$app.Id;appAlive=$alive;sourceHash=$null;expectedSourceHash=$f.sha256;handlesBefore=$null;rename=@{};delete=@{};restored=$false;senderUi=$view}
 if($phase -eq 'during-upload'){
  # A read-only exclusive open detects sharing without moving/deleting an active source.
  $out.rename=@{attempted=$false;reason='Active-transfer control preserves source pathname.'};$out.delete=$out.rename
  $exclusive=$null
  $out['exclusiveOpenStartedUtc']=[DateTime]::UtcNow.ToString('o')
  try{$exclusive=[IO.File]::Open($f.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$out.exclusiveOpen=@{success=$true}}catch{$out.exclusiveOpen=@{success=$false;error=$_.Exception.ToString();hresult=$_.Exception.HResult}}finally{if($exclusive){$exclusive.Dispose()}}
  $out['exclusiveOpenFinishedUtc']=[DateTime]::UtcNow.ToString('o');$out['liveHashPerformed']=$false;$out['hashObservation']='Initial fixture hash is pinned expected evidence; no full-file hash during active upload.'
  Json (Join-Path $OutputDirectory ($label+'-exclusive-open.json')) $out
  $out.handlesBefore=Handles ($label+'-before') $f
  $out['ownedHandleConfirmed']=$out.handlesBefore.ownedHandleConfirmed
  $out.restored=$true;return $out
 }
 $out.handlesBefore=Handles ($label+'-before') $f
 $hash=(Get-FileHash -LiteralPath $f.path -Algorithm SHA256).Hash.ToLowerInvariant();if($hash -ne $f.sha256){throw 'Source changed before probe.'}
 $out.sourceHash=$hash;$out['liveHashPerformed']=$true
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
 $children=@([SenderInput]::Children($hwnd));$evidence=@{dialog=$dialog;before=$children;typed=$null;after=$null;method='Observed native Edit HWND mouse focus, ordinary keyboard input, bounded cross-process WM_GETTEXT verification, observed native Open mouse click'}
 $record=Join-Path $OutputDirectory ($id+'-picker-native.json');Json $record $evidence
 $edits=@($children|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Edit' -and $_.FileNameAncestor -and $_.Width -gt 0})
 $buttons=@($children|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Button' -and $_.Id -eq 1 -and $_.Text -match '^(&)?Open$'})
 if($edits.Count -ne 1 -or $buttons.Count -ne 1){throw 'Native File name Edit (under ID 1148) and Open Button (ID 1) must be unique; inspect retained HWND evidence.'}
 Focus $hwnd;$edit=$edits[0];[SenderInput]::Click([int]($edit.Left+$edit.Width/2),[int]($edit.Top+$edit.Height/2))
 $selectionShortcut=[SenderInput]::ControlShortcut($hwnd,$app.Id,[ushort]0x41);$evidence['selectAllShortcut']=$selectionShortcut;Json $record $evidence
 if(-not $selectionShortcut.Accepted){throw "Native picker Select All infrastructure failure: $($selectionShortcut.Error)"}
 $escaped=[regex]::Replace($path,'([+^%~(){}\[\]])','{$1}')
 [System.Windows.Forms.SendKeys]::SendWait($escaped);Start-Sleep -Milliseconds 200
 $after=@([SenderInput]::Children($hwnd));$actual=@($after|Where-Object{$_.Hwnd -eq $edit.Hwnd -and $_.Pid -eq $app.Id -and $_.Visible -and $_.Enabled -and $_.ClassName -eq 'Edit' -and $_.FileNameAncestor})
 $evidence.typed=$actual;$evidence.after=$after;Json $record $evidence
 if($actual.Count -ne 1){throw 'Actual native File name Edit ownership differs; Open withheld.'}
 # Cross-process GetWindowText cannot read an Edit value. Use Windows-marshalled
 # WM_GETTEXT solely to observe the field; typing remains ordinary keyboard input.
 $textObservation=[SenderInput]::ReadEdit($hwnd,$edit,(Remaining 2000))
 $evidence['textObservation']=$textObservation;Json $record $evidence
 if(-not $textObservation.Success -or $textObservation.Truncated){throw 'Bounded native WM_GETTEXT did not return a complete field value; inspect retained timeout/error details. Open withheld.'}
 if($textObservation.Text -cne $path){throw 'Actual native File name value differs from fixture path; Open withheld.'}
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
function StartRecording {
 if($recorder -and -not $recorder.HasExited){throw 'Continuous recorder is already active.'}
 $exe=$FfmpegPath;if(-not $exe){$exe=$env:FFMPEG_PATH};if(-not $exe){$command=Get-Command ffmpeg -ErrorAction SilentlyContinue;if($command){$exe=$command.Source}}
 if(-not $exe -or -not(Test-Path -LiteralPath $exe)){$report['recording']=@{status='unsupported';reason='No existing cloud ffmpeg executable; no tools downloaded.'};Persist;throw 'Continuous video requires an existing trusted cloud ffmpeg executable.'}
 $path=Join-Path $OutputDirectory 'windows-continuous.mkv'
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.Arguments='-hide_banner -y -f gdigrab -framerate 10 -i desktop -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p -t '+[Math]::Ceiling((Remaining ([int]::MaxValue))/1000)+' "'+$path+'"';$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.CreateNoWindow=$true
 $script:recorder=[Diagnostics.Process]::Start($start)
 $report['recording']=@{status='recording';path=$path;processId=$recorder.Id;startedUtc=[DateTime]::UtcNow.ToString('o');source='Continuous real desktop gdigrab at 10fps; original timeline retained';command=$start.Arguments;executable=$exe;executableSha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;timing='Action and screenshot UTC timestamps retained in status; ffmpeg records capture PTS.'}
 Start-Sleep -Milliseconds 1000;$recorder.Refresh();if($recorder.HasExited){$report.recording.status='failed';$report.recording.exitCode=$recorder.ExitCode;Persist;throw 'Continuous recorder exited during initialization.'};Persist;return $report.recording
}
function StopRecording {
 if(-not $recorder){return @{status='not-started'}}
 if(-not $recorder.HasExited){$recorder.StandardInput.WriteLine('q');$recorder.StandardInput.Flush();if(-not $recorder.WaitForExit(15000)){$recorder.Kill();[void]$recorder.WaitForExit(5000);$report.recording.status='incomplete-forced-stop'}}
 if($report.recording.status -ne 'incomplete-forced-stop'){$report.recording.status='capture-finished'}
 $report.recording.finishedUtc=[DateTime]::UtcNow.ToString('o');$report.recording.exitCode=$recorder.ExitCode
 if(Test-Path $report.recording.path){$report.recording.sha256=(Get-FileHash -LiteralPath $report.recording.path -Algorithm SHA256).Hash;$report.recording.bytes=(Get-Item -LiteralPath $report.recording.path).Length}
 $report.recording['verification']='Cloud decode/frame/PTS inspection still required; successful capture process alone is insufficient.';return $report.recording
}
function ErrorDetails {
 Focus;$s=Snapshot 'before-error-details';$error=LabelBounds $s 'Error'
 # v1.14.0 ProgressPage renders a warning-coloured 20px info glyph beside the
 # failed file-row Error label. Require its actual connected pixels, not a
 # blind offset, before invoking the details dialog.
 $left=[int]($error.x-$s.window.Left+$error.width+4);$top=[int]($error.y-$s.window.Top-8)
 $width=[Math]::Min(52,$s.window.Width-$left);$height=[Math]::Min([int]($error.height+20),$s.window.Height-$top)
 if($left -lt 0 -or $top -lt 0 -or $width -lt 20 -or $height -lt 20){throw 'Error icon search region outside owned window.'}
 $image=[Drawing.Bitmap]::new($s.screenshot);$mask=@{};$components=@()
 try{
  for($y=0;$y -lt $height;$y++){for($x=0;$x -lt $width;$x++){$c=$image.GetPixel($left+$x,$top+$y);$spread=[Math]::Max($c.R,[Math]::Max($c.G,$c.B))-[Math]::Min($c.R,[Math]::Min($c.G,$c.B));if($spread -ge 40 -and $c.R -ge 130 -and $c.G -ge 60 -and $c.B -le 180){$mask[$y*$width+$x]=$true}}}
  while($mask.Count -gt 0){$seed=@($mask.Keys)[0];$queue=[Collections.Generic.Queue[int]]::new();$queue.Enqueue($seed);$mask.Remove($seed);$xs=@();$ys=@()
   while($queue.Count -gt 0){$point=$queue.Dequeue();$px=$point%$width;$py=[int][Math]::Floor($point/$width);$xs+=$px;$ys+=$py;foreach($neighbor in @(@(($px-1),$py),@(($px+1),$py),@($px,($py-1)),@($px,($py+1)))){$nx=$neighbor[0];$ny=$neighbor[1];if($nx -ge 0 -and $nx -lt $width -and $ny -ge 0 -and $ny -lt $height){$key=$ny*$width+$nx;if($mask.ContainsKey($key)){$mask.Remove($key);$queue.Enqueue($key)}}}}
   $minx=($xs|Measure-Object -Minimum).Minimum;$maxx=($xs|Measure-Object -Maximum).Maximum;$miny=($ys|Measure-Object -Minimum).Minimum;$maxy=($ys|Measure-Object -Maximum).Maximum;$cw=$maxx-$minx+1;$ch=$maxy-$miny+1
   if($cw -ge 10 -and $cw -le 30 -and $ch -ge 10 -and $ch -le 30 -and [Math]::Abs($cw-$ch) -le 5 -and $xs.Count -ge 40){$components+=@{x=$s.window.Left+$left+$minx;y=$s.window.Top+$top+$miny;width=$cw;height=$ch;pixels=$xs.Count}}
  }
 }finally{$image.Dispose()}
 Json (Join-Path $OutputDirectory ('error-glyph-'+$sequence+'.json')) @{screenshot=$s.screenshot;errorLabel=$error;search=@{left=$left;top=$top;width=$width;height=$height};components=$components;contract='v1.14.0 file-row Error + warning info icon; saturated warning pixels, compact near-square connected component'}
 if($components.Count -ne 1){throw 'No unique observed warning info glyph; details click withheld.'};$glyph=$components[0]
 if(-not(FreshPixels $s $glyph)){throw 'Error glyph changed before input.'}
 [SenderInput]::Click([int]($glyph.x+$glyph.width/2),[int]($glyph.y+$glyph.height/2));$report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='observed-file-error-info-glyph';bounds=$glyph;evidence=$s.screenshot}
 Start-Sleep -Milliseconds 400;$details=Snapshot 'file-error-details'
 [void](LabelBounds $details 'Error');$report['errorDetails']=$details
 return $details
}
function Execute($c){
 switch($c.action){
  'record-start' { return StartRecording }
  'record-stop' { return StopRecording }
  'recorder-start' { return StartRecording }
  'recorder-stop' { return StopRecording }
  'error-details' { return ErrorDetails }
  'network-proof' { return NetworkProof $c.id }
  'screenshot' { Focus; return Snapshot ('command-'+$c.id) }
  'click' { if(-not $c.label){throw 'click needs exact label.'};Click $c.label;return Snapshot ('after-'+$c.id) }
  'add-favorite' {
   Click 'Send';Favorites;Click 'Add';Focus;$s=Snapshot 'favorite-add-dialog'
   foreach($label in @('Add to favorites','IP Address','Port','Confirm')){$bounds=LabelBounds $s $label;if(-not(FreshPixels $s $bounds)){throw "Favorite dialog label changed before typing: $label"}}
   # 1.14.0 FavoriteEditDialog autofocuses IP. Tab order is IP -> Port.
   # Retain the dialog and typed input; no profile injection or protocol registration replaces the UI.
   ControlShortcut 'A';[System.Windows.Forms.SendKeys]::SendWait($receiverHost)
   InputObservation 'favorite-ip-after-literal-typing' $true
   $ipReadback=FavoriteFieldReadback $receiverHost 'IP Address'
   [System.Windows.Forms.SendKeys]::SendWait('{TAB}');ControlShortcut 'A';[System.Windows.Forms.SendKeys]::SendWait([string]$receiverPort)
   $portReadback=FavoriteFieldReadback ([string]$receiverPort) 'Port'
   [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
   $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='favorite IP autofocus and source-defined Tab to Port';ip=$receiverHost;port=$receiverPort;evidence=$s.screenshot}
   $typed=Snapshot 'favorite-typed-values';[void](LabelBounds $typed 'Add to favorites')
   $ipLabel=LabelBounds $typed 'IP Address';$portLabel=LabelBounds $typed 'Port';$confirm=LabelBounds $typed 'Confirm'
   foreach($bounds in @($ipLabel,$portLabel,$confirm)){if(-not(FreshPixels $typed $bounds)){throw 'Favorite field labels or Confirm changed before confirmation.'}}
   $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='favorite actual typed endpoint readback';ip=$ipReadback;port=$portReadback;confirm=$confirm;evidence=$typed.screenshot};Persist
   Click 'Confirm'
   $confirmDeadline=[DateTime]::UtcNow.AddMilliseconds((Remaining 15000));$favoriteObserved=$false;$confirmed=$null;$lastConfirmationSnapshot=$null
   while([DateTime]::UtcNow -lt $confirmDeadline){
    $observed=Snapshot 'favorite-confirmation-observation';$lastConfirmationSnapshot=$observed.screenshot
    if([DateTime]::UtcNow -ge $confirmDeadline){break}
    try{
     [void](LabelBounds $observed 'Favorites');[void](LabelBounds $observed ('('+$receiverHost+')'))
     if($ReceiverName){[void](LabelBounds $observed $ReceiverName)}
    }catch{
     if($_.Exception.Message -notlike 'Label not unique in live UI:*'){throw}
     Start-Sleep -Milliseconds 100;continue
    }
    if([DateTime]::UtcNow -ge $confirmDeadline){break}
    $confirmed=$observed;$favoriteObserved=$true;break
   }
   $report['favoriteConfirmObservation']=@{finishedUtc=[DateTime]::UtcNow.ToString('o');deadlineUtc=$confirmDeadline.ToString('o');actualFavoriteObserved=$favoriteObserved;lastScreenshot=$lastConfirmationSnapshot;ip=$receiverHost;receiverName=$ReceiverName;confirmInputs=1;productCredit=$false};Persist
   if(-not $favoriteObserved){throw 'Favorite confirmation observation deadline expired without the exact actual favorite; infrastructure admission failed.'}
   Click 'Cancel';$sendTab=Snapshot 'favorite-returned-send';[void](LabelBounds $sendTab 'Nearby devices');[void](LabelBounds $sendTab 'File');return $sendTab
  }
  'select' {
   if($c.fixture -eq 'failed' -and (-not $recorder -or $recorder.HasExited)){throw 'Start a real continuous recorder before selecting the failed fixture.'}
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
    # The actual favorite IP remains stable even when the receiver alias varies.
    try{Click ('('+$receiverHost+')');$label='('+$receiverHost+')'}catch{Click $receiverHost;$label=$receiverHost}
   }
   $send=@{started=$true;utc=[DateTime]::UtcNow.ToString('o');receiverName=$label;endpoint=$receiverHost+':'+$receiverPort;processId=$app.Id}
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
 if($env:RECEIVER_HOST){
  $parsed=$null
  if($env:RECEIVER_HOST -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -or -not [Net.IPAddress]::TryParse($env:RECEIVER_HOST,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.ToString() -cne $env:RECEIVER_HOST -or $parsed.Equals([Net.IPAddress]::Any) -or $parsed.Equals([Net.IPAddress]::Broadcast)){throw 'RECEIVER_HOST must be an explicit canonical unicast IPv4 address.'}
  $receiverHost=$parsed.ToString()
  if($parsed.GetAddressBytes()[0] -eq 0 -or $parsed.GetAddressBytes()[0] -ge 224){throw 'RECEIVER_HOST must be unicast IPv4, not unspecified, multicast or reserved space.'}
 }
 foreach($setting in @('RECEIVER_PORT','RECEPTION_PORT')){
  $value=[Environment]::GetEnvironmentVariable($setting);$port=0
  if($value){if($value -notmatch '^[0-9]+$' -or -not [int]::TryParse($value,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw "$setting must be a TCP port from 1 to 65535."};if($setting -eq 'RECEIVER_PORT'){$receiverPort=$port;$receptionPort=$port}else{$receptionPort=$port}}
 }
 if($env:FAILED_FIXTURE_BYTES){if($env:FAILED_FIXTURE_BYTES -notmatch '^[0-9]+$' -or -not [long]::TryParse($env:FAILED_FIXTURE_BYTES,[ref]$failedFixtureBytes) -or $failedFixtureBytes -lt 1 -or $failedFixtureBytes -gt 17179869184){throw 'FAILED_FIXTURE_BYTES must be decimal bytes from 1 to 16GiB.'}}
 $report['receiverEndpoint']=@{host=$receiverHost;port=$receiverPort;receptionPort=$receptionPort;failedFixtureBytes=$failedFixtureBytes}
 if(-not [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($receiverHost))){$report.environmentScope='Actual OS is recorded below. Windows Server differs from Windows11; direct peer target may be a Linux WSL virtual network. Actual app TCP/interface proof is required.';if($receptionPort -ne $receiverPort){throw 'Direct-peer trial requires matching sender reception and receiver ports.'}}
 $report.os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64'){throw 'Official artifact requires x64 Windows.'}
 if(@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue).Count -gt 0){throw 'Another LocalSend exists; require isolated job.'}
 $archive=Join-Path $OutputDirectory 'LocalSend-1.14.0-windows-x86-64.zip'
 Invoke-WebRequest $report.artifactUrl -OutFile $archive -TimeoutSec 120
 $report.archive=@{path=$archive;bytes=(Get-Item $archive).Length;sha256=(Get-FileHash $archive -Algorithm SHA256).Hash}
 if($report.archive.bytes -ne 15368130 -or $report.archive.sha256.ToLowerInvariant() -ne 'e9c595bf3b83d6056e4f81c2867cbf2b65bb16c5cc3a9fc99ff2cd1ce4b45eb5'){throw 'Official Windows1.14 ZIP size/hash differs from the independently retained release asset; extraction withheld.'}
 $release=Join-Path $OutputDirectory 'release';Expand-Archive -LiteralPath $archive -DestinationPath $release
 $executables=@(Get-ChildItem $release -Recurse -File|Where-Object{$_.Name -in @('localsend_app.exe','LocalSend.exe')})
 if($executables.Count -ne 1){throw 'Expected one official executable.'};$exe=$executables[0]
 $report.executable=@{path=$exe.FullName;fileVersion=$exe.VersionInfo.FileVersion;sha256=(Get-FileHash $exe.FullName -Algorithm SHA256).Hash}
 if($env:RECEIVER_PORT -or $env:RECEPTION_PORT){
  # Official1.14 SharedPreferencesPortable reads flutter-prefixed settings.json
  # from the executable working directory. Explicit ordinary observation
  # settings preserve English terminal UI and normal Quit, with encryption off.
  $settingsPath=Join-Path $exe.DirectoryName 'settings.json'
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  try{
   $members=@($zip.Entries|Where-Object {$_.FullName -ceq 'settings.json'})
   if($members.Count -ne 1){throw 'Pinned release must contain exactly one root settings.json member.'}
   $memberStream=$members[0].Open();$memberBytes=[IO.MemoryStream]::new()
   try{$memberStream.CopyTo($memberBytes);$shippedBytes=$memberBytes.ToArray()}finally{$memberStream.Dispose();$memberBytes.Dispose()}
  }finally{$zip.Dispose()}
  $originalSettings=Join-Path $OutputDirectory 'shipped-settings.json'
  if(Test-Path -LiteralPath $originalSettings){throw 'Shipped settings evidence already exists; no overwrite permitted.'}
  [IO.File]::WriteAllBytes($originalSettings,$shippedBytes)
  $shippedHash=(Get-FileHash -LiteralPath $originalSettings -Algorithm SHA256).Hash.ToLowerInvariant()
  $extractedBytes=[IO.File]::ReadAllBytes($settingsPath)
  $extractedHash=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $settingsMatch=[Convert]::ToBase64String($shippedBytes) -ceq [Convert]::ToBase64String($extractedBytes)
  $report['shippedPortablePreferences']=@{archiveMember='settings.json';originalPath=$originalSettings;bytes=$shippedBytes.Length;sha256=$shippedHash;base64=[Convert]::ToBase64String($shippedBytes);extractedPath=$settingsPath;extractedBytes=$extractedBytes.Length;extractedSha256=$extractedHash;archiveExtractedBytesMatch=$settingsMatch}
  Persist
  if(-not $settingsMatch -or $shippedBytes.Length -ne 2 -or $shippedBytes[0] -ne 13 -or $shippedBytes[1] -ne 10 -or $shippedHash -cne '7eb70257593da06f682a3ddda54a9d260d4fc514f645237f5ca74b08f8da61a6'){throw 'Only the independently observed exact shipped CRLF settings placeholder may be initialized; unexpected settings remain untouched.'}
  $initialPreferences=@{'flutter.ls_version'=1;'flutter.ls_port'=$receptionPort;'flutter.ls_locale'='en';'flutter.ls_minimize_to_tray'=$false;'flutter.ls_auto_finish'=$false;'flutter.ls_https'=$false}
  Json $settingsPath $initialPreferences
  $report['portablePreferences']=@{path=$settingsPath;port=$receptionPort;initialSettings=$initialPreferences;sha256BeforeAppStart=(Get-FileHash $settingsPath -Algorithm SHA256).Hash;scope='Supported1.14 initialization of exact retained shipped CRLF placeholder: port/English/normalQuit/terminalUI/encryption-off; no app binary or selected-file injection.'}
  $seedReadback=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($settingsPath)) -ine $exe.DirectoryName -or @($seedReadback.PSObject.Properties).Count -ne $initialPreferences.Count){throw 'Portable seed path or exact preference key set differs before launch.'}
  foreach($key in $initialPreferences.Keys){
   $value=$seedReadback.$key;$expected=$initialPreferences[$key]
   $typeMatches=if($expected -is [bool]){$value -is [bool]}elseif($expected -is [string]){$value -is [string]}else{$value -is [int] -or $value -is [long]}
   if(-not $typeMatches -or $value -cne $expected){throw "Portable seed value or JSON type differs before launch: $key"}
  }
  $report.portablePreferences['seedReadbackVerified']=$true;Persist
 }
 $sysZip=Join-Path $OutputDirectory 'Handle.zip';Invoke-WebRequest 'https://download.sysinternals.com/files/Handle.zip' -OutFile $sysZip -TimeoutSec 120
 Expand-Archive -LiteralPath $sysZip -DestinationPath (Join-Path $OutputDirectory 'sysinternals')
 $report.handleTool=@{url='https://download.sysinternals.com/files/Handle.zip';zipSha256=(Get-FileHash $sysZip -Algorithm SHA256).Hash;exeSha256=(Get-FileHash (Join-Path $OutputDirectory 'sysinternals/handle64.exe') -Algorithm SHA256).Hash;eula='-accepteula explicitly authorized diagnostic observation'}
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($OutputDirectory));$requiredSpace=2*$failedFixtureBytes+2097152+1073741824
 $report['fixtureStorage']=@{root=$drive.Name;fileSystem=$drive.DriveFormat;availableBytes=$drive.AvailableFreeSpace;requiredBytes=$requiredSpace;scope='Both fixtures, one failed-fixture probe backup, and1GiB reserve.'}
 if($drive.DriveFormat -ne 'NTFS' -or $drive.AvailableFreeSpace -lt $requiredSpace){throw 'Fixture creation requires NTFS and enough measured space for source, probe backup and reserve.'}
 # Ordinary deterministic files retain byte(i)=i mod256, including a final partial block.
 $block=[byte[]]::new(1048576);for($i=0;$i -lt $block.Length;$i++){$block[$i]=[byte]($i%256)}
 foreach($entry in @(@{key='control';bytes=[long]1048576},@{key='failed';bytes=$failedFixtureBytes})){
  $sizeLabel=if($entry.bytes%1048576 -eq 0){[string]($entry.bytes/1048576)+'MiB'}else{[string]$entry.bytes+'bytes'}
  $path=Join-Path $OutputDirectory ('1461-'+$entry.key+'-'+$sizeLabel+'.bin');$stream=[IO.File]::Create($path)
  try{for([long]$written=0;$written -lt $entry.bytes;){$count=[int][Math]::Min([long]$block.Length,$entry.bytes-$written);$stream.Write($block,0,$count);$written+=$count}}finally{$stream.Dispose()}
  if((Get-Item $path).Length -ne $entry.bytes){throw 'Fixture write did not produce the requested byte length.'}
  $report.fixtures[$entry.key]=@{path=$path;bytes=(Get-Item $path).Length;sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();selected=$false;pattern='byte at offset i = i mod 256'}
 }
 $rule='LocalSend1461-'+[Guid]::NewGuid().ToString('N');New-NetFirewallRule -Name $rule -DisplayName $rule -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any|Out-Null
 $app=Start-Process $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru;$report.processId=$app.Id;$appStartedTicks=$app.StartTime.ToUniversalTime().Ticks;$report['processStartedUtc']=$app.StartTime.ToUniversalTime().ToString('o')
 $until=[DateTime]::UtcNow.AddSeconds(60);$windows=@()
 do{Start-Sleep -Milliseconds 500;$app.Refresh();if($app.HasExited){throw 'Official sender exited at startup.'};$windows=@([ReceiverNative]::All()|Where-Object{$_.Pid -eq $app.Id -and $_.Visible -and $_.Width -gt 300})}until($windows.Count -gt 0 -or [DateTime]::UtcNow -ge $until)
 if($windows.Count -ne 1){throw 'Single sender window unavailable.'};$appHwnd=[IntPtr]::new($windows[0].Hwnd);Focus;$initial=Snapshot 'ready'
 if($report.portablePreferences){
  # postInit starts the server after HomePage initialization. Observe its
  # listener within the existing startup deadline, preserving process identity.
  $startupListeners=@();$listenerAccepted=$false
  while([DateTime]::UtcNow -lt $until){
   $app.Refresh();if($app.HasExited -or $app.StartTime.ToUniversalTime().Ticks -ne $appStartedTicks){throw 'Original sender process unavailable during startup listener observation.'}
   if([DateTime]::UtcNow -ge $until){break}
   $startupListeners=@(Get-NetTCPConnection -ErrorAction Stop|Where-Object {$_.OwningProcess -eq $app.Id -and $_.State -eq 'Listen' -and $_.LocalPort -eq $receptionPort}|Select-Object LocalAddress,LocalPort,State,OwningProcess)
   if([DateTime]::UtcNow -ge $until){break}
   if($startupListeners.Count -gt 0){$listenerAccepted=$true;break};Start-Sleep -Milliseconds 100
  }
  $report['startupListenerObservation']=@{deadlineUtc=$until.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');acceptedWithinDeadline=$listenerAccepted;lastObservedSockets=$startupListeners;productCredit=$false};Persist
  if(-not $listenerAccepted){throw 'Infrastructure startup reception listener deadline expired; late or missing listener is not readiness evidence.'}
  $actualPreferences=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
  $report['startupPreferences']=@{observedUtc=[DateTime]::UtcNow.ToString('o');path=$settingsPath;sha256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash;alias=$actualPreferences.'flutter.ls_alias';port=$actualPreferences.'flutter.ls_port';locale=$actualPreferences.'flutter.ls_locale';https=$actualPreferences.'flutter.ls_https';minimizeToTray=$actualPreferences.'flutter.ls_minimize_to_tray';autoFinish=$actualPreferences.'flutter.ls_auto_finish';processId=$app.Id;window=$windows[0];listeningSockets=$startupListeners}
  Persist
  foreach($key in $initialPreferences.Keys){if($actualPreferences.$key -cne $initialPreferences[$key]){throw "Actual startup preference differs from supported initialization: $key"}}
  if([string]::IsNullOrWhiteSpace($report.startupPreferences.alias) -or $report.startupPreferences.listeningSockets.Count -eq 0){throw 'Actual generated sender alias and app-owned reception listener are required at startup.'}
 }
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
 if($recorder){try{[void](StopRecording)}catch{$report.errors+='Recorder cleanup: '+$_.Exception.ToString()}}
 if($app -and -not $app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue;$report.cleanup='Forced process cleanup is not normal Quit evidence.'}
 if($rule){Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue}
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o');Persist
 # Keep ready.json as durable identity evidence; status.json is authoritative after stop.
}
if($report.status -eq 'failed'){exit 1}
