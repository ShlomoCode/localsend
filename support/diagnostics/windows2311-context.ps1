param([string]$Case='on', [switch]$CompletePrevious, [string]$FixtureSource='', [string]$FixtureExtension='png', [string]$FixtureModifiedUtc='2025-02-13T14:11:00Z', [switch]$QualifyFavoritesPointerOnly)
$ErrorActionPreference='Stop'
if($env:ISSUE2311_SENDER_FAVORITES_QUALIFICATION -eq 'true' -and !$QualifyFavoritesPointerOnly){throw 'The sender qualification job cannot enter the recipient workflow'}
if($QualifyFavoritesPointerOnly -and ($env:ISSUE2311_SENDER_FAVORITES_QUALIFICATION -ne 'true' -or $env:OS -ne 'Windows_NT' -or
 $env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -ne 'ShlomoCode/localsend' -or $CompletePrevious -or $FixtureExtension -ne 'jpg')){
 throw 'Sender pointer qualification requires its isolated job and JPEG fixture; no recipient input is permitted'
}
$physicalRemainingFavorites=$env:ISSUE2311_PHYSICAL_REMAINING_FAVORITES -eq 'true'
if($physicalRemainingFavorites -and ($QualifyFavoritesPointerOnly -or $env:ISSUE2311_SENDER_FAVORITES_QUALIFICATION -eq 'true' -or
 $env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -ne 'ShlomoCode/localsend' -or
 $env:DIAGNOSTIC_RUNNER_LABEL -ne 'windows-2022' -or $env:VALIDATION_SUITE -ne 'remaining-media' -or
 $Case -notin @('jpeg-off','video-on','video-off') -or
 ($Case -eq 'jpeg-off' -and $FixtureExtension -ne 'jpg') -or ($Case -ne 'jpeg-off' -and $FixtureExtension -ne 'mp4'))){
 throw 'Physical native Favorites delivery is restricted to the three remaining media cases on the authorized Windows 2022 job'
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
$ui="$PSScriptRoot/windows3393-ui.ps1"
$control=Get-Content evidence/windows-control-send-action.json -Raw|ConvertFrom-Json
$senderPid=[uint32]$control.appPid;$senderHwnd=[long]$control.window
if(!$senderPid -or !$senderHwnd){throw 'Known-working control sender identity is missing'}
function SaveSenderBoundary([string]$phase){
 $processes=@(Get-CimInstance Win32_Process -Filter "Name = 'localsend_app.exe'"|Select-Object ProcessId,ParentProcessId,ExecutablePath,CreationDate)
 $listeners=@(Get-NetTCPConnection -LocalPort 53317 -State Listen -ErrorAction SilentlyContinue|Select-Object LocalAddress,LocalPort,OwningProcess)
 $windows=@(Get-Process localsend_app -ErrorAction SilentlyContinue|Select-Object Id,MainWindowHandle,MainWindowTitle,StartTime)
 @{utc=[DateTime]::UtcNow.ToString('o');phase=$phase;expectedPid=$senderPid;expectedHwnd=$senderHwnd;processes=$processes;windows=$windows;listeners=$listeners}|ConvertTo-Json -Depth 6|Set-Content "evidence/context-$Case-$phase-sender-boundary.json"
 foreach($app in $windows){if($app.MainWindowHandle){& $ui -Action snapshot -ExpectedPid $app.Id -ExpectedHwnd $app.MainWindowHandle -Label "windows-$Case-$phase-pid-$($app.Id)"}}
 if($phase -eq 'before-context'){$script:beforeSenderPids=@($processes.ProcessId)}
 elseif(@($processes|Where-Object {$_.ProcessId -notin $script:beforeSenderPids}).Count){throw 'Native SendTo left a new LocalSend process; sender handoff is unproven, no recipient input sent'}
 if(!$listeners.Count -or @($listeners|Where-Object {$_.OwningProcess -ne $senderPid}).Count){throw 'Port 53317 is not exclusively owned by the known-working sender; no recipient input sent'}
 & $ui -Action snapshot -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -Label "windows-$Case-$phase-original"
}
function SaveSemanticObservation([string]$phase){
 $semanticPath=Join-Path $PWD "evidence/context-$Case-$phase-semantics.json"
 $escapedPath=$semanticPath.Replace("'","''")
 $probe=@'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
try {
 $root=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]__SENDER_HWND__)
 $elements=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 $rows=@($elements|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled;offscreen=$_.Current.IsOffscreen}}catch{}})
 @{available=($rows.Count -gt 0);readinessClaim=$false;elements=$rows}|ConvertTo-Json -Depth 5|Set-Content '__SEMANTIC_PATH__'
}catch{@{available=$false;readinessClaim=$false;error=$_.Exception.Message}|ConvertTo-Json|Set-Content '__SEMANTIC_PATH__'}
'@
 $probe=$probe.Replace('__SENDER_HWND__',[string]$senderHwnd).Replace('__SEMANTIC_PATH__',$escapedPath)
 # Probe in a bounded separate CLR process: historical Flutter exposed only a pane.
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
 $child=Start-Process pwsh -ArgumentList '-NoProfile','-EncodedCommand',$encoded -PassThru -RedirectStandardOutput "evidence/context-$Case-$phase-semantics.stdout.txt" -RedirectStandardError "evidence/context-$Case-$phase-semantics.stderr.txt"
 if(!$child.WaitForExit(5000)){
  # Only stop our diagnostic probe, never any LocalSend process.
  $child.Kill();[void]$child.WaitForExit(1000)
  @{available=$false;readinessClaim=$false;reason='Bounded UIAutomation probe unavailable'}|ConvertTo-Json|Set-Content $semanticPath
 }
 if(!(Test-Path $semanticPath)){@{available=$false;readinessClaim=$false;reason='UIAutomation probe produced no result'}|ConvertTo-Json|Set-Content $semanticPath}
 $observed=Get-Content $semanticPath -Raw|ConvertFrom-Json
 if(@($observed.elements|Where-Object {$_.name -match 'SocketException|Failed to create server socket|errno = 10048'}).Count){throw 'Sender SocketException observed; no recipient input sent'}
}
SaveSenderBoundary 'before-context'
if($CompletePrevious){& $ui -Action click -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -X 318 -Y 423 -Label "windows-$Case-done"}
$report=Get-Content evidence/release-ui-report.json -Raw|ConvertFrom-Json
$exe=$report.executable.path
if($FixtureExtension -notin @('png','jpg','mp4')){throw 'Unsupported diagnostic fixture extension'}
$fixture=Join-Path $PWD "evidence/issue2311-$env:GITHUB_RUN_ID-$Case.$FixtureExtension"
if(!$FixtureSource){$FixtureSource='app/assets/img/logo-128.png'}
Copy-Item $FixtureSource $fixture
$requested=[DateTimeOffset]::Parse($FixtureModifiedUtc).ToUniversalTime()
$old=$requested.UtcDateTime
[IO.File]::SetLastWriteTimeUtc($fixture,$old)
$actual=[DateTimeOffset]::new([IO.File]::GetLastWriteTimeUtc($fixture))
@{path=$fixture;sha256=(Get-FileHash $fixture).Hash;bytes=(Get-Item $fixture).Length;mtimeUtc=$actual.UtcDateTime.ToString('o');mtimeMs=$actual.ToUnixTimeMilliseconds();requestedMtimeUtc=$requested.UtcDateTime.ToString('o');requestedMtimeMs=$requested.ToUnixTimeMilliseconds();systemTimezone=[TimeZoneInfo]::Local.Id}|ConvertTo-Json|Set-Content "evidence/source-$Case.json"
if($actual.UtcDateTime.Ticks -ne $requested.UtcDateTime.Ticks){throw 'Windows fixture did not retain the requested timestamp exactly; source report preserved'}
# Prepare the supported SendTo shortcut exactly as LocalSend's context-menu helper does.
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path $env:APPDATA 'Microsoft/Windows/SendTo/LocalSend.lnk'))
$shortcut.TargetPath=$exe;$shortcut.Save()
Start-Process explorer.exe -ArgumentList ('/select,"'+$fixture+'"')
Start-Sleep 3
$shellApp=New-Object -ComObject Shell.Application
$parentPath=[IO.Path]::GetDirectoryName($fixture)
$window=@($shellApp.Windows()|Where-Object {try{[IO.Path]::GetFullPath(([Uri]$_.LocationURL).LocalPath).TrimEnd('\') -eq $parentPath.TrimEnd('\')}catch{$false}}|Select-Object -Last 1)
if($window.Count -ne 1){throw 'Explorer fixture window was not found'}
$shell.AppActivate([int](Get-Process explorer|Select-Object -Last 1).Id)|Out-Null
$root=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window[0].HWND)
Add-Type @'
using System;using System.Runtime.InteropServices;using System.Text;using System.Collections.Generic;
public class MenuEntry2311 { public long Window,Menu;public uint Process;public int Index,Left,Top,Right,Bottom;public string Text; }
public static class Explorer2311 {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f,IntPtr p);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu,uint index,StringBuilder b,int n,uint flags);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr h,IntPtr menu,uint index,out Rect r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 public static MenuEntry2311[] Menus(){
  var result=new List<MenuEntry2311>();
  EnumWindows((h,p)=>{
   var name=new StringBuilder(256);GetClassName(h,name,256);
   if(!IsWindowVisible(h)||name.ToString()!="#32768")return true;
   var menu=SendMessage(h,0x1E1,IntPtr.Zero,IntPtr.Zero); // MN_GETHMENU: inspect the displayed native popup.
   uint pid;GetWindowThreadProcessId(h,out pid);
   for(uint i=0;i<GetMenuItemCount(menu);i++){
    var text=new StringBuilder(1024);GetMenuString(menu,i,text,1024,0x400);Rect rect;
    if(!GetMenuItemRect(IntPtr.Zero,menu,i,out rect))GetMenuItemRect(h,menu,i,out rect);
    result.Add(new MenuEntry2311{Window=h.ToInt64(),Menu=menu.ToInt64(),Process=pid,Index=(int)i,Text=text.ToString().Replace("&","").Split('\t')[0].Trim(),Left=rect.Left,Top=rect.Top,Right=rect.Right,Bottom=rect.Bottom});
   }
   return true;
  },IntPtr.Zero);
  return result.ToArray();
 }
}
'@
$hwnd=[IntPtr]$window[0].HWND
$current=[Explorer2311]::GetCurrentThreadId();$unused=0u
$threads=@([Explorer2311]::GetWindowThreadProcessId([Explorer2311]::GetForegroundWindow(),[ref]$unused),[Explorer2311]::GetWindowThreadProcessId($hwnd,[ref]$unused))|Select-Object -Unique
$attached=@()
foreach($thread in $threads){if($thread -and $thread -ne $current -and [Explorer2311]::AttachThreadInput($current,$thread,$true)){$attached+=$thread}}
try{[void][Explorer2311]::ShowWindow($hwnd,9);[void][Explorer2311]::SetForegroundWindow($hwnd)}finally{foreach($thread in $attached){[void][Explorer2311]::AttachThreadInput($current,$thread,$false)}}
if([Explorer2311]::GetForegroundWindow() -ne $hwnd){throw 'Explorer foreground could not be established; no context-menu keys were sent'}
$filename=[IO.Path]::GetFileNameWithoutExtension($fixture)
$shellItem=$window[0].Document.Folder.ParseName([IO.Path]::GetFileName($fixture))
if(!$shellItem -or $shellItem.Path -ne $fixture){throw 'Explorer folder did not resolve the exact fixture'}
# Native Explorer selection also scrolls virtualized rows into view.
# SVSI_SELECT | SVSI_DESELECTOTHERS | SVSI_ENSUREVISIBLE | SVSI_FOCUSED.
$window[0].Document.SelectItem($shellItem,29)
$deadline=[DateTime]::UtcNow.AddSeconds(10)
do{
 $items=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 $item=@($items|Where-Object {$_.Current.ControlType.ProgrammaticName -in @('ControlType.ListItem','ControlType.DataItem') -and ($_.Current.Name -eq $filename -or $_.Current.Name -eq [IO.Path]::GetFileName($fixture))}|Select-Object -Last 1)
 $shellSelection=@($window[0].Document.SelectedItems()|ForEach-Object {$_.Path})
 if($item.Count -or ($shellSelection.Count -eq 1 -and $shellSelection[0] -eq $fixture)){break}
 Start-Sleep -Milliseconds 250
}while([DateTime]::UtcNow -lt $deadline)
@($items|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName}}catch{}})|ConvertTo-Json -Depth 4|Set-Content "evidence/context-$Case-explorer-items.json"
$selected=$false
if($item.Count){
 $item[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 $item[0].SetFocus()
 $selected=$item[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
}
$shellSelection=@($window[0].Document.SelectedItems()|ForEach-Object {$_.Path})
$exactShellSelection=$shellSelection.Count -eq 1 -and $shellSelection[0] -eq $fixture
$focused=[Windows.Automation.AutomationElement]::FocusedElement
@{hwnd=$hwnd.ToInt64();foreground=[Explorer2311]::GetForegroundWindow().ToInt64();fixture=$fixture;folder=$window[0].LocationURL;selected=$selected;shellSelectedPaths=$shellSelection;exactShellSelection=$exactShellSelection;focused=$focused.Current.Name;focusedType=$focused.Current.ControlType.ProgrammaticName}|ConvertTo-Json|Set-Content "evidence/context-$Case-selection.json"
if(!$exactShellSelection -or [Explorer2311]::GetForegroundWindow() -ne $hwnd){throw 'Exact fixture selection or Explorer focus was lost before context request'}
[Explorer2311]::keybd_event(0x5D,0,0,[UIntPtr]::Zero)
[Explorer2311]::keybd_event(0x5D,0,2,[UIntPtr]::Zero)
@{method='Native Windows Context Menu key';virtualKey='VK_APPS 0x5D';fixture=$fixture}|ConvertTo-Json|Set-Content "evidence/context-$Case-request.json"
Start-Sleep 1
function Snapshot([string]$phase){
 $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$image=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$g=[Drawing.Graphics]::FromImage($image)
 try{$g.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$image.Save((Join-Path $PWD "evidence/context-$Case-$phase.png"))}finally{$g.Dispose();$image.Dispose()}
 $all=[Explorer2311]::Menus()
 ConvertTo-Json -InputObject @($all) -Depth 4|Set-Content "evidence/context-$Case-$phase.json"
 return $all
}
function WaitMenuItem([string]$name,[string]$phase){
 $deadline=[DateTime]::UtcNow.AddSeconds(10);$observations=@()
 do{
  $all=[Explorer2311]::Menus()
  $owner=0u;[void][Explorer2311]::GetWindowThreadProcessId($hwnd,[ref]$owner)
  $matches=@($all|Where-Object {$_.Text -eq $name -and $_.Process -eq $owner -and $_.Right -gt $_.Left -and $_.Bottom -gt $_.Top}|Select-Object -Last 1)
  $observations+=@{utc=[DateTime]::UtcNow.ToString('o');count=$matches.Count;nativeMenuItems=@($all)}
  if($matches.Count){break}
  Start-Sleep -Milliseconds 250
 }while([DateTime]::UtcNow -lt $deadline)
 ConvertTo-Json -InputObject $observations -Depth 4|Set-Content "evidence/context-$Case-$phase-readiness.json"
 $null=Snapshot $phase
 return $matches
}
$send=WaitMenuItem 'Send to' 'opened'
if($send.Count -ne 1){throw 'Actual Explorer Send to menu is unavailable'}
function ClickNativeMenu($entry,[string]$label){
 $x=[int](($entry.Left+$entry.Right)/2);$y=[int](($entry.Top+$entry.Bottom)/2)
 @{method='Native pointer click on displayed Explorer popup item';entry=$entry;x=$x;y=$y}|ConvertTo-Json -Depth 5|Set-Content "evidence/context-$Case-$label-action.json"
 if(![Explorer2311]::SetCursorPos($x,$y)){throw 'Native menu pointer positioning failed'}
 [Explorer2311]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Explorer2311]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
ClickNativeMenu $send[0] 'send-to'
Start-Sleep 1
$entry=WaitMenuItem 'LocalSend' 'send-to'
if($entry.Count -ne 1){throw 'LocalSend was not listed in actual Send to submenu'}
ClickNativeMenu $entry[0] 'localsend'
Start-Sleep 2
SaveSenderBoundary 'after-send-to'
& $ui -Action snapshot -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -Label "windows-$Case-image-selected"
SaveSemanticObservation 'before-favorites'
SaveSenderBoundary 'before-favorites'
& $ui -Action click -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -X 246 -Y 266 -Label "windows-$Case-favorites" -RequireForeground -UseNativePointer:($QualifyFavoritesPointerOnly -or $physicalRemainingFavorites)
SaveSemanticObservation 'before-send'
SaveSenderBoundary 'before-send'
# A queued mouse gesture and an opaque accessibility pane do not establish the
# Favorites dialog. Require both fresh owned-window captures to match the pinned
# positive dialog interior before the single recipient input.
& "$PSScriptRoot/issue2311-favorites-gate.ps1" -Mode Validate `
 -CapturePaths @("evidence/windows-$Case-favorites.png","evidence/windows-$Case-before-send-original.png") `
 -ActionPaths @("evidence/windows-$Case-favorites-action.json","evidence/windows-$Case-before-send-original-action.json") `
 -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -OutputPath "evidence/$Case-favorites-gate.json"
if($QualifyFavoritesPointerOnly){
 SaveSenderBoundary 'after-favorites-qualification'
 @{scope='Sender Favorites dialog only; no working transfer claim';pid=$senderPid;hwnd=$senderHwnd;recipientInputSent=$false;receiverAllocated=$false;passed=$true}|ConvertTo-Json|Set-Content "evidence/$Case-sender-qualification.json"
 return
}
& $ui -Action click -ExpectedPid $senderPid -ExpectedHwnd $senderHwnd -X 145 -Y 225 -Label "windows-$Case-send" -RequireForeground -UseControlSequence
SaveSenderBoundary 'after-recipient'
