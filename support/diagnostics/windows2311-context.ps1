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
$window=@($shellApp.Windows()|Where-Object {$_.LocationURL -like '*evidence*'}|Select-Object -Last 1)
if($window.Count -ne 1){throw 'Explorer fixture window was not found'}
$shell.AppActivate([int](Get-Process explorer|Select-Object -Last 1).Id)|Out-Null
$root=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window[0].HWND)
$filename=[IO.Path]::GetFileNameWithoutExtension($fixture)
$items=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
$item=@($items|Where-Object {$_.Current.Name -eq $filename -or $_.Current.Name -eq [IO.Path]::GetFileName($fixture)}|Select-Object -Last 1)
if($item.Count -ne 1){throw 'Explorer did not expose the fixture selection'}
$item[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
$item[0].SetFocus()
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
$send=@($all|Where-Object {$_.Current.Name -eq 'Send to'}|Select-Object -Last 1)
if($send.Count -ne 1){throw 'Actual Explorer Send to menu is unavailable'}
try{$send[0].GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()}catch{$send[0].SetFocus();[Windows.Forms.SendKeys]::SendWait('{RIGHT}')}
Start-Sleep 1
$all=Snapshot 'send-to'
$entry=@($all|Where-Object {$_.Current.Name -eq 'LocalSend'}|Select-Object -Last 1)
if($entry.Count -ne 1){throw 'LocalSend was not listed in actual Send to submenu'}
try{$entry[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}catch{$entry[0].SetFocus();[Windows.Forms.SendKeys]::SendWait('{ENTER}')}
Start-Sleep 2
& $ui -Action snapshot -Label "windows-$Case-image-selected"
& $ui -Action click -X 246 -Y 266 -Label "windows-$Case-favorites" -RequireForeground -UseControlSequence
& $ui -Action click -X 145 -Y 225 -Label "windows-$Case-send" -RequireForeground -UseControlSequence
