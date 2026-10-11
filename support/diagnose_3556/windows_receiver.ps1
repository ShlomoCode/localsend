# Official LocalSend 1.18.2 UI receiver for the cloud app-to-app control.
param(
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [ValidateRange(30,7200)][int]$TimeoutSeconds=1800,
 [ValidateRange(10,120)][int]$ReadinessSeconds=60,
 [long]$ExpectedBytes=1048576,
 [ValidatePattern('^([0-9a-fA-F]{64})?$')][string]$ExpectedSha256='bf63d8a95fcc2e64619813aae35fdcbe871fdd9264caa3f365eb3aed0f679129',
 [string]$VerificationDeadlineUtc,
 [string]$SenderCompletionFile,
 [string]$SendStartedFile,
 [string]$ExpectedHashFile,
 [ValidateRange(30,900)][int]$HashTimeoutSeconds=900,
 [ValidateRange(4,120)][int]$ImageLimit=60,
 [ValidateRange(1,300)][int]$UiObservationLimit=150,
 [string]$StopFile
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
if (-not $StopFile) { $StopFile=Join-Path $OutputDirectory 'stop' }
$large=$ExpectedBytes -eq 16000000000L
$boundedDiagnostic=$large -or $env:LARGE_TRANSFER_DIAGNOSTIC -eq '1'
if (-not $SenderCompletionFile) { $SenderCompletionFile=Join-Path $OutputDirectory 'sender-completed.json' }
if (-not $SendStartedFile) { $SendStartedFile=Join-Path $OutputDirectory 'send-started.json' }
if (-not $ExpectedHashFile) { $ExpectedHashFile=Join-Path $OutputDirectory 'expected-sha256.json' }
$verificationDeadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
if ($VerificationDeadlineUtc) {
 $parentDeadline=[DateTime]::Parse($VerificationDeadlineUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
 if($parentDeadline -lt $verificationDeadline) { $verificationDeadline=$parentDeadline }
} elseif($large) { throw 'Large receiver requires the parent absolute VerificationDeadlineUtc (session age 105 minutes or earlier).' }
if($verificationDeadline -le [DateTime]::UtcNow) { throw 'Parent verification deadline has already expired.' }
$readyPath=Join-Path $OutputDirectory 'ready.json'
$resultPath=Join-Path $OutputDirectory 'results.json'
if (Test-Path $readyPath) { Remove-Item $readyPath }
$report=[ordered]@{
 status='starting'; stage='setup'; startedUtc=[DateTime]::UtcNow.ToString('o')
 release='1.18.2'; artifactUrl='https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip'
 environmentMismatch='GitHub-hosted Windows Server 2022/2025 differs from the reported Windows 10 Pro.'
 transportBoundary='Android 127.0.0.1:53318 reverse relay to Windows 127.0.0.1:53317; differs from a shared LAN.'
 evidenceLevel='Prepared actual-release UI receiver; inspect cloud evidence before classifying.'
 acceptCapability=@{status='unverified';scope='Window and listener readiness do not verify an observable Accept control.'}
 ocrCapability=@{status='not-probed';limitation=$null}
 runner=$env:RUNNER_NAME; runnerImage=$env:ImageOS; runnerImageVersion=$env:ImageVersion
 os=$null; osArchitecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
 session=$env:SESSIONNAME; archive=$null; executable=$null; processId=$null
 endpoint='https://127.0.0.1:53317'; destination=$null; expectedBytes=$ExpectedBytes; expectedSha256=$ExpectedSha256.ToLowerInvariant()
 verificationDeadlineUtc=$verificationDeadline.ToString('o'); hashWorkers=@(); senderCompletion=$null; receiverCompletion=$null
 imageLimit=$ImageLimit; imageCount=0; terminalImageReserve=[Math]::Min(10,$ImageLimit-2); uiObservationLimit=$UiObservationLimit; uiObservationCount=0; terminalObservationReserve=4; uiWorkers=@()
 snapshots=@(); actions=@(); savedFiles=@(); errors=@()
}
$app=$null; $ruleName=$null; $appHwnd=[IntPtr]::Zero; $exitCode=1
$nextOcr=[DateTime]::MinValue; $ocrNumber=0; $ocrUnavailable=$false; $verifiedHashes=@{}; $nextUiProbe=[DateTime]::MinValue; $acceptProbes=0; $completionProbes=0
function Get-RemainingMilliseconds([int]$Maximum) {
 $remaining=[int][Math]::Max(0,[Math]::Min($Maximum,($verificationDeadline-[DateTime]::UtcNow).TotalMilliseconds))
 if($remaining -le 0) { throw 'Absolute verification deadline expired.' }
 return $remaining
}
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
 if($boundedDiagnostic) { throw 'Diagnostic UI Automation must run in a bounded child process.' }
 $root=[System.Windows.Automation.AutomationElement]::FromHandle($appHwnd)
 return $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
}
function Get-BoundedUiSnapshot([string]$Name) {
 if($report.uiObservationCount -ge $report.uiObservationLimit) { return @() }
 $terminal=$Name -in @('failure','saved-file-verified','before-saved-file-hash','receiver-finished') -or $Name.StartsWith('completion-ocr-')
 if(-not $terminal -and $report.uiObservationCount -ge $report.uiObservationLimit-$report.terminalObservationReserve) { return @() }
 $report.uiObservationCount++
 $scriptPath=Join-Path $OutputDirectory 'uia-snapshot-worker.ps1'
 if(-not (Test-Path $scriptPath)) {
  [IO.File]::WriteAllText($scriptPath,@'
param([long]$Hwnd,[string]$Result,[string]$DeadlineUtc)
$ErrorActionPreference='Stop'
$deadline=[DateTime]::Parse($DeadlineUtc).ToUniversalTime()
if([DateTime]::UtcNow -ge $deadline) { throw 'UIA worker deadline expired before observation.' }
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new($Hwnd))
$elements=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
$tree=@()
foreach($element in $elements) {
 if([DateTime]::UtcNow -ge $deadline) { throw 'UIA worker deadline expired.' }
 try { $v=$element.Current; $tree+=@{name=$v.Name;type=$v.ControlType.ProgrammaticName;enabled=$v.IsEnabled;offscreen=$v.IsOffscreen;bounds=$v.BoundingRectangle.ToString()} } catch {}
 if($tree.Count -ge 500) { break }
}
[IO.File]::WriteAllText($Result,(ConvertTo-Json -InputObject $tree -Depth 6),[Text.UTF8Encoding]::new($false))
'@,[Text.UTF8Encoding]::new($false))
 }
 $result=Join-Path $OutputDirectory ($Name+'-uia-worker.json')
 $worker=$null; $entry=$null
 try {
  $bound=Get-RemainingMilliseconds 30000
  $workerDeadline=[DateTime]::UtcNow.AddMilliseconds($bound).ToString('o')
  $worker=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-Hwnd',$appHwnd.ToInt64(),'-Result',('"'+$result+'"'),'-DeadlineUtc',('"'+$workerDeadline+'"')) -PassThru -WindowStyle Hidden
  $entry=@{name=$Name;processId=$worker.Id;status='running';timeoutMs=$bound}; $report.uiWorkers+=$entry
  if(-not $worker.WaitForExit((Get-RemainingMilliseconds $bound))) { throw 'UI Automation snapshot exceeded its 30-second/remaining-deadline bound.' }
  if($worker.ExitCode -ne 0 -or -not (Test-Path $result)) { throw 'UI Automation snapshot worker failed.' }
  $entry.status='complete'
  return @(Get-Content -LiteralPath $result -Raw | ConvertFrom-Json)
 } catch {
  if($entry) { $entry.status='failed'; $entry.error=$_.Exception.Message }
  $report.errors+="Bounded UI tree at $Name : $($_.Exception.Message)"
  return @()
 } finally {
  if($worker -and -not $worker.HasExited) { $worker.Kill(); [void]$worker.WaitForExit(5000) }
 }
}
function Save-Snapshot([string]$Name) {
 $terminal=$Name -in @('failure','saved-file-verified','before-saved-file-hash','receiver-finished') -or $Name.StartsWith('completion-ocr-')
 $allowed=$report.imageLimit
 if(-not $terminal) { $allowed-=$report.terminalImageReserve }
 if($boundedDiagnostic -and $report.imageCount -ge $allowed) { return }
 $tree=@()
 try {
  if($appHwnd -ne [IntPtr]::Zero) {
   if($boundedDiagnostic) { $tree=Get-BoundedUiSnapshot $Name } else { foreach($element in (Get-AppElements)) {
    try { $v=$element.Current; $tree+=@{ name=$v.Name; type=$v.ControlType.ProgrammaticName; enabled=$v.IsEnabled; offscreen=$v.IsOffscreen; bounds=$v.BoundingRectangle.ToString() } } catch {}
    if($tree.Count -ge 500) { break }
   }
   }
  }
 } catch { $report.errors+="UI tree at $Name : $($_.Exception.Message)" }
 $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
 if($screen.Width -le 0 -or $screen.Height -le 0) { throw 'No interactive Windows desktop is available.' }
 $bitmap=[Drawing.Bitmap]::new($screen.Width,$screen.Height)
 try {
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try { $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$screen.Size) } finally { $graphics.Dispose() }
  $path=Join-Path $OutputDirectory "$Name.png"; $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png); $report.imageCount++
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
function Invoke-OcrAccept([switch]$Completion) {
 # UIA can expose only FLUTTERVIEW in the official release. OCR must prove an incoming dialog first.
 if([DateTime]::UtcNow -lt $script:nextOcr) { return $false }
 $ocrLimit=$report.imageLimit-$report.terminalImageReserve
 if($Completion) { $ocrLimit=$report.imageLimit-2 }
 $observationLimit=$report.uiObservationLimit-$report.terminalObservationReserve
 if($Completion) { $observationLimit=$report.uiObservationLimit-2 }
 if($boundedDiagnostic -and ($report.imageCount+2 -gt $ocrLimit -or $report.uiObservationCount+2 -gt $observationLimit)) { throw 'Diagnostic OCR observation/image budget exhausted; retain terminal evidence and stop.' }
 # Count attempted OCR probes even if capability/setup prevents worker launch.
 if($boundedDiagnostic) { $report.uiObservationCount++ }
 if($script:ocrUnavailable) { return $false }
 $script:nextOcr=[DateTime]::UtcNow.AddSeconds(5); $script:ocrNumber++
 $name='ocr-{0:D3}' -f $script:ocrNumber
 if($Completion) { $name='completion-'+$name }
 Save-Snapshot $name
 $window=@([ReceiverNative]::All() | Where-Object { $_.Hwnd -eq $appHwnd.ToInt64() -and $_.Visible })
 if($window.Count -ne 1 -or [ReceiverNative]::GetForegroundWindow() -ne $appHwnd) { return $false }
 $w=$window[0]; $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
 $rect=[Drawing.Rectangle]::new($w.Left-$screen.Left,$w.Top-$screen.Top,$w.Width,$w.Height)
 $full=[Drawing.Bitmap]::new((Join-Path $OutputDirectory "$name.png"))
 try {
  if($rect.Left -lt 0 -or $rect.Top -lt 0 -or $rect.Right -gt $full.Width -or $rect.Bottom -gt $full.Height) { return $false }
  $frame=$full.Clone($rect,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
   $framePath=Join-Path $OutputDirectory "$name-window.png"; $frame.Save($framePath,[Drawing.Imaging.ImageFormat]::Png); $report.imageCount++
   $digest=Get-BitmapDigest $frame
  } finally { $frame.Dispose() }
 } finally { $full.Dispose() }
 $ocrScript=Join-Path $OutputDirectory 'native-ocr.ps1'
 if(-not (Test-Path $ocrScript)) {
  # Framework Windows PowerShell supports native WinRT projection independently of pwsh's runtime.
  [IO.File]::WriteAllText($ocrScript,@'
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
 }
 $result=Join-Path $OutputDirectory "$name-recognized.json"
 $worker=$null
 try {
  $workerDeadline=[DateTime]::UtcNow.AddMilliseconds((Get-RemainingMilliseconds 15000)).ToString('o')
  $worker=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$ocrScript+'"'),'-Image',('"'+$framePath+'"'),'-Result',('"'+$result+'"'),'-DeadlineUtc',('"'+$workerDeadline+'"')) -PassThru -WindowStyle Hidden
  if(-not $worker.WaitForExit((Get-RemainingMilliseconds 15000))) { $worker.Kill(); throw 'Native Windows OCR exceeded its bounded verification time.' }
  if(-not (Test-Path $result)) { throw 'Native Windows OCR produced no result.' }
  $observed=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
  if($observed.status -ne 'recognized') { throw "Native Windows OCR unsupported: $($observed.error)" }
 } catch {
  # Capability probing happens while idle too. Preserve the limitation without aborting before Send.
  $script:ocrUnavailable=$true; $report.ocrCapability.status='unsupported'; $report.ocrCapability.limitation=$_.Exception.Message
  if(-not (Test-Path $result)) { Write-JsonFile $result @{status='unsupported';image=$framePath;error=$_.Exception.ToString();words=@()} }
  Write-JsonFile $resultPath $report
  return $false
 } finally {
  if($worker -and -not $worker.HasExited) { $worker.Kill(); [void]$worker.WaitForExit(5000) }
 }
 $report.ocrCapability.status='recognized'
 if($Completion) {
  $finished=@($observed.words | Where-Object text -CEQ 'Finished')
  $done=@($observed.words | Where-Object text -CEQ 'Done')
  if($finished.Count -eq 1 -and $done.Count -ge 1) {
   $report.receiverCompletion=@{utc=[DateTime]::UtcNow.ToString('o');method='Native OCR observed Finished and Done in receiver window';recognized=$result;screenshot=$framePath}
   return $true
  }
  return $false
 }
 $accept=@($observed.words | Where-Object text -CEQ 'Accept')
 $decline=@($observed.words | Where-Object text -CEQ 'Decline')
 if($accept.Count -eq 0 -or $decline.Count -eq 0) { return $false }
 if($accept.Count -ne 1 -or $decline.Count -ne 1 -or $null -ne $observed.textAngle -and [Math]::Abs([double]$observed.textAngle) -gt 1) { throw 'Incoming OCR buttons are ambiguous or rotated; no click.' }
 $button=$accept[0]; $other=$decline[0]
 if($button.width -le 0 -or $button.height -le 0 -or $button.x -lt 0 -or $button.y -lt 0 -or $button.x+$button.width -gt $w.Width -or $button.y+$button.height -gt $w.Height -or [Math]::Abs($button.y-$other.y) -gt [Math]::Max($button.height,$other.height)*2) { throw 'Incoming OCR button bounds are invalid; no click.' }
 Write-JsonFile (Join-Path $OutputDirectory "$name-incoming.json") @{utc=[DateTime]::UtcNow.ToString('o');recognized=$result;screenshot=$framePath;accept=$button;decline=$other;window=$w;visibleRgbSha256=$digest}
 # Recheck ownership, foreground, geometry and every window pixel immediately before input.
 $now=@([ReceiverNative]::All() | Where-Object { $_.Hwnd -eq $appHwnd.ToInt64() -and $_.Visible })
 if($now.Count -ne 1 -or [ReceiverNative]::GetForegroundWindow() -ne $appHwnd -or $now[0].Left -ne $w.Left -or $now[0].Top -ne $w.Top -or $now[0].Width -ne $w.Width -or $now[0].Height -ne $w.Height) { return $false }
 $fresh=[Drawing.Bitmap]::new($w.Width,$w.Height)
 try {
  $graphics=[Drawing.Graphics]::FromImage($fresh)
  try { $graphics.CopyFromScreen($w.Left,$w.Top,0,0,$fresh.Size) } finally { $graphics.Dispose() }
  if((Get-BitmapDigest $fresh) -ne $digest) { return $false }
 } finally { $fresh.Dispose() }
 $x=[int][Math]::Round($w.Left+$button.x+$button.width/2); $y=[int][Math]::Round($w.Top+$button.y+$button.height/2)
 if(-not [ReceiverNative]::ClickScreen($appHwnd,$x,$y)) { throw 'Could not click the fresh OCR Accept bounds.' }
 $report.acceptCapability.status='verified-native-ocr-accept'
 $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='Accept';method='Native Windows OCR unique Accept and Decline, unchanged foreground window pixels';bounds=$button;screenCenter=@{x=$x;y=$y};recognized=$result;screenshot=$framePath}
 Start-Sleep -Milliseconds 500; Save-Snapshot 'after-accept'; return $true
}
function Invoke-Accept {
 if($boundedDiagnostic) { return Invoke-OcrAccept }
 $hasUiaAccept=$false
 foreach($element in (Get-AppElements)) {
  try { $v=$element.Current } catch [System.Windows.Automation.ElementNotAvailableException] { continue }
  if($v.Name -eq 'Accept') { $hasUiaAccept=$true }
  if($v.Name -ne 'Accept' -or -not $v.IsEnabled -or $v.IsOffscreen -or $v.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
  Save-Snapshot 'incoming-before-accept'; $pattern=$null; $method='UI Automation InvokePattern'
  if($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) {
   ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
  } else {
   $bounds=$v.BoundingRectangle
   if(-not [ReceiverNative]::ClickScreen($appHwnd,[int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))) { throw 'Could not click the observed Accept button bounds.' }
   $method='Typed native HWND input at observed semantic Accept button bounds'
  }
  $report.actions+=@{ utc=[DateTime]::UtcNow.ToString('o'); name='Accept'; method=$method; bounds=$v.BoundingRectangle.ToString() }
  $report.acceptCapability.status='verified-uia-accept'
  Start-Sleep -Milliseconds 500; Save-Snapshot 'after-accept'; return $true
 }
 if($hasUiaAccept) { return $false }
 return Invoke-OcrAccept
}
function Invoke-ReceiverCompletion {
 if($boundedDiagnostic) { return Invoke-OcrAccept -Completion }
 $names=@()
 foreach($element in (Get-AppElements)) {
  try { $v=$element.Current; if(-not $v.IsOffscreen) { $names+=$v.Name } } catch {}
 }
 if('Finished' -in $names -and 'Done' -in $names) {
  Save-Snapshot 'receiver-finished'
  $report.receiverCompletion=@{utc=[DateTime]::UtcNow.ToString('o');method='UI Automation observed visible Finished and Done';screenshot=(Join-Path $OutputDirectory 'receiver-finished.png')}
  return $true
 }
 return Invoke-OcrAccept -Completion
}
function Get-DestinationCapacity([string]$Path) {
 $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
 $drive=[IO.DriveInfo]::new($root)
 if(-not $drive.IsReady){throw "Destination drive is not ready: $root"}
 return @{utc=[DateTime]::UtcNow.ToString('o');path=$Path;driveRoot=$root;availableFreeBytes=$drive.AvailableFreeSpace;totalFreeBytes=$drive.TotalFreeSpace;totalBytes=$drive.TotalSize;driveFormat=$drive.DriveFormat}
}
function Get-BoundedFileHash([string]$Path,[string]$Label) {
 $scriptPath=Join-Path $OutputDirectory 'hash-worker.ps1'
 if(-not (Test-Path $scriptPath)) {
  [IO.File]::WriteAllText($scriptPath,@'
param([string]$Path,[string]$Result,[string]$DeadlineUtc)
$ErrorActionPreference='Stop'
$deadline=[DateTime]::Parse($DeadlineUtc).ToUniversalTime()
if([DateTime]::UtcNow -ge $deadline) { throw 'Hash worker deadline expired before reading.' }
# An exclusive-to-writers read rejects files still open for writing by the app.
$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
 $hash=[Security.Cryptography.SHA256]::Create()
 try { $digest=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
 if([DateTime]::UtcNow -ge $deadline) { throw 'Hash worker deadline expired before result.' }
 [IO.File]::WriteAllText($Result,(ConvertTo-Json @{bytes=$stream.Length;sha256=$digest}),[Text.UTF8Encoding]::new($false))
} finally { $stream.Dispose() }
'@,[Text.UTF8Encoding]::new($false))
 }
 $result=Join-Path $OutputDirectory ($Label+'-hash.json')
 if(Test-Path $result) { Remove-Item -LiteralPath $result }
 $worker=$null; $entry=$null; $started=[DateTime]::UtcNow
 $bound=$started.AddSeconds($HashTimeoutSeconds)
 if($verificationDeadline -lt $bound) { $bound=$verificationDeadline }
 try {
  [void](Get-RemainingMilliseconds 1)
  $worker=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-Path',('"'+$Path+'"'),'-Result',('"'+$result+'"'),'-DeadlineUtc',('"'+$bound.ToString('o')+'"')) -PassThru -WindowStyle Hidden
  $entry=@{label=$Label;processId=$worker.Id;startedUtc=$started.ToString('o');deadlineUtc=$bound.ToString('o');status='running'}
  $report.hashWorkers+=$entry; Write-JsonFile $resultPath $report
  while(-not $worker.WaitForExit((Get-RemainingMilliseconds 250))) {
   if(Test-Path $StopFile) { throw 'Workflow stopped the hash worker.' }
   if([DateTime]::UtcNow -ge $bound) { throw 'Hash worker exceeded its bounded verification deadline.' }
  }
  if($worker.ExitCode -ne 0 -or -not (Test-Path $result)) { throw 'Hash worker failed; saved file may still be open for writing.' }
  $observed=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
  if($observed.sha256 -notmatch '^[0-9a-f]{64}$' -or $observed.bytes -ne $ExpectedBytes) { throw 'Hash worker returned invalid content metadata.' }
  $entry.status='complete'; $entry.finishedUtc=[DateTime]::UtcNow.ToString('o')
  return $observed.sha256
 } finally {
  if($worker -and -not $worker.HasExited) { $worker.Kill(); [void]$worker.WaitForExit(5000) }
  if($entry -and $entry.status -eq 'running') { $entry.status='terminated'; $entry.finishedUtc=[DateTime]::UtcNow.ToString('o') }
 }
}
try {
 $report.os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 if($report.osArchitecture -ne 'X64') { throw 'This receiver requires a native x64 Windows runner.' }
 $archive=Join-Path $OutputDirectory 'LocalSend-1.18.2-windows-x86-64.zip'
 $downloadSeconds=[Math]::Max(1,[Math]::Floor((Get-RemainingMilliseconds 120000)/1000))
 Invoke-WebRequest -Uri $report.artifactUrl -OutFile $archive -MaximumRedirection 10 -TimeoutSec $downloadSeconds
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
 $report.destination.capacityBefore=Get-DestinationCapacity $destination
 $requiredBytes=$ExpectedBytes+2147483648L
 $report.destination.requiredFreeBytes=$requiredBytes
 if($report.destination.capacityBefore.availableFreeBytes -lt $requiredBytes){throw 'Actual Windows Downloads drive needs fixture bytes plus 2GiB free reserve.'}
 $beforePaths=@((Get-ChildItem $destination -File -Recurse).FullName)
 if(@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Another LocalSend process exists; require an isolated hosted job.' }
 if(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue) { throw 'Port 53317 is already in use.' }
 $ruleName='LocalSend3556-'+[Guid]::NewGuid().ToString('N')
 New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any | Out-Null
 $app=Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
 $report.processId=$app.Id; $report.stage='readiness'; $deadline=[DateTime]::UtcNow.AddSeconds($ReadinessSeconds)
 if($verificationDeadline -lt $deadline) { $deadline=$verificationDeadline }
 do {
  Start-Sleep -Milliseconds 500; $app.Refresh()
  if($app.HasExited) { throw "LocalSend exited during readiness: $($app.ExitCode)" }
  $windows=@([ReceiverNative]::All() | Where-Object { $_.Pid -eq $app.Id -and $_.Visible -and $_.Width -gt 300 -and $_.Height -gt 200 })
  $listeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $app.Id)
 } until(($windows.Count -gt 0 -and $listeners.Count -gt 0) -or [DateTime]::UtcNow -ge $deadline)
 if($windows.Count -eq 0 -or $listeners.Count -eq 0) { throw 'Readiness deadline expired before the release window and its TCP 53317 listener became available.' }
 $appHwnd=[IntPtr]::new($windows[0].Hwnd); [void][ReceiverNative]::Activate($appHwnd); Save-Snapshot 'ready'
 $report.stage='waiting-for-receive-request'; $report.status='ready'; Write-JsonFile $resultPath $report
 Write-JsonFile $readyPath @{ ready=$true; utc=[DateTime]::UtcNow.ToString('o'); processId=$app.Id; endpoint=$report.endpoint; destination=$destination; results=$resultPath }
 $deadline=$verificationDeadline; $accepted=$false
 $snapshotInterval=30; if($large) { $snapshotInterval=120 }
 $nextSnapshot=[DateTime]::UtcNow.AddSeconds($snapshotInterval); $snapshotNumber=0
 do {
  if(Test-Path $StopFile) { throw 'Workflow stopped the receiver before a verified save.' }
  $app.Refresh(); if($app.HasExited) { throw 'LocalSend exited before a verified save.' }
  $sendStarted=-not $large
  if($large -and (Test-Path $SendStartedFile)) {
   $send=Get-Content -LiteralPath $SendStartedFile -Raw | ConvertFrom-Json
   if($send.started -eq $true -and $send.utc) {
    $sendUtc=[DateTime]::Parse($send.utc).ToUniversalTime()
    $sendStarted=$sendUtc -ge [DateTime]::Parse($report.startedUtc).ToUniversalTime() -and $sendUtc -le [DateTime]::UtcNow
   }
  }
  if(-not $accepted -and $sendStarted -and [DateTime]::UtcNow -ge $nextUiProbe) {
   if($large) { $nextUiProbe=[DateTime]::UtcNow.AddSeconds(40) }
   if($large -and $acceptProbes -ge 5) { throw 'No observed Accept after five bounded post-Send UI probes.' }
   $acceptProbes++
   $report.destination.capacityBeforeAccept=Get-DestinationCapacity $destination
   if($report.destination.capacityBeforeAccept.availableFreeBytes -lt $requiredBytes) { throw 'Fresh Downloads capacity before Accept is below fixture plus 2GiB.' }
   $accepted=Invoke-Accept
   if($accepted) { $report.stage='waiting-for-saved-file'; Write-JsonFile $resultPath $report }
  }
  if($accepted) {
   $completionAllowed=-not $large
   if($large -and (Test-Path $SenderCompletionFile)) {
    $completion=Get-Content -LiteralPath $SenderCompletionFile -Raw | ConvertFrom-Json
    if($completion.completed -eq $true -and $completion.utc -and $completion.evidence) {
     $completedUtc=[DateTime]::Parse($completion.utc).ToUniversalTime()
     if($completedUtc -ge [DateTime]::Parse($report.startedUtc).ToUniversalTime() -and $completedUtc -le [DateTime]::UtcNow) {
      $report.senderCompletion=$completion; $completionAllowed=$true
     }
    }
   }
   if($large -and $completionAllowed -and (Test-Path $ExpectedHashFile)) {
    $expected=Get-Content -LiteralPath $ExpectedHashFile -Raw | ConvertFrom-Json
    if($expected.bytes -ne $ExpectedBytes -or $expected.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Android post-completion hash metadata is invalid.' }
    $ExpectedSha256=$expected.sha256.ToLowerInvariant(); $report.expectedSha256=$ExpectedSha256
   }
   if($large -and $completionAllowed -and -not $report.receiverCompletion -and [DateTime]::UtcNow -ge $nextUiProbe) {
    if($completionProbes -ge 4) { throw 'No observed Finished and Done after four bounded post-completion UI probes.' }
    $completionProbes++
    $nextUiProbe=[DateTime]::UtcNow.AddSeconds(40)
    [void](Invoke-ReceiverCompletion)
    Write-JsonFile $resultPath $report
   }
   if($completionAllowed -and (-not $large -or $report.receiverCompletion)) {
   foreach($file in @(Get-ChildItem $destination -File -Recurse | Where-Object { $_.FullName -notin $beforePaths -and $_.Length -eq $ExpectedBytes })) {
    $beforeHash=Get-Item -LiteralPath $file.FullName
    Start-Sleep -Milliseconds 750
    $stable=Get-Item -LiteralPath $file.FullName
    if($stable.Length -ne $ExpectedBytes -or $stable.LastWriteTimeUtc -ne $beforeHash.LastWriteTimeUtc) { continue }
    $cacheKey=$file.FullName+'|'+$stable.Length+'|'+$stable.LastWriteTimeUtc.Ticks
    if(-not $verifiedHashes.ContainsKey($cacheKey)) {
     $report.stage='hashing-saved-file'; Save-Snapshot 'before-saved-file-hash'
     $verifiedHashes[$cacheKey]=Get-BoundedFileHash $file.FullName 'saved-file'
    }
    $hash=$verifiedHashes[$cacheKey]
    if($large -and -not (Test-Path $ExpectedHashFile)) { $report.stage='waiting-for-android-post-completion-hash'; continue }
    if($hash -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Saved Windows bytes disagree with the Android fixture hash.' }
    $afterHash=Get-Item -LiteralPath $file.FullName
    if($afterHash.Length -ne $ExpectedBytes -or $afterHash.LastWriteTimeUtc -ne $stable.LastWriteTimeUtc) { continue }
    if(-not $large -and (Get-BoundedFileHash $file.FullName 'saved-file-confirmation') -ne $hash) { continue }
    $report.destination.capacityAfterSave=Get-DestinationCapacity $file.FullName
    $copy=$null
    if(-not $large) { $copy=Join-Path $OutputDirectory ('saved-'+$file.Name); Copy-Item -LiteralPath $file.FullName -Destination $copy }
    $report.savedFiles+=@{ path=$file.FullName; evidenceCopy=$copy; copyOmittedForLarge=$large; bytes=$afterHash.Length; sha256=$hash; lastWriteUtc=$afterHash.LastWriteTimeUtc.ToString('o');stableSizeBeforeAfterHash=$true }
    Save-Snapshot 'saved-file-verified'; $report.status='saved-file-verified'; $report.stage='complete'
    $report.evidenceLevel='Actual Windows release UI Accept and saved bytes verified; pair with Android sender evidence for app-to-app conclusion.'
    $exitCode=0; break
   }
   }
  }
  if($exitCode -eq 0) { break }
  if([DateTime]::UtcNow -ge $nextSnapshot) {
   $snapshotNumber++
   # Reserve images for the incoming dialog, completed receiver and hash evidence.
   if(-not $large -or $snapshotNumber -le 36) { Save-Snapshot ('waiting-{0:D3}' -f $snapshotNumber) }
   Write-JsonFile $resultPath $report
   $nextSnapshot=[DateTime]::UtcNow.AddSeconds($snapshotInterval)
  }
  Start-Sleep -Milliseconds 500
 } until([DateTime]::UtcNow -ge $deadline)
 if($exitCode -ne 0) { throw "Receiver deadline expired at stage $($report.stage). Inspect both application evidence bundles before classifying." }
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

