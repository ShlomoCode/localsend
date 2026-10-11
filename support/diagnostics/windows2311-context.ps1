param([string]$Case='on', [switch]$CompletePrevious)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
$ui="$PSScriptRoot/windows3393-ui.ps1"
if($CompletePrevious){& $ui -Action click -X 318 -Y 423 -Label "windows-$Case-done"}
$report=Get-Content evidence/release-ui-report.json -Raw|ConvertFrom-Json
$exe=$report.executable.path
$fixture=Join-Path $PWD "evidence/issue2311-$env:GITHUB_RUN_ID-$Case.png"
Copy-Item app/assets/img/logo-128.png $fixture
$old=[DateTime]::Parse('2025-02-13T14:11:00Z').ToUniversalTime()
[IO.File]::SetLastWriteTimeUtc($fixture,$old)
@{path=$fixture;sha256=(Get-FileHash $fixture).Hash;bytes=(Get-Item $fixture).Length;mtimeUtc=[IO.File]::GetLastWriteTimeUtc($fixture).ToString('o')}|ConvertTo-Json|Set-Content "evidence/source-$Case.json"
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
using System;using System.Runtime.InteropServices;
public static class Explorer2311 {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
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
if(!$exactShellSelection -or [Explorer2311]::GetForegroundWindow() -ne $hwnd){throw 'Exact fixture selection or Explorer focus was lost before Shift+F10'}
[Windows.Forms.SendKeys]::SendWait('+{F10}')
Start-Sleep 1
function Snapshot([string]$phase){
 $all=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 @($all|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName}}catch{}})|ConvertTo-Json -Depth 4|Set-Content "evidence/context-$Case-$phase.json"
 $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$image=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$g=[Drawing.Graphics]::FromImage($image)
 try{$g.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$image.Save((Join-Path $PWD "evidence/context-$Case-$phase.png"))}finally{$g.Dispose();$image.Dispose()}
 return $all
}
$all=Snapshot 'opened'
$send=@($all|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::MenuItem -and $_.Current.Name -eq 'Send to'}|Select-Object -Last 1)
if($send.Count -ne 1){throw 'Actual Explorer Send to menu is unavailable'}
try{$send[0].GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()}catch{$send[0].SetFocus();[Windows.Forms.SendKeys]::SendWait('{RIGHT}')}
Start-Sleep 1
$all=Snapshot 'send-to'
$entry=@($all|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::MenuItem -and $_.Current.Name -eq 'LocalSend'}|Select-Object -Last 1)
if($entry.Count -ne 1){throw 'LocalSend was not listed in actual Send to submenu'}
try{$entry[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{$entry[0].SetFocus();[Windows.Forms.SendKeys]::SendWait('{ENTER}')}
Start-Sleep 2
& $ui -Action snapshot -Label "windows-$Case-image-selected"
& $ui -Action click -X 246 -Y 266 -Label "windows-$Case-favorites" -RequireForeground -UseControlSequence
& $ui -Action click -X 145 -Y 225 -Label "windows-$Case-send" -RequireForeground -UseControlSequence
