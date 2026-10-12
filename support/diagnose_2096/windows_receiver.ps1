# Actual unmodified official Windows 1.16.1 app receiver; one supported portable profile per case.
# Input files: {displayRelativePath,bytes,sha256,owned}; expectedNames requires exact relative names.
# The parent owns release provenance/download. No endpoint emulation or binary modification occurs here.
param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$CaseManifest,
 [Parameter(Mandatory=$true)][string]$DeadlineUtc
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$verificationDeadline=[DateTime]::Parse($DeadlineUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
$StopFile=Join-Path $OutputDirectory 'stop'
$readyPath=Join-Path $OutputDirectory 'ready.json'
$resultPath=Join-Path $OutputDirectory 'results.json'
$receiverCompletedFile=Join-Path $OutputDirectory 'receiver-completed.json'
$boundedDiagnostic=$true
$app=$null; $ruleName=$null; $appHwnd=[IntPtr]::Zero; $exitCode=1
$nextOcr=[DateTime]::MinValue; $ocrNumber=0; $ocrUnavailable=$false
$report=[ordered]@{
 status='starting';stage='input-admission';startedUtc=[DateTime]::UtcNow.ToString('o');release='1.16.1'
 endpoint='https://127.0.0.1:53317';processId=$null;caseName=$null;expectedNames=$false
 executable=$null;profile=$null;destination=$null;manifest=$null;receiverCompletion=$null
 environmentMismatch='Windows Server 2022 hosted receiver; historical receiver operating system is unspecified.'
 transportBoundary='Android tunnel and relay to real Windows app; differs from shared LAN.'
 runner=$env:RUNNER_NAME;runnerImage=$env:ImageOS;runnerImageVersion=$env:ImageVersion;os=$null
 acceptCapability=@{status='unverified'};ocrCapability=@{status='not-probed';limitation=$null}
 imageLimit=100;imageCount=0;terminalImageReserve=10;uiObservationLimit=100;uiObservationCount=0;terminalObservationReserve=4
 uiWorkers=@();snapshots=@();actions=@();savedFiles=@();matches=@();verification=$null;errors=@()
}
function Get-RemainingMilliseconds([int]$Maximum) {
 if(Test-Path -LiteralPath $StopFile) { throw 'Parent stopped this receiver.' }
 $remaining=[int][Math]::Max(0,[Math]::Min($Maximum,($verificationDeadline-[DateTime]::UtcNow).TotalMilliseconds))
 if($remaining -le 0) { throw 'Absolute case deadline expired.' }
 return $remaining
}
function Write-JsonFile($Path,$Value) {
 [IO.File]::WriteAllText("$Path.tmp",(ConvertTo-Json -InputObject $Value -Depth 20),[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
trap {
 $report.status='incomplete';$report.errors+=$_.Exception.ToString();$report.finishedUtc=[DateTime]::UtcNow.ToString('o')
 Write-JsonFile $resultPath $report
 exit 1
}
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
  $bound=Get-RemainingMilliseconds 5000
  $workerDeadline=[DateTime]::UtcNow.AddMilliseconds($bound).ToString('o')
  $worker=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-Hwnd',$appHwnd.ToInt64(),'-Result',('"'+$result+'"'),'-DeadlineUtc',('"'+$workerDeadline+'"')) -PassThru -WindowStyle Hidden
  $entry=@{name=$Name;processId=$worker.Id;status='running';timeoutMs=$bound}; $report.uiWorkers+=$entry
  if(-not $worker.WaitForExit((Get-RemainingMilliseconds $bound))) { throw 'UI Automation snapshot exceeded its 5-second/remaining-deadline bound.' }
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
   $tree=Get-BoundedUiSnapshot $Name
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
  try { return [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
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
 $pendingInventory=@(Get-ChildItem -LiteralPath $destination -Recurse -File -Force | Select-Object FullName,Length)
 $pendingObservationUtc=[DateTime]::UtcNow.ToString('o')
 if(-not [ReceiverNative]::ClickScreen($appHwnd,$x,$y)) { throw 'Could not click the fresh OCR Accept bounds.' }
 $report.acceptCapability.status='verified-native-ocr-accept'
 $report.actions+=@{utc=[DateTime]::UtcNow.ToString('o');name='Accept';method='Native Windows OCR unique Accept and Decline, unchanged foreground window pixels';bounds=$button;screenCenter=@{x=$x;y=$y};recognized=$result;screenshot=$framePath;pendingRequestEvidence=(Join-Path $OutputDirectory "$name-incoming.json");beforeAcceptUtc=$pendingObservationUtc;beforeAcceptSavedInventory=$pendingInventory}
 Start-Sleep -Milliseconds 500; Save-Snapshot 'after-accept'; return $true
}
function Get-SavedReceipt {
 $items=@(Get-ChildItem -LiteralPath $destination -Recurse -File -Force)
 $report.actualInventory=@($items | Select-Object FullName,Length,LastWriteTimeUtc)
 if($items.Count -gt 20 -or ($items | Measure-Object -Property Length -Sum).Sum -gt 5242880) { throw 'Saved inventory exceeds 20 files/5 MiB; retain paths/files without hashing beyond admission.' }
 # Preserve all files, including unexpected files; never filter by expected name or content.
 $files=@()
 foreach($file in $items) {
  [void](Get-RemainingMilliseconds 1)
  $relative=$file.FullName.Substring($destination.Length+1).Replace('\','/')
  if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Saved file is a reparse point; no traversal or hashing.' }
  $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try {
   $hash=[Security.Cryptography.SHA256]::Create()
   try { $digest=[BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
   $files+=@{path=$file.FullName;savedRelativePath=$relative;bytes=$stream.Length;sha256=$digest;lastWriteUtc=$file.LastWriteTimeUtc.ToString('o')}
  } finally { $stream.Dispose() }
 }
 return $files
}
function Compare-Receipt($Saved,$Expected,[bool]$ExactNames) {
 $used=@{};$matches=@();$missing=@();$nameDifferences=@()
 foreach($fixture in $Expected) {
  $candidates=@(0..($Saved.Count-1) | Where-Object {
   $Saved.Count -gt 0 -and -not $used.ContainsKey($_) -and $Saved[$_].bytes -eq $fixture.bytes -and $Saved[$_].sha256 -eq $fixture.sha256.ToLowerInvariant()
  })
  # Resolve duplicate-content files by their actual relative names when possible.
  $named=@($candidates | Where-Object { $Saved[$_].savedRelativePath -ceq $fixture.displayRelativePath.Replace('\','/') })
  if($named.Count -gt 0) { $index=$named[0] } elseif($candidates.Count -gt 0) { $index=$candidates[0] } else { $missing+=$fixture;continue }
  $used[$index]=$true
  $match=@{fixtureRelativePath=$fixture.displayRelativePath;owned=$fixture.owned;savedRelativePath=$Saved[$index].savedRelativePath;bytes=$Saved[$index].bytes;sha256=$Saved[$index].sha256;nameEqual=($Saved[$index].savedRelativePath -ceq $fixture.displayRelativePath.Replace('\','/'))}
  $matches+=$match
  if(-not $match.nameEqual) { $nameDifferences+=$match }
 }
 $unexpected=@(0..($Saved.Count-1) | Where-Object { $Saved.Count -gt 0 -and -not $used.ContainsKey($_) } | ForEach-Object { $Saved[$_] })
 return @{passed=($missing.Count -eq 0 -and $unexpected.Count -eq 0 -and (-not $ExactNames -or $nameDifferences.Count -eq 0));matches=$matches;missing=$missing;unexpected=$unexpected;nameDifferences=$nameDifferences;allSavedFilesRetained=$true}
}
try {
 foreach($marker in @($readyPath,$receiverCompletedFile,$resultPath,$StopFile)) {
  if(Test-Path -LiteralPath $marker) { throw "OutputDirectory must be fresh: marker exists: $marker" }
 }
 [void](Get-RemainingMilliseconds 1)
 $manifest=Get-Content -LiteralPath $CaseManifest -Raw | ConvertFrom-Json
 $expected=@($manifest.files)
 if(-not $manifest.caseName -or $expected.Count -lt 1 -or $expected.Count -gt 20) { throw 'Require caseName and 1..20 admitted inventory files.' }
 $total=0L;$paths=@{}
 foreach($file in $expected) {
  if(-not $file.displayRelativePath -or $file.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $file.bytes -lt 0 -or $file.owned -isnot [bool]) { throw 'Every admitted file needs relative display path, nonnegative byte count, SHA-256, and owned boolean.' }
  $relative=$file.displayRelativePath.Replace('\','/')
  if($relative.StartsWith('/') -or $relative -match '(^|/)\.\.(/|$)' -or $relative -match '^[A-Za-z]:' -or $paths.ContainsKey($relative)) { throw 'Manifest relative paths must be unique and relative.' }
  $paths[$relative]=$true;$total+=[long]$file.bytes
 }
 if($total -gt 5242880 -or @($expected | Where-Object owned -EQ $true).Count -lt 1) { throw 'Admitted root must be <=5 MiB and include owned fixtures.' }
 if($manifest.expectedNames -isnot [bool]) { throw 'expectedNames must be a JSON boolean.' }
 $report.caseName=$manifest.caseName;$report.expectedNames=$manifest.expectedNames;$report.manifest=$manifest
 $report.os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 $Executable=[IO.Path]::GetFullPath($Executable)
 $sourceDirectory=[IO.Path]::GetDirectoryName($Executable)
 if($OutputDirectory.StartsWith($sourceDirectory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory cannot be inside the prepared release directory.' }
 if(-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'Prepared official release executable does not exist.' }
 # Copy the full prepared official archive installation byte-for-byte; change only supported portable preferences.
 $caseRelease=Join-Path $OutputDirectory 'release'
 if(Test-Path -LiteralPath $caseRelease) { throw 'Per-case release copy must be fresh.' }
 [void][IO.Directory]::CreateDirectory($caseRelease)
 Get-ChildItem -LiteralPath $sourceDirectory -Force | Copy-Item -Destination $caseRelease -Recurse
 $exe=Get-Item -LiteralPath (Join-Path $caseRelease ([IO.Path]::GetFileName($Executable)))
 $sourceDigest=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
 $copyDigest=(Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 if($copyDigest -ne $sourceDigest) { throw 'Per-case executable copy differs from prepared official release.' }
 $report.executable=@{preparedPath=$Executable;path=$exe.FullName;sha256=$copyDigest;preparedSha256=$sourceDigest;fileVersion=$exe.VersionInfo.FileVersion;bytes=$exe.Length;modified=$false}
 $destination=Join-Path $OutputDirectory 'saved'
 if(Test-Path -LiteralPath $destination) { throw 'Per-case save destination must be absent before preparation.' }
 [void][IO.Directory]::CreateDirectory($destination)
 $profile=Join-Path $caseRelease 'settings.json'
 # The retained official portable ZIP ships settings.json as CRLF (an empty supported template). Retain its bytes and preserve any existing supported values.
 $templateExisted=Test-Path -LiteralPath $profile
 $originalTemplate=Join-Path $OutputDirectory 'official-settings-template.json'
 $beforeValues=@{};$settings=@{};$templateHash=$null
 if($templateExisted) {
  Copy-Item -LiteralPath $profile -Destination $originalTemplate
  $templateHash=(Get-FileHash -LiteralPath $originalTemplate -Algorithm SHA256).Hash.ToLowerInvariant()
  $templateText=[IO.File]::ReadAllText($profile)
  if(-not [string]::IsNullOrWhiteSpace($templateText)) {
   $template=$templateText | ConvertFrom-Json
   if($null -eq $template -or $template -isnot [pscustomobject]) { throw 'Nonempty official portable settings template must be a JSON object.' }
   foreach($entry in $template.PSObject.Properties) { $beforeValues[$entry.Name]=$entry.Value;$settings[$entry.Name]=$entry.Value }
  }
 }
 # v1.16.1 README documents portable mode. SharedPreferencesFile stores prefixed keys as a JSON map.
 $changes=@{'flutter.ls_destination'=$destination;'flutter.ls_locale'='en';'flutter.ls_quick_save'=$false;'flutter.ls_auto_finish'=$false}
 foreach($key in $changes.Keys) { $settings[$key]=$changes[$key] }
 Write-JsonFile $profile $settings
 $report.profile=@{path=$profile;method='Supported documented portable settings';templateExisted=$templateExisted;originalTemplate=$originalTemplate;originalTemplateSha256=$templateHash;beforeValues=$beforeValues;changedPreferences=$changes;initialSettings=$settings;sourceVersion='v1.16.1';source=@('README.md:Portable mode','app/lib/util/shared_preferences/shared_preferences_portable.dart','app/lib/util/shared_preferences/shared_preferences_file.dart','app/lib/provider/persistence_provider.dart')}
 $report.destination=@{path=$destination;initialFileCount=@(Get-ChildItem -LiteralPath $destination -Force).Count;freshPerCase=$true}
 if($report.destination.initialFileCount -ne 0) { throw 'Fresh destination is not empty.' }
 if(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue) { throw 'Official default port 53317 is already owned; never stop an unrelated listener.' }
 if(@(Get-Process -Name localsend_app,LocalSend -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Existing LocalSend process could redirect the launch; require an isolated runner.' }
 $ruleName='LocalSend2096-'+[Guid]::NewGuid().ToString('N')
 New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Inbound -Program $exe.FullName -Action Allow -Profile Any | Out-Null
 $app=Start-Process -FilePath $exe.FullName -WorkingDirectory $caseRelease -PassThru
 $report.processId=$app.Id;$report.stage='readiness'
 $readyDeadline=[DateTime]::UtcNow.AddSeconds(30)
 do {
  [void](Get-RemainingMilliseconds 1)
  Start-Sleep -Milliseconds 250;$app.Refresh()
  if($app.HasExited) { throw "Owned release process exited: $($app.ExitCode)" }
  $windows=@([ReceiverNative]::All() | Where-Object { $_.Pid -eq $app.Id -and $_.Visible -and $_.Width -gt 300 -and $_.Height -gt 200 })
  $listeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -EQ $app.Id)
 } until(($windows.Count -gt 0 -and $listeners.Count -gt 0) -or [DateTime]::UtcNow -ge $readyDeadline)
 if($windows.Count -eq 0 -or $listeners.Count -eq 0) { throw 'Owned release window and 53317 listener did not become ready within 30 seconds.' }
 $appHwnd=[IntPtr]::new($windows[0].Hwnd);[void][ReceiverNative]::Activate($appHwnd)
 Save-Snapshot 'ready'
 $report.status='ready';$report.stage='waiting-for-receive-request'
 Write-JsonFile $resultPath $report
 Write-JsonFile $readyPath @{ready=$true;utc=[DateTime]::UtcNow.ToString('o');caseName=$manifest.caseName;processId=$app.Id;executable=$exe.FullName;destination=$destination;endpoint=$report.endpoint;results=$resultPath}
 $accepted=$false;$transferDeadline=$null
 # Readiness remains live while Android performs its picker actions. The separate transfer bound begins at real Accept.
 while(-not $report.receiverCompletion) {
  [void](Get-RemainingMilliseconds 1)
  $app.Refresh();if($app.HasExited) { throw 'Owned release exited before receiver completion.' }
  if(-not $accepted) {
   $accepted=Invoke-OcrAccept
   if($accepted) {
    $transferDeadline=[DateTime]::Parse($report.actions[-1].utc).ToUniversalTime().AddSeconds(120)
    if($transferDeadline -lt $verificationDeadline) { $verificationDeadline=$transferDeadline }
    $report.transferDeadlineUtc=$verificationDeadline.ToString('o');$report.stage='waiting-for-Finished';Write-JsonFile $resultPath $report
   }
  } else {
   [void](Invoke-OcrAccept -Completion)
   if([DateTime]::UtcNow -ge $transferDeadline -and -not $report.receiverCompletion) { throw 'No actual Finished/Done UI within 120 seconds of Accept.' }
  }
  Start-Sleep -Milliseconds 250
 }
 $firstCompletion=$report.receiverCompletion
 # Reobserve the real completion screen after at least one second, before reading saved bytes.
 if((Get-RemainingMilliseconds 1000) -lt 1000) { throw 'No deadline budget for repeated Finished/Done observation.' }
 Start-Sleep -Milliseconds 1000
 $script:nextOcr=[DateTime]::MinValue
 $completionStillVisible=Invoke-OcrAccept -Completion
 $repeatCompletion=$null
 if($completionStillVisible) { $repeatCompletion=$report.receiverCompletion }
 $report.receiverCompletion=$firstCompletion
 $completionSeparationMs=$null
 if($repeatCompletion) { $completionSeparationMs=([DateTime]::Parse($repeatCompletion.utc)-[DateTime]::Parse($firstCompletion.utc)).TotalMilliseconds }
 $report.stage='hashing-all-saved-files'
 $report.savedFiles=@(Get-SavedReceipt)
 $acceptAction=@($report.actions | Where-Object name -EQ 'Accept')[-1]
 $allPathsInsideDestination=$report.savedFiles.Count -gt 0
 foreach($saved in $report.savedFiles) {
  if(-not [IO.Path]::GetFullPath($saved.path).StartsWith($destination+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { $allPathsInsideDestination=$false }
 }
 $report.profile.observedBehavior=@{
  classification='Observed real-app behavior; no direct Settings UI readback'
  english=@{corroborated=$true;observedLabels=@('Accept','Decline','Finished','Done');pendingRequest=@{recognized=$acceptAction.recognized;screenshot=$acceptAction.screenshot};completion=$firstCompletion;limit='Exact English labels corroborate these screens; the locale preference was not read from Settings UI.'}
  quickSaveOff=@{manualApprovalObserved=$true;pendingRequestEvidence=$acceptAction.pendingRequestEvidence;acceptAction=$acceptAction;destinationEmptyImmediatelyBeforeAccept=($acceptAction.beforeAcceptSavedInventory.Count -eq 0);limit='Pending request and actual Accept corroborate manual approval for this transfer; the Quick Save toggle was not read from Settings UI.'}
  autoFinishOff=@{completionRemainedVisible=$completionStillVisible;firstObservation=$firstCompletion;repeatedObservation=$repeatCompletion;minimumSeparationMs=1000;observedSeparationMs=$completionSeparationMs;limit='Repeated Finished/Done corroborates that this completion screen persisted; the Auto Finish toggle was not read from Settings UI. A missing repeated observation leaves this behavior unverified.'}
  destination=@{allSavedPathsInsideConfiguredDestination=$allPathsInsideDestination;configuredPath=$destination;observedSavedFiles=$report.savedFiles;limit='Actual saved paths verify the destination used by this transfer; the destination field was not read from Settings UI.'}
 }
 $report.verification=Compare-Receipt $report.savedFiles $expected $manifest.expectedNames
 $report.matches=$report.verification.matches
 # Read the app's actual post-transfer portable file without changing it. Retain only the four relevant values.
 $runtimeBytes=[IO.File]::ReadAllBytes($profile)
 $runtimeHash=[Security.Cryptography.SHA256]::Create()
 try { $runtimeDigest=[BitConverter]::ToString($runtimeHash.ComputeHash($runtimeBytes)).Replace('-','').ToLowerInvariant() } finally { $runtimeHash.Dispose() }
 $runtimeText=[Text.Encoding]::UTF8.GetString($runtimeBytes).TrimStart([char]0xFEFF)
 $runtimePreferences=$runtimeText | ConvertFrom-Json
 if($null -eq $runtimePreferences -or $runtimePreferences -isnot [pscustomobject]) { throw 'Post-transfer portable preferences are not a JSON object.' }
 $runtimeValues=@{}
 foreach($key in $changes.Keys) {
  $entry=$runtimePreferences.PSObject.Properties[$key]
  $runtimeValues[$key]=if($null -ne $entry) { $entry.Value } else { $null }
 }
 $runtimeReadback=@{
  utc=[DateTime]::UtcNow.ToString('o');actualSettingsPath=$profile;actualSettingsSha256=$runtimeDigest
  actualSettingsBytes=$runtimeBytes.Length;values=$runtimeValues;expectedValues=$changes
  directSupportedFileReadback=$true;settingsUiReadback=$false;fileRewritten=$false
  retainedValues='Only the four requested preferences; other runtime settings are omitted from this receipt.'
  passed=($runtimeValues['flutter.ls_destination'] -ceq $destination -and $runtimeValues['flutter.ls_locale'] -ceq 'en' -and $runtimeValues['flutter.ls_quick_save'] -is [bool] -and $runtimeValues['flutter.ls_quick_save'] -eq $false -and $runtimeValues['flutter.ls_auto_finish'] -is [bool] -and $runtimeValues['flutter.ls_auto_finish'] -eq $false)
 }
 $runtimeReceipt=Join-Path $OutputDirectory 'runtime-preferences-receipt.json'
 Write-JsonFile $runtimeReceipt $runtimeReadback
 $report.profile.runtimeReadback=@{receipt=$runtimeReceipt;observation=$runtimeReadback;distinction='beforeValues are the official template; runtimeReadback reads the actual app-written portable file after saved-byte hashing.'}
 if(-not $runtimeReadback.passed) { throw 'Post-transfer supported preferences differ from the four configured values; inspect the sanitized runtime receipt.' }
 $report.status='receiver-completed';$report.stage='complete'
 if($report.verification.passed) { $report.status='saved-files-verified';$exitCode=0 } else { $report.status='verification-failed' }
 if($report.verification.passed) { Save-Snapshot 'saved-file-verified' } else { Save-Snapshot 'failure' }
 Write-JsonFile $receiverCompletedFile @{completed=$true;verified=$report.verification.passed;utc=$report.receiverCompletion.utc;caseName=$manifest.caseName;observation=$report.receiverCompletion;observedConfigurationBehavior=$report.profile.observedBehavior;savedFiles=$report.savedFiles;verification=$report.verification;results=$resultPath}
} catch {
 $report.status='incomplete';$report.errors+=$_.Exception.ToString()
 try { Save-Snapshot 'failure' } catch { $report.errors+=$_.Exception.Message }
 # Retain partial save evidence when available. Failure remains failure even if some files match.
 if($destination -and (Test-Path -LiteralPath $destination)) { try { $report.savedFiles=@(Get-SavedReceipt) } catch { $report.errors+="Partial file receipt: $($_.Exception.Message)" } }
} finally {
 if($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
 if($ruleName) { Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }
 $report.finishedUtc=[DateTime]::UtcNow.ToString('o');Write-JsonFile $resultPath $report
 # Keep ready.json as historical evidence; consumers must also check results and receiver-completed.
}
exit $exitCode
