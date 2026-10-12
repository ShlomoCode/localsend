# External diagnostic observer; invoked only by the bounded startup-trace workflow.
# Parent starts this before LocalSend, waits for ready.json, then writes target-pid.txt.
# Owns only its unique hook thread and unique ETW session; never closes other sessions.
param([Parameter(Mandatory=$true)][string]$OutputDirectory, [int]$DurationSeconds=20)
$ErrorActionPreference = 'Stop'
if(Test-Path $OutputDirectory) { throw 'Require a fresh observer output directory' }
New-Item -ItemType Directory $OutputDirectory | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class StartupObserver {
  public sealed class WindowEvent {
    public uint Event, EventTick, Pid, ThreadId; public long ReceiptQpc, SampleStartQpc, SampleEndQpc, CallbackEndQpc;
    public string ReceiptUtc, Class; public long Hwnd, Parent, Root;
    public int ObjectId, ChildId; public bool Visible, FrameOk, ClientOk;
    public bool CachedOwner; public int OwnerError, ClassError;
    public Rect Frame, Client; public uint Dpi;
  }
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] struct Msg {
    public IntPtr Hwnd; public uint Message; public UIntPtr WParam; public IntPtr LParam;
    public uint Time; public Point Point; public uint Private;
  }
  delegate void Callback(IntPtr hook,uint ev,IntPtr hwnd,int obj,int child,uint tid,uint time);
  static Callback callback; static Thread thread; static uint threadId;
  static readonly ManualResetEvent ready=new ManualResetEvent(false);
  static readonly ConcurrentQueue<WindowEvent> events=new ConcurrentQueue<WindowEvent>();
  static readonly Dictionary<long,uint> owners=new Dictionary<long,uint>();
  public static string Error; public static long CallbackErrors; public static bool Unhooked; public static bool PerMonitorAware;
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWinEventHook(uint a,uint b,IntPtr mod,Callback fn,uint pid,uint tid,uint flags);
  [DllImport("user32.dll",SetLastError=true)] static extern bool UnhookWinEvent(IntPtr hook);
  [DllImport("user32.dll",SetLastError=true)] static extern int GetMessage(out Msg msg,IntPtr hwnd,uint a,uint b);
  [DllImport("user32.dll")] static extern bool PeekMessage(out Msg msg,IntPtr hwnd,uint a,uint b,uint remove);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg msg);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg msg);
  [DllImport("user32.dll",SetLastError=true)] static extern bool PostThreadMessage(uint tid,uint msg,UIntPtr wp,IntPtr lp);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsWow64Process2(IntPtr process,out ushort processMachine,out ushort nativeMachine);
  public static string Architecture(int pid) { using(var p=Process.GetProcessById(pid)) { ushort pm,nm; if(!IsWow64Process2(p.Handle,out pm,out nm)) return "error:"+Marshal.GetLastWin32Error(); return "processMachine="+pm+",nativeMachine="+nm; } }
  [DllImport("user32.dll",SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
  [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int GetClassName(IntPtr hwnd,System.Text.StringBuilder text,int max);
  delegate bool ChildCallback(IntPtr hwnd,IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd,ChildCallback callback,IntPtr data);
  static void Receive(IntPtr hook,uint ev,IntPtr hwnd,int obj,int child,uint tid,uint time) {
    // Receipt geometry is current state, not event-time historical state. No messages sent.
    try {
      long entryQpc=Stopwatch.GetTimestamp(); string receiptUtc=DateTime.UtcNow.ToString("o");
      if(hwnd==IntPtr.Zero || obj!=0 || child!=0) return;
      if(ev==0x8000) owners.Remove(hwnd.ToInt64());
      uint pid; uint ownerThread=GetWindowThreadProcessId(hwnd,out pid); int ownerError=ownerThread==0?Marshal.GetLastWin32Error():0; bool cached=false;
      if(pid!=0) owners[hwnd.ToInt64()]=pid;
      else if(owners.TryGetValue(hwnd.ToInt64(),out pid)) cached=true;
      var item=new WindowEvent { Event=ev,EventTick=time,ReceiptQpc=entryQpc,ReceiptUtc=receiptUtc,Pid=pid,ThreadId=tid,Hwnd=hwnd.ToInt64(),ObjectId=obj,ChildId=child };
      item.CachedOwner=cached; item.OwnerError=ownerError;
      item.SampleStartQpc=Stopwatch.GetTimestamp();
      item.Parent=GetParent(hwnd).ToInt64(); item.Root=GetAncestor(hwnd,2).ToInt64();
      item.Visible=IsWindowVisible(hwnd); item.FrameOk=GetWindowRect(hwnd,out item.Frame);
      item.ClientOk=GetClientRect(hwnd,out item.Client); item.Dpi=GetDpiForWindow(hwnd);
      var text=new System.Text.StringBuilder(256); if(GetClassName(hwnd,text,256)==0) item.ClassError=Marshal.GetLastWin32Error(); item.Class=text.ToString();
      item.SampleEndQpc=Stopwatch.GetTimestamp();
      // Synthetic inventory events have Event=0 and do not assert child event generation.
      if(ev!=0 && ev!=0x8001) { ChildCallback children=(childHwnd,data)=> { Receive(hook,0,childHwnd,0,0,0,time); return true; }; EnumChildWindows(hwnd,children,IntPtr.Zero); GC.KeepAlive(children); }
      if(ev==0x8001) owners.Remove(hwnd.ToInt64());
      item.CallbackEndQpc=Stopwatch.GetTimestamp(); events.Enqueue(item);
    } catch { Interlocked.Increment(ref CallbackErrors); }
  }
  public static void Start() {
    thread=new Thread(()=> {
      var hooks=new List<IntPtr>();
      try {
        threadId=GetCurrentThreadId(); PerMonitorAware=SetThreadDpiAwarenessContext(new IntPtr(-4))!=IntPtr.Zero; Msg init; PeekMessage(out init,IntPtr.Zero,0,0,0); callback=Receive;
        // Foreground, create/destroy/show/hide, location and parent changes.
        uint[] ids={3,0x8000,0x8001,0x8002,0x8003,0x800B,0x800F};
        foreach(uint id in ids) {
          IntPtr hook=SetWinEventHook(id,id,IntPtr.Zero,callback,0,0,2);
          if(hook==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
          hooks.Add(hook);
        }
        ready.Set(); Msg msg; int result;
        while((result=GetMessage(out msg,IntPtr.Zero,0,0))>0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        if(result<0) throw new Win32Exception(Marshal.GetLastWin32Error());
      } catch(Exception ex) { Error=ex.ToString(); ready.Set(); }
      finally { Unhooked=true; foreach(var hook in hooks) if(!UnhookWinEvent(hook)) Unhooked=false; GC.KeepAlive(callback); }
    }); thread.IsBackground=true; thread.Start();
    if(!ready.WaitOne(5000)) throw new Exception("Hook readiness timed out");
    if(Error!=null) throw new Exception(Error);
  }
  public static WindowEvent[] Drain() { var result=new List<WindowEvent>(); WindowEvent item; while(events.TryDequeue(out item)) result.Add(item); return result.ToArray(); }
  public static void Stop() { if(thread!=null && thread.IsAlive) { if(!PostThreadMessage(threadId,0x12,UIntPtr.Zero,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error()); if(!thread.Join(5000)) throw new Exception("Hook thread did not stop"); } }

  // Unique named Windows8+ system logger. Flags: process/thread/image-load; sequential ETL.
  [StructLayout(LayoutKind.Sequential)] struct Wnode {
    public uint BufferSize,ProviderId; public ulong HistoricalContext; public long TimeStamp;
    public Guid Guid; public uint ClientContext,Flags;
  }
  [StructLayout(LayoutKind.Sequential)] struct Properties {
    public Wnode Wnode; public uint BufferSize,MinimumBuffers,MaximumBuffers,MaximumFileSize;
    public uint LogFileMode,FlushTimer,EnableFlags; public int AgeLimit;
    public uint NumberOfBuffers,FreeBuffers,EventsLost,BuffersWritten,LogBuffersLost,RealTimeBuffersLost;
    public IntPtr LoggerThreadId; public uint LogFileNameOffset,LoggerNameOffset;
  }
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint StartTrace(out ulong handle,string name,IntPtr props);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint ControlTrace(ulong handle,string name,IntPtr props,uint control);
  static IntPtr traceProps; static ulong traceHandle; static string traceName;
  public static uint TraceEventsLost,TraceLogBuffersLost; public static uint TraceStartStatus,TraceStopStatus;
  public static void StartImages(string name,string file) {
    int size=Marshal.SizeOf(typeof(Properties)); byte[] path=System.Text.Encoding.Unicode.GetBytes(file+"\0"), logger=System.Text.Encoding.Unicode.GetBytes(name+"\0");
    traceProps=Marshal.AllocHGlobal(size+path.Length+logger.Length);
    for(int i=0;i<size+path.Length+logger.Length;i++) Marshal.WriteByte(traceProps,i,0);
    var p=new Properties(); p.Wnode.BufferSize=(uint)(size+path.Length+logger.Length);
    p.Wnode.Guid=Guid.NewGuid(); p.Wnode.ClientContext=1; p.Wnode.Flags=0x20000;
    p.BufferSize=64; p.MinimumBuffers=16; p.MaximumBuffers=128; p.LogFileMode=0x02000001; p.FlushTimer=1; p.EnableFlags=7;
    p.LoggerNameOffset=(uint)size; p.LogFileNameOffset=(uint)(size+logger.Length);
    Marshal.StructureToPtr(p,traceProps,false); Marshal.Copy(logger,0,IntPtr.Add(traceProps,size),logger.Length); Marshal.Copy(path,0,IntPtr.Add(traceProps,size+logger.Length),path.Length);
    traceName=name; TraceStartStatus=StartTrace(out traceHandle,name,traceProps);
    if(TraceStartStatus!=0) { Marshal.FreeHGlobal(traceProps); traceProps=IntPtr.Zero; throw new Win32Exception((int)TraceStartStatus); }
  }
  public static void StopImages() {
    if(traceProps==IntPtr.Zero) return;
    try { TraceStopStatus=ControlTrace(traceHandle,traceName,traceProps,1); var p=(Properties)Marshal.PtrToStructure(traceProps,typeof(Properties)); TraceEventsLost=p.EventsLost; TraceLogBuffersLost=p.LogBuffersLost; }
    finally { Marshal.FreeHGlobal(traceProps); traceProps=IntPtr.Zero; }
  }
}
'@
$sessionName='localsend2380-'+[Guid]::NewGuid().ToString('N')
$clock=[Diagnostics.Stopwatch]::StartNew()
$pending=New-Object 'System.Collections.Generic.List[object]'
$windowRows=New-Object 'System.Collections.Generic.List[object]'
$moduleRows=New-Object 'System.Collections.Generic.List[object]'
$targetPid=$null
$targetClock=$null
$lastInventory=-1
$unknownRows=New-Object 'System.Collections.Generic.List[object]'
$failure=$null
try {
  [StartupObserver]::StartImages($sessionName,(Join-Path $OutputDirectory 'image-process.etl'))
  [StartupObserver]::Start()
  @{session=$sessionName; utc=[DateTime]::UtcNow.ToString('o'); qpc=[Diagnostics.Stopwatch]::GetTimestamp(); qpcFrequency=[Diagnostics.Stopwatch]::Frequency; tick64=[StartupObserver]::GetTickCount64(); observerPid=$PID; observerArchitecture=[StartupObserver]::Architecture($PID); phase='hooks-and-etw-ready'} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'ready.json')
  while(!$targetClock -or $targetClock.Elapsed.TotalSeconds -lt $DurationSeconds) {
    if(!$targetClock -and $clock.Elapsed.TotalSeconds -gt 30) { throw 'Target registration timeout' }
    foreach($item in [StartupObserver]::Drain()) { $pending.Add($item) }
    $pidFile=Join-Path $OutputDirectory 'target-pid.txt'
    if(!$targetPid -and (Test-Path $pidFile)) { $raw=Get-Content $pidFile -Raw; if(![string]::IsNullOrEmpty($raw) -and $raw.Trim() -match '^\d+$') { $targetPid=[int]$raw.Trim(); $targetClock=[Diagnostics.Stopwatch]::StartNew(); @{pid=$targetPid;utc=[DateTime]::UtcNow.ToString('o');qpc=[Diagnostics.Stopwatch]::GetTimestamp();architecture=[StartupObserver]::Architecture($targetPid)} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'target-registration.json') } }
    if($targetPid) {
      foreach($item in $pending) { if($item.Pid -eq $targetPid) { $windowRows.Add($item) } elseif($item.Pid -eq 0) { $unknownRows.Add($item) } }; $pending.Clear()
      if($targetClock.Elapsed.TotalSeconds - $lastInventory -lt 0.25) { Start-Sleep -Milliseconds 10; continue }
      $lastInventory=$targetClock.Elapsed.TotalSeconds
      $start=[Diagnostics.Stopwatch]::GetTimestamp(); $modules=@(); $errorText=$null
      try { $process=Get-Process -Id $targetPid; foreach($module in $process.Modules) { $modules+=@{path=$module.FileName;base=$module.BaseAddress.ToInt64();size=$module.ModuleMemorySize} } }
      catch { $errorText=$_.Exception.ToString() }
      $moduleRows.Add(@{startQpc=$start;endQpc=[Diagnostics.Stopwatch]::GetTimestamp();utc=[DateTime]::UtcNow.ToString('o');pid=$targetPid;modules=$modules;error=$errorText;meaning='inventory at sample; not load timestamp'})
    }
    Start-Sleep -Milliseconds 10
  }
} catch { $failure=$_.Exception.ToString() }
finally {
  try { [StartupObserver]::Stop() } catch { $failure+='; hook stop: '+$_.Exception.ToString() }
  foreach($item in [StartupObserver]::Drain()) { if($targetPid -and $item.Pid -eq $targetPid) { $windowRows.Add($item) } elseif($item.Pid -eq 0) { $unknownRows.Add($item) } }
  [StartupObserver]::StopImages()
  ConvertTo-Json -InputObject @($windowRows.ToArray()) -Depth 8 | Set-Content (Join-Path $OutputDirectory 'window-events.json')
  ConvertTo-Json -InputObject @($unknownRows.ToArray()) -Depth 8 | Set-Content (Join-Path $OutputDirectory 'unattributed-events.json')
  ConvertTo-Json -InputObject @($moduleRows.ToArray()) -Depth 8 | Set-Content (Join-Path $OutputDirectory 'module-inventories.json')
  @{session=$sessionName;targetPid=$targetPid;failure=$failure;hookError=[StartupObserver]::Error;callbackErrors=[StartupObserver]::CallbackErrors;unhooked=[StartupObserver]::Unhooked;perMonitorAware=[StartupObserver]::PerMonitorAware;etwStart=[StartupObserver]::TraceStartStatus;etwStop=[StartupObserver]::TraceStopStatus;eventsLost=[StartupObserver]::TraceEventsLost;logBuffersLost=[StartupObserver]::TraceLogBuffersLost} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'observer-status.json')
}
if($failure -or !$targetPid -or [StartupObserver]::Error -or [StartupObserver]::CallbackErrors -ne 0 -or ![StartupObserver]::Unhooked -or [StartupObserver]::TraceStopStatus -ne 0 -or [StartupObserver]::TraceEventsLost -ne 0 -or [StartupObserver]::TraceLogBuffersLost -ne 0 -or $windowRows.Count -eq 0 -or @($moduleRows | Where-Object { !$_.error -and $_.modules.Count -gt 0 }).Count -eq 0) { throw 'Observer incomplete; see observer-status.json' }
