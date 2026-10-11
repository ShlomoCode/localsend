# Official LocalSend 1.18.2 UI receiver for the cloud app-to-app control.
param(
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidateRange(30,3600)][int]$TimeoutSeconds=1800,
 [ValidateRange(10,120)][int]$ReadinessSeconds=60,
 [long]$ExpectedBytes=1048576,
 [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256='bf63d8a95fcc2e64619813aae35fdcbe871fdd9264caa3f365eb3aed0f679129',
 [string]$StopFile
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
if (-not $StopFile) { $StopFile=Join-Path $OutputDirectory 'stop' }
$readyPath=Join-Path $OutputDirectory 'ready.json'
$resultPath=Join-Path $OutputDirectory 'results.json'
if (Test-Path $readyPath) { Remove-Item $readyPath }
$report=[ordered]@{
 status='starting'; stage='setup'; startedUtc=[DateTime]::UtcNow.ToString('o')
 release='1.18.2'; artifactUrl='https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip'
 environmentMismatch='Peer device and OS are unspecified in issue 2426; this is a real Windows Server 2022 x64 peer.'
 transportBoundary='Android 127.0.0.1:53318 reverse relay to Windows 127.0.0.1:53317; differs from a shared LAN.'
 evidenceLevel='Actual original Windows LocalSend discovery UI with repeated original Android registration; no file transfer.'
 acceptCapability=@{status='unverified';scope='Window and listener readiness do not verify an observable Accept control.'}
 ocrCapability=@{status='not-probed';limitation=$null}
 runner=$env:RUNNER_NAME; runnerImage=$env:ImageOS; runnerImageVersion=$env:ImageVersion
 os=$null; osArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
 session=$env:SESSIONNAME; archive=$null; executable=$null; processId=$null
 endpoint='https://127.0.0.1:53317'; destination=$null; expectedBytes=$ExpectedBytes; expectedSha256=$ExpectedSha256.ToLowerInvariant()
 snapshots=@(); actions=@(); savedFiles=@(); errors=@()
}
$app=$null; $ruleName=$null; $appHwnd=[IntPtr]::Zero; $exitCode=1
$nextOcr=[DateTime]::MinValue; $ocrNumber=0; $ocrUnavailable=$false
function Write-JsonFile($Path,$Value) {
 [IO.File]::WriteAllText("$Path.tmp",(ConvertTo-Json -InputObject $Value -Depth 12),[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
# Retain setup exceptions too, including native/UI Automation initialization failures.
trap {
 $report.status='incomplete'; $report.errors+=$_.Exception.ToString()
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
 Write-JsonFile $resultPath $report
 exit 1
}
# Typed HWND enumeration and Flutter child hit-testing follow the proven release UI probe.
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
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
function Get-AppElements {
 $root=[System.Windows.Automation.AutomationElement]::FromHandle($appHwnd)
 return $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
}
function Save-Snapshot([string]$Name) {
 $tree=@()
 try {
  if($appHwnd -ne [IntPtr]::Zero) {
   foreach($element in (Get-AppElements)) {
    try { $v=$element.Current; $tree+=@{ name=$v.Name; type=$v.ControlType.ProgrammaticName; enabled=$v.IsEnabled; offscreen=$v.IsOffscreen; bounds=$v.BoundingRectangle.ToString() } } catch {}
    if($tree.Count -ge 500) { break }
   }
  }
 } catch { $report.errors+="UI tree at $Name : $($_.Exception.Message)" }
 $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
 if($screen.Width -le 0 -or $screen.Height -le 0) { throw 'No interactive Windows desktop is available.' }
 $bitmap=[Drawing.Bitmap]::new($screen.Width,$screen.Height)
 try {
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$screen.Size) } finally { $graphics.Dispose() }
  $path=Join-Path $OutputDirectory "$Name.png"; $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
 } finally { $bitmap.Dispose() }
 Write-JsonFile (Join-Path $OutputDirectory "$Name.json") @{
  utc=[DateTime]::UtcNow.ToString('o'); windows=@([ReceiverNative]::All() | Where-Object Visible)
  foregroundHwnd=[ReceiverNative]::GetForegroundWindow().ToInt64(); tree=$tree; screenshot=$path
  screen=@{ left=$screen.Left; top=$screen.Top; width=$screen.Width; height=$screen.Height }
 }
 $report.snapshots+=@{ name=$Name; screenshot=$path; state=(Join-Path $OutputDirectory "$Name.json") }
}
function Get-BitmapDigest([Drawing.Bitmap]$Bitmap) {
 $locked=$Bitmap.LockBits([Drawing.Rectangle]::new(0,0,$Bitmap.Width,$Bitmap.Height),[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
 try {
  $bytes=[byte[]]::new([Math]::Abs($locked.Stride)*$Bitmap.Height)
  [Runtime.InteropServices.Marshal]::Copy($locked.Scan0,$bytes,0,$bytes.Length)
  # PNG decoding can normalize alpha; only the visible RGB pixels determine freshness.
  for($i=3;$i -lt $bytes.Length;$i+=4) { $bytes[$i]=0 }
  $hash=[Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($hash.ComputeHash($bytes)) } finally { $hash.Dispose() }
 } finally { $Bitmap.UnlockBits($locked) }
}

function Observe-Peer([string]$Name,[string]$TapLabel='') {
 Save-Snapshot $Name
 $image=Join-Path $OutputDirectory "$Name.png"; $recognized=Join-Path $OutputDirectory "$Name-ocr.json"
 $worker=Start-Process "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot '../diagnose_2426/native-ocr.ps1'),'-Image',$image,'-Result',$recognized) -PassThru -WindowStyle Hidden
 if(-not $worker.WaitForExit(15000)){$worker.Kill();throw 'OCR timeout'}
 $ocr=Get-Content $recognized -Raw | ConvertFrom-Json
 if($ocr.status -ne 'recognized'){throw 'Native OCR unavailable'}
 if($TapLabel){
  $word=@($ocr.words|Where-Object text -CEQ $TapLabel)
  if($word.Count -ne 1){throw "Expected unique visible $TapLabel word"}
  if([ReceiverNative]::GetForegroundWindow() -ne $appHwnd){throw 'Peer lost foreground'}
  if(-not [ReceiverNative]::ClickScreen($appHwnd,[int]($word[0].x+$word[0].width/2),[int]($word[0].y+$word[0].height/2))){throw 'Peer input failed'}
  $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name=$TapLabel;method='Native OCR unique observed label';bounds=$word[0]}
  Start-Sleep -Milliseconds 800
 }
}
try {
 $report.os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 if($report.osArchitecture -ne 'X64') { throw 'This receiver requires a native x64 Windows runner.' }
 $archive=Join-Path $OutputDirectory 'LocalSend-1.18.2-windows-x86-64.zip'
 Invoke-WebRequest -Uri $report.artifactUrl -OutFile $archive -MaximumRedirection 10 -TimeoutSec 120
 if((Get-Item $archive).Length -lt 1000000) { throw 'Release ZIP download is unexpectedly small.' }
 $report.archive=@{ path=$archive; bytes=(Get-Item $archive).Length; sha256=(Get-FileHash $archive -Algorithm SHA256).Hash }
 $releaseDirectory=Join-Path $OutputDirectory 'release'; Expand-Archive -LiteralPath $archive -DestinationPath $releaseDirectory -Force
 $executables=@(Get-ChildItem $releaseDirectory -Recurse -File | Where-Object { $_.Name -in @('localsend_app.exe','LocalSend.exe') })
 if($executables.Count -ne 1) { throw "Expected one LocalSend executable; found $($executables.Count)." }
 $exe=$executables[0]
 $stream=[IO.File]::OpenRead($exe.FullName)
 try {
  $reader=[IO.BinaryReader]::new($stream)
  [void]$stream.Seek(0x3C,[IO.SeekOrigin]::Begin); $peOffset=$reader.ReadInt32()
  [void]$stream.Seek($peOffset,[IO.SeekOrigin]::Begin)
  if($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Release executable is not a valid x64 PE artifact.' }
 } finally { $stream.Dispose() }
 $report.executable=@{ path=$exe.FullName; fileVersion=$exe.VersionInfo.FileVersion; bytes=$exe.Length; sha256=(Get-FileHash $exe.FullName -Algorithm SHA256).Hash }
 $destination=[ReceiverNative]::Downloads(); [void][IO.Directory]::CreateDirectory($destination)
 $report.destination=@{ path=$destination; method='Normal release default Downloads destination; no Quick Save or profile changes' }
 $beforePaths=@((Get-ChildItem $destination -File -Recurse).FullName)
 if(@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Another LocalSend process exists; require an isolated hosted job.' }
 if(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue) { throw 'Port 53317 is already in use.' }
 $ruleName='LocalSend2426-'+[Guid]::NewGuid().ToString('N')
 New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any | Out-Null
 $app=Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
 $report.processId=$app.Id; $report.stage='readiness'; $deadline=[DateTime]::UtcNow.AddSeconds($ReadinessSeconds)
 do {
  Start-Sleep -Milliseconds 500; $app.Refresh()
  if($app.HasExited) { throw "LocalSend exited during readiness: $($app.ExitCode)" }
  $windows=@([ReceiverNative]::All() | Where-Object { $_.Pid -eq $app.Id -and $_.Visible -and $_.Width -gt 300 -and $_.Height -gt 200 })
  $listeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $app.Id)
 } until(($windows.Count -gt 0 -and $listeners.Count -gt 0) -or [DateTime]::UtcNow -ge $deadline)
 if($windows.Count -eq 0 -or $listeners.Count -eq 0) { throw 'Readiness deadline expired before the release window and its TCP 53317 listener became available.' }
 $appHwnd=[IntPtr]::new($windows[0].Hwnd); [void][ReceiverNative]::Activate($appHwnd); Save-Snapshot 'ready'
 $report.stage='observing-discovered-alias'; $report.status='ready'; Write-JsonFile $resultPath $report
 Write-JsonFile $readyPath @{ ready=$true; utc=[DateTime]::UtcNow.ToString('o'); processId=$app.Id; endpoint=$report.endpoint; destination=$destination; results=$resultPath }

 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$lastId=''
 do {
  if(Test-Path $StopFile){$exitCode=0;$report.status='peer-observation-complete';break}
  $app.Refresh();if($app.HasExited){throw 'Peer exited'}
  $commandPath=Join-Path $OutputDirectory 'command.json'
  if(Test-Path $commandPath){
   $command=Get-Content $commandPath -Raw|ConvertFrom-Json
   if($command.id -ne $lastId){
    $lastId=$command.id
    Observe-Peer $command.id $command.tap
    if($command.tap){Observe-Peer ($command.id+'-after')}
    Write-JsonFile (Join-Path $OutputDirectory ('response-'+$command.id+'.json')) @{id=$command.id;utc=[DateTime]::UtcNow.ToString('o');processId=$app.Id;status='observed'}
   }
  }
  Start-Sleep -Milliseconds 250
 }until([DateTime]::UtcNow -ge $deadline)
 if($exitCode -ne 0){throw 'Peer observer deadline'}
} catch {
 $report.status='incomplete'; $report.errors+=$_.Exception.ToString()
 try { Save-Snapshot 'failure' } catch { $report.errors+="Failure screenshot: $($_.Exception.Message)" }
} finally {
 if($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
 if($ruleName) { Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o'); Write-JsonFile $resultPath $report
 if(Test-Path $readyPath) { Remove-Item $readyPath }
}
exit $exitCode

