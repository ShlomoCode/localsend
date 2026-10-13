param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline,[string]$PrelaunchPhase,[string]$PhaseContext,[string]$PhaseTag)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot prelaunch.ps1)
if($PrelaunchPhase){Run-PrelaunchPhase}
$script:Triggered=$false;$script:Recorder=$null
Start-Transcript (Join-Path $Evidence scenario-original.txt)
function Alive($App){$null=Assert-App $App;return Get-Process -Id $App.Id}
function Wait-Visible($App){$end=[DateTime]::UtcNow.AddSeconds(12);do{Check-Budget;$null=Alive $App;if([Tray3166Native]::Visible([IntPtr]$App.Hwnd) -and [Issue3456Native]::GetForegroundWindow().ToInt64() -eq $App.Hwnd){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end);throw 'ENV_BLOCK: actual tray activation did not show/foreground same app'}
function Desktop-Snapshot($Name){Check-Budget;$roots=@([Controls3536]::Roots());Json $roots "$Name-roots";foreach($r in $roots|Where-Object {$_.ClassName -in @('Shell_TrayWnd','NotifyIconOverflowWindow','#32768','TaskManagerWindow')}){Json @([Controls3536]::Snapshot($r.Handle,$r.Pid)) "$Name-root-$($r.Pid)-$($r.Handle)"};Save-Desktop $Name;return $roots}
function Shell {
 $roots=@([Controls3536]::Roots()|Where-Object ClassName -eq Shell_TrayWnd)
 if($roots.Count -ne 1){throw 'ENV_BLOCK: unique actual shell taskbar absent'}
 $r=$roots[0];$p=Get-Process -Id $r.Pid -ErrorAction Stop
 if($p.ProcessName -ne 'explorer'){throw 'ENV_BLOCK: Shell_TrayWnd not owned by Explorer'}
 return [pscustomobject]@{Id=$p.Id;Path=$p.Path;StartUtc=$p.StartTime.ToUniversalTime().ToString('o');Hwnd=$r.Handle;Root=$r}
}
function Shell-Click($Control,[switch]$Right){
 Check-Budget;$root=@([Controls3536]::Roots()|Where-Object {$_.Pid -eq $Control.Pid -and $_.ClassName -in @('Shell_TrayWnd','NotifyIconOverflowWindow','#32768')})
 $matches=@();foreach($r in $root){$matches+=@([Controls3536]::Snapshot($r.Handle,$r.Pid)|Where-Object {$_.Name -eq $Control.Name -and $_.Type -eq $Control.Type -and $_.Left -eq $Control.Left -and $_.Top -eq $Control.Top -and $_.Right -eq $Control.Right -and $_.Bottom -eq $Control.Bottom})}
 if($matches.Count -ne 1 -or -not $Control.Enabled){throw 'ENV_BLOCK: shell input live binding absent/ambiguous'}
 $x=[int](($Control.Left+$Control.Right)/2);$y=[int](($Control.Top+$Control.Bottom)/2)
 if(-not [Issue3456Native]::SetCursorPos($x,$y)){throw 'ENV_BLOCK: shell cursor failed'}
 Write-Event shellMouse @{Target=$Control;X=$x;Y=$y;Right=[bool]$Right}
 if($Right){[Issue3456Native]::mouse_event(8,0,0,0,[UIntPtr]::Zero);[Issue3456Native]::mouse_event(16,0,0,0,[UIntPtr]::Zero)}else{[Issue3456Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[Issue3456Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 300
}
function Tray-Control($Name){
 $found=@();foreach($r in @([Controls3536]::Roots()|Where-Object ClassName -in @('Shell_TrayWnd','NotifyIconOverflowWindow'))){$found+=@([Controls3536]::Snapshot($r.Handle,$r.Pid)|Where-Object {$_.Name -eq $Name -and $_.Enabled -and $_.Type -eq 50000})}
 if($found.Count -gt 1){throw "ENV_BLOCK: ambiguous tray control $Name"};if($found.Count -eq 1){return $found[0]};return $null
}
function Qualify-RenewedTray($ExpectedShell){
 $actual=Shell;if($actual.Id -ne $ExpectedShell.Id -or $actual.StartUtc -ne $ExpectedShell.StartUtc){throw 'ENV_BLOCK: renewed shell changed during tray qualification'}
 $nodes=@([Controls3536]::Snapshot($actual.Hwnd,$actual.Id));$regions=@($nodes|Where-Object {$_.ClassName -eq 'TrayNotifyWnd' -or $_.Name -in @('System Promoted Notification Area','User Promoted Notification Area','Notification area')})
 Json @{Shell=$actual;VisibleNotificationRegions=$regions;Nodes=$nodes} renewed-tray-readiness;Save-Desktop renewed-tray-readiness
 if($regions.Count -eq 0){throw 'ENV_BLOCK: renewed notification-area provider readiness unavailable; absent icon cannot be attributed'}
}
function Find-Tray([int]$Seconds=12){
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$opened=$false
 do{Check-Budget;$icon=Tray-Control 'LocalSend';if($icon){return $icon};if(-not $opened){$chevron=Tray-Control 'Show hidden icons';if(-not $chevron){$chevron=Tray-Control 'Notification Chevron'};if($chevron){Shell-Click $chevron;$opened=$true}};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 return $null
}
function Find-SettingsNavigation($App){
 $tree=@(Snapshot $App);$views=@($tree|Where-Object {$_.ClassName -eq 'FLUTTERVIEW' -and $_.Pid -eq $App.Id -and $_.Enabled})
 if($views.Count -ne 1){throw 'ENV_BLOCK: unique owned Flutter client unavailable for navigation'}
 $view=$views[0];$zoomed=[Tray3166Native]::Zoomed([IntPtr]$App.Hwnd);$expectedType=if($zoomed){50020}else{50000};$items=@()
 foreach($name in @("Receive`nTab 1 of 3","Send`nTab 2 of 3","Settings`nTab 3 of 3")){
  $matches=@($tree|Where-Object {$_.Name -ceq $name -and $_.Type -eq $expectedType -and $_.Enabled -and $_.Pid -eq $App.Id})
  if($matches.Count -ne 1){throw 'ENV_BLOCK: complete unique state-specific navigation unavailable'}
  $c=$matches[0]
  if($c.Right -le $c.Left -or $c.Bottom -le $c.Top -or $c.Left -lt $view.Left -or $c.Right -gt $view.Right -or $c.Top -lt $view.Top -or $c.Bottom -gt $view.Bottom){throw 'ENV_BLOCK: navigation bounds outside live client'}
  $items+=$c
 }
 if($zoomed){
  if($items[0].Left -ne $view.Left -or $items[0].Left -ne $items[1].Left -or $items[1].Left -ne $items[2].Left -or $items[0].Right -ne $items[1].Right -or $items[1].Right -ne $items[2].Right -or $items[2].Right -ge $view.Right -or $items[0].Bottom -gt $items[1].Top -or $items[1].Bottom -gt $items[2].Top){throw 'ENV_BLOCK: maximized Text rail alignment/order unavailable'}
 }else{
  if($items[0].Top -ne $items[1].Top -or $items[1].Top -ne $items[2].Top -or $items[0].Bottom -ne $view.Bottom -or $items[1].Bottom -ne $view.Bottom -or $items[2].Bottom -ne $view.Bottom -or $items[0].Right -gt $items[1].Left -or $items[1].Right -gt $items[2].Left){throw 'ENV_BLOCK: normal Button navigation alignment/order unavailable'}
 }
 if([Tray3166Native]::Zoomed([IntPtr]$App.Hwnd) -ne $zoomed){throw 'ENV_BLOCK: native window state changed during navigation binding'}
 Json @{View=$view;Zoomed=$zoomed;ExpectedType=$expectedType;AllThree=$items;Tree=$tree} "$script:Stage-navigation-binding"
 Save-Desktop "$script:Stage-navigation-bound"
 return $items[2]
}
function Bind-GeneralBooleanRows($App,$CompositeName,$LanguageName,$BooleanLabels){
 $tree=@(Snapshot $App);$groups=@($tree|Where-Object {$_.Name -eq $CompositeName -and $_.Type -eq 50026});$navigation=@(Find-SettingsNavigation $App);$views=@($tree|Where-Object ClassName -eq FLUTTERVIEW)
 if($groups.Count -ne 1 -or $navigation.Count -ne 1 -or $views.Count -ne 1){throw 'ENV_BLOCK: unique source-contracted General composite/navigation unavailable'}
 $group=$groups[0];$inside={param($c) $c.Left -ge $group.Left -and $c.Right -le $group.Right -and $c.Top -ge $group.Top -and $c.Bottom -le $group.Bottom}
 $view=$views[0];$nav=$navigation[0]
 if($group.Left -lt $view.Left -or $group.Right -gt $view.Right -or $group.Top -lt $view.Top -or $group.Bottom -gt $view.Bottom){throw 'ENV_BLOCK: General rows outside visible native client bounds'}
 if(-not ($group.Bottom -le $nav.Top -or $group.Left -ge $nav.Right)){throw 'ENV_BLOCK: General rows overlap actual bottom/rail navigation'}
 $visibleBottom=if($group.Left -ge $nav.Right){$view.Bottom}else{$nav.Top}
 $language=@($tree|Where-Object {$_.Name -eq $LanguageName -and $_.Type -eq 50000 -and (& $inside $_)})
 $checks=@($tree|Where-Object {$_.Type -eq 50002 -and (& $inside $_)}|Sort-Object Top)
 if($language.Count -ne 1 -or $checks.Count -ne $BooleanLabels.Count){throw 'ENV_BLOCK: complete source-contracted General row controls unavailable'}
 $rows=@();$previous=$language[0]
 for($i=0;$i -lt $checks.Count;$i++){
  $c=$checks[$i]
  if(-not $c.Enabled -or $c.Pid -ne $App.Id -or $c.Toggle -notin @(0,1) -or $c.Top -le $previous.Bottom){throw 'ENV_BLOCK: General row order/toggle/ownership ambiguous'}
  if($i -gt 0 -and ($c.Left -ne $checks[0].Left -or $c.Right -ne $checks[0].Right)){throw 'ENV_BLOCK: source Boolean column alignment differs'}
  $top=[int][Math]::Floor(($previous.Bottom+$c.Top)/2)
  $bottom=if($i+1 -lt $checks.Count){[int][Math]::Floor(($c.Bottom+$checks[$i+1].Top)/2)}else{$group.Bottom}
  if($top -lt $group.Top -or $bottom -gt $group.Bottom -or $bottom -gt $visibleBottom -or $c.Top -lt $top -or $c.Bottom -gt $bottom){throw 'ENV_BLOCK: full rendered Boolean row not inside visible General bounds'}
  $rows+=[pscustomobject]@{Label=$BooleanLabels[$i];SourceOrdinal=$i;Control=$c;Row=[pscustomobject]@{Left=$group.Left;Top=$top;Right=$group.Right;Bottom=$bottom};LabelArea=[pscustomobject]@{Left=$group.Left;Top=$top;Right=$c.Left;Bottom=$bottom}}
  $previous=$c
 }
 Json @{SourceContract='v1.18.2 SettingsTab General: Theme, Color, Language, then minimizeToTray, launchAtStartup, animations; advanced and autostart-hidden rows absent';Composite=$group;Language=$language[0];Rows=$rows;Tree=$tree} "$script:Stage-general-row-binding"
 return $rows
}
function Save-RowPixels($Row,$Name){
 Check-Budget;$screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
 if($Row.Left -lt $screen.Left -or $Row.Top -lt $screen.Top -or $Row.Right -gt $screen.Right -or $Row.Bottom -gt $screen.Bottom){throw 'ENV_BLOCK: row pixels outside actual desktop'}
 $size=[System.Drawing.Size]::new($Row.Right-$Row.Left,$Row.Bottom-$Row.Top);$b=[System.Drawing.Bitmap]::new($size.Width,$size.Height);$g=[System.Drawing.Graphics]::FromImage($b)
 try{$g.CopyFromScreen([System.Drawing.Point]::new($Row.Left,$Row.Top),[System.Drawing.Point]::Empty,$size);$b.Save((Join-Path $Evidence "$Name.png"),[System.Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
 Json $Row "$Name-bounds"
}
function TaskManager {
 $script:Stage='task-manager';Check-Budget;Write-Event keys @{Method='Ctrl+Shift+Esc';Foreground=[Issue3456Native]::GetForegroundWindow().ToInt64()};[System.Windows.Forms.SendKeys]::SendWait('^+{ESC}')
 $end=[DateTime]::UtcNow.AddSeconds(15)
 do{Check-Budget;$roots=@([Controls3536]::Roots()|Where-Object {$_.Name -eq 'Task Manager'});$matches=@();foreach($r in $roots){$p=Get-Process -Id $r.Pid -ErrorAction Stop;if($p.ProcessName -eq 'Taskmgr'){$matches+=[pscustomobject]@{Id=$p.Id;Path=$p.Path;StartUtc=$p.StartTime.ToUniversalTime().ToString('o');Hwnd=$r.Handle}}};if($matches.Count -eq 1){return $matches[0]};if($matches.Count -gt 1){throw 'ENV_BLOCK: ambiguous actual Task Manager'};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 Desktop-Snapshot task-manager-missing|Out-Null;throw 'ENV_BLOCK: actual Task Manager window unavailable'
}
function Restart-Control($Manager,$OldShell){
 $null=Focus-App $Manager;$tree=@(Snapshot $Manager);Save-Desktop task-manager-before
 $details=@($tree|Where-Object {$_.Name -eq 'More details' -and $_.Type -eq 50000});if($details.Count -eq 1){Click-Control $Manager $details[0];$tree=@(Snapshot $Manager)}
 $processTab=@($tree|Where-Object {$_.Name -eq 'Processes' -and $_.Type -eq 50019});if($processTab.Count -eq 1){Click-Control $Manager $processTab[0];$tree=@(Snapshot $Manager)}
 $explorers=@(Get-Process explorer -ErrorAction SilentlyContinue)
 if($explorers.Count -ne 1 -or $explorers[0].Id -ne $OldShell.Id){throw 'ENV_BLOCK: Explorer row cannot be uniquely mapped to shell PID'}
 # Maximize through the actual caption so list rows and the Restart control can fit the desktop.
 $max=@($tree|Where-Object {$_.Name -ceq 'Maximize' -and $_.Type -eq 50000 -and $_.Enabled -and $_.Pid -eq $Manager.Id})
 if($max.Count -ne 1){throw 'ENV_BLOCK: actual Task Manager Maximize unavailable'}
 Click-Control $Manager $max[0]
 $end=[DateTime]::UtcNow.AddSeconds(5);do{Check-Budget;$null=Assert-App $Manager;if([Tray3166Native]::Zoomed([IntPtr]$Manager.Hwnd)){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 if(-not [Tray3166Native]::Zoomed([IntPtr]$Manager.Hwnd)){throw 'ENV_BLOCK: ordinary Task Manager maximize did not complete'}
 $previous=$null;$rows=@();$end=[DateTime]::UtcNow.AddSeconds(60)
 for($page=0;$page -le 12;$page++){
  Check-Budget;if([DateTime]::UtcNow -ge $end){throw 'ENV_BLOCK: bounded Explorer row navigation deadline'}
  $null=Alive $script:App;if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: hidden app precondition lost during Processes navigation'}
  $actualShell=Shell;if($actualShell.Id -ne $OldShell.Id -or $actualShell.StartUtc -ne $OldShell.StartUtc){throw 'ENV_BLOCK: Explorer changed before ordinary Restart'}
  $explorers=@(Get-Process explorer -ErrorAction SilentlyContinue);if($explorers.Count -ne 1 -or $explorers[0].Id -ne $OldShell.Id){throw 'ENV_BLOCK: unique shell process mapping lost'}
  $tree=@(Snapshot $Manager);$lists=@($tree|Where-Object {$_.Name -ceq 'List of items' -and $_.ClassName -ceq 'TmScrollViewer' -and $_.Type -eq 50028 -and $_.Enabled -and $_.Pid -eq $Manager.Id})
  $tabs=@($tree|Where-Object {$_.Name -ceq 'Processes' -and $_.Type -eq 50019 -and $_.Enabled -and $_.Pid -eq $Manager.Id})
  if($lists.Count -ne 1 -or $tabs.Count -ne 1){throw 'ENV_BLOCK: exact Task Manager Processes list unavailable'}
  $list=$lists[0];$screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
  if($list.Left -lt $screen.Left -or $list.Top -lt $screen.Top -or $list.Right -gt $screen.Right -or $list.Bottom -gt $screen.Bottom){throw 'ENV_BLOCK: Processes viewport clipped outside desktop'}
  $inside={param($c) $c.Left -ge $list.Left -and $c.Right -le $list.Right -and $c.Top -ge $list.Top -and $c.Bottom -le $list.Bottom}
  $visibleRows=@($tree|Where-Object {$_.ClassName -ceq 'TmViewItemSelector' -and $_.Type -eq 50024 -and $_.Enabled -and $_.Pid -eq $Manager.Id -and (& $inside $_)})
  if($visibleRows.Count -eq 0){throw 'ENV_BLOCK: native Processes row contract unavailable'}
  # This exact candidate must qualify in the fresh visible tree; it was outside the original viewport.
  $rows=@($visibleRows|Where-Object Name -CEQ 'Process: Windows Explorer')
  Json @{Shell=$actualShell;Manager=$Manager;Page=$page;List=$list;VisibleRows=$visibleRows;Rows=$rows;Tree=$tree} "actual-explorer-page-$page";Save-Desktop "actual-explorer-page-$page"
  if($rows.Count -gt 1){throw 'ENV_BLOCK: exact Explorer Processes row ambiguous'}
  if($rows.Count -eq 1){Json @{Shell=$actualShell;Rows=$rows;Tree=$tree} actual-explorer-row;break}
  $signature=($visibleRows|ForEach-Object {"$($_.Name)|$($_.Top)|$($_.Bottom)"}) -join "`n"
  if($signature -ceq $previous -or $page -eq 12){throw 'ENV_BLOCK: exact visible Explorer row unreachable within bounded native pages'};$previous=$signature
  $scroll=@($tree|Where-Object {$_.Name -ceq 'Vertical' -and $_.ClassName -ceq 'CCVScrollBar' -and $_.Type -eq 50014 -and $_.Enabled -and $_.Pid -eq $Manager.Id -and (& $inside $_)})
  if($scroll.Count -ne 1){throw 'ENV_BLOCK: unique live Processes vertical scrollbar unavailable'};$bar=$scroll[0]
  $down=@($tree|Where-Object {$_.Name -ceq 'Page down' -and $_.Type -eq 50000 -and $_.Enabled -and $_.Pid -eq $Manager.Id -and $_.Left -ge $bar.Left -and $_.Right -le $bar.Right -and $_.Top -ge $bar.Top -and $_.Bottom -le $bar.Bottom})
  if($down.Count -ne 1){throw 'ENV_BLOCK: supported live Processes Page down unavailable'}
  Click-Control $Manager $down[0]
 }
 if($rows.Count -ne 1){throw 'ENV_BLOCK: exact visible native Windows Explorer Processes row unavailable'}
 Save-RowPixels $rows[0] actual-explorer-row-pixels
 Click-Control $Manager $rows[0];$tree=@(Snapshot $Manager);$buttons=@($tree|Where-Object {$_.Name -eq 'Restart' -and $_.Type -eq 50000 -and $_.Enabled})
 if($buttons.Count -eq 1){return [pscustomobject]@{Control=$buttons[0];Root=$Manager;Route='actual selected Explorer Restart button'}}
 if($buttons.Count -gt 1){throw 'ENV_BLOCK: ambiguous Restart button'}
 # The alternate route is the selected row's actual context menu. No process restart API is used.
 $null=Focus-App $Manager;Write-Event keys @{Method='Shift+F10';SelectedRow=$rows[0];Owner=$Manager};[System.Windows.Forms.SendKeys]::SendWait('+{F10}');Start-Sleep -Milliseconds 300
 $menus=@([Controls3536]::Roots()|Where-Object {$_.ClassName -eq '#32768' -and $_.Pid -eq $Manager.Id});$items=@()
 foreach($r in $menus){$items+=@([Controls3536]::Snapshot($r.Handle,$r.Pid)|Where-Object {$_.Name -eq 'Restart' -and $_.Type -eq 50011 -and $_.Enabled}|ForEach-Object {[pscustomobject]@{Control=$_;Root=[pscustomobject]@{Id=$Manager.Id;Path=$Manager.Path;StartUtc=$Manager.StartUtc;Hwnd=$r.Handle};Route='actual Explorer context menu Restart'}})}
 Desktop-Snapshot actual-restart-menu|Out-Null;if($items.Count -ne 1){throw 'ENV_BLOCK: actual Explorer Restart button and menu unavailable'};return $items[0]
}
try {
 . (Join-Path $PSScriptRoot ui.ps1)
 $os=Get-CimInstance Win32_OperatingSystem;Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Architecture=$env:PROCESSOR_ARCHITECTURE;Desktop=[System.Windows.Forms.SystemInformation]::VirtualScreen;Difference='Server2022 build20348; reported Windows25H2 and LocalSend version unknown. No historical fix attribution.'} environment
 if($os.Caption -notmatch 'Windows Server 2022' -or $os.BuildNumber -ne '20348' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'ENV_BLOCK: selected Windows environment mismatch'}
 $desktop=[Issue3456Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw 'ENV_BLOCK: input desktop absent'};[Issue3456Native]::CloseDesktop($desktop)|Out-Null
 if(Test-Path C:\s3166){throw 'ENV_BLOCK: pre-existing3166 profile root is unowned'};New-Item -ItemType Directory C:\s3166|Out-Null
 $script:Archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip;Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip' -UseBasicParsing -OutFile $script:Archive -TimeoutSec 90
 $hash=(Get-FileHash $script:Archive).Hash;Json @{Path=$script:Archive;Sha256=$hash} archive;if($hash -ne '737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a'){throw 'ENV_BLOCK: official ZIP identity mismatch'}
 $script:App=Launch-App app 53316 C:\s3166 (Join-Path $PSScriptRoot scenario.ps1)
 $script:Stage='tray-control';$oldShell=Shell;Desktop-Snapshot tray-working-control-before|Out-Null
 $icon=Find-Tray;if(-not $icon){throw 'ENV_BLOCK: named visible LocalSend tray icon unavailable'};Json $icon actual-control-tray
 # Native minimize is a user caption action, so actual tray activation must show the window.
 Click-Name $script:App Minimize 50000
 if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd) -and -not [Tray3166Native]::Iconic([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: actual minimize control did not minimize app'}
 $icon=Find-Tray;if(-not $icon){throw 'ENV_BLOCK: actual tray control unavailable after ordinary minimize'};Shell-Click $icon;Wait-Visible $script:App;Desktop-Snapshot tray-working-control-after|Out-Null
 $script:Stage='close-to-tray';Click-Name $script:App Maximize 50000
 $end=[DateTime]::UtcNow.AddSeconds(5);do{Check-Budget;$null=Alive $script:App;if([Tray3166Native]::Zoomed([IntPtr]$script:App.Hwnd)){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 if(-not [Tray3166Native]::Zoomed([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: normal caption Maximize did not maximize same app'}
 Save-Desktop close-to-tray-maximized;Click-Control $script:App (Find-SettingsNavigation $script:App)
 # Bind the complete release-specific named section and all source Boolean rows before selecting the requested label.
 $booleanLabels=@('Minimize to the System Tray/Menu Bar when closing','Autostart after login','Animations')
 $generalComposite=(@('General','Theme','Color','Language')+$booleanLabels) -join "`n"
 $rows=@(Bind-GeneralBooleanRows $script:App $generalComposite 'English' $booleanLabels)
 $target=@($rows|Where-Object Label -eq $booleanLabels[0]);if($target.Count -ne 1){throw 'ENV_BLOCK: requested close-to-tray source row ambiguous'}
 Save-Desktop close-to-tray-setting-before;Save-RowPixels $target[0].Row close-to-tray-row-before
 $profile=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json
 $persisted=$profile.'flutter.ls_minimize_to_tray' -eq $true
 if(($target[0].Control.Toggle -eq 1) -ne $persisted){throw 'ENV_BLOCK: native toggle and ordinary persisted setting disagree before input'}
 if(-not $persisted){Click-Control $script:App $target[0].Control}
 $end=[DateTime]::UtcNow.AddSeconds(5)
 do{Check-Budget;$rows=@(Bind-GeneralBooleanRows $script:App $generalComposite 'English' $booleanLabels);$target=@($rows|Where-Object Label -eq $booleanLabels[0]);$profile=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json;if($target.Count -eq 1 -and $target[0].Control.Toggle -eq 1 -and $profile.'flutter.ls_minimize_to_tray' -eq $true){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 Save-Desktop close-to-tray-setting-after;Save-RowPixels $target[0].Row close-to-tray-row-after
 Json @{Path=$script:App.Profile;MinimizeToTray=$profile.'flutter.ls_minimize_to_tray';NativeToggle=$target[0].Control.Toggle;ActualRow=$target[0];ObservedOnly=$true} close-to-tray-setting-readback
 if($target.Count -ne 1 -or $target[0].Control.Toggle -ne 1 -or $profile.'flutter.ls_minimize_to_tray' -ne $true){throw 'ENV_BLOCK: actual ordinary close-to-tray toggle and persisted true-state readback not qualified'}
 Click-Name $script:App Close 50000;$null=Alive $script:App
 if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: normal Close did not hide same app'}
 $manager=TaskManager;$null=Focus-App $manager
 # Task Manager focus setup must not re-show the hidden LocalSend window.
 if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: hidden precondition lost before Restart'}
 $restart=Restart-Control $manager $oldShell;Json $restart actual-restart-control;Desktop-Snapshot restart-before|Out-Null
 $capture=Test-Path (Join-Path $Evidence capture-qualified.json)
 if($capture){try{Start-Clip actual-explorer-restart}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} recorder-block}}
 try {if($restart.Control.Type -eq 50011){Shell-Click $restart.Control}else{Click-Control $restart.Root $restart.Control};$script:Triggered=$true;Write-Event actualRestart @{Route=$restart.Route;OldShell=$oldShell;App=$script:App};Start-Sleep -Seconds 2;Desktop-Snapshot restart-during|Out-Null;Start-Sleep -Seconds 3}finally{try{Stop-Clip}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} recorder-stop-block}}
 $end=[DateTime]::UtcNow.AddSeconds(20);$newShell=$null
 do{Check-Budget;$null=Alive $script:App;try{$candidate=Shell;if($candidate.Id -ne $oldShell.Id -or $candidate.StartUtc -ne $oldShell.StartUtc){$newShell=$candidate;break}}catch{Write-Event shellWait @{Error="$_"}};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 Desktop-Snapshot restart-after|Out-Null
 if(-not $newShell){throw 'ENV_BLOCK: actual Explorer identity transition not confirmed'}
 Json @{Before=$oldShell;After=$newShell;SameApp=Alive $script:App|Select-Object Id,Path,StartTime,MainWindowHandle} actual-shell-transition
 Qualify-RenewedTray $newShell
 $icon=Find-Tray
 if(-not $icon){Json @{Status='CURRENT_RELEASE_FAILURE';ProductExperiments=1;Symptom='No actual LocalSend tray icon after valid Explorer Restart';SameApp=$script:App;OS='Server2022 build20348';HistoricalAttribution='UNKNOWN'} final-result;exit 1}
 Json $icon actual-after-tray;Shell-Click $icon
 $end=[DateTime]::UtcNow.AddSeconds(12);$activated=$false;do{Check-Budget;$null=Alive $script:App;if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd) -and [Issue3456Native]::GetForegroundWindow().ToInt64() -eq $script:App.Hwnd){$activated=$true;break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 Desktop-Snapshot actual-tray-activation-after|Out-Null
 $windowVisible=[Tray3166Native]::Visible([IntPtr]$script:App.Hwnd);$foreground=[Issue3456Native]::GetForegroundWindow().ToInt64()
 Json @{SameApp=$script:App;WindowVisible=$windowVisible;ActualForeground=$foreground;ExpectedForeground=$script:App.Hwnd;ActualActivation=$activated} activation-observation
 if($windowVisible -and $foreground -ne $script:App.Hwnd){throw 'ENV_BLOCK: same app window visible but owned foreground unavailable after actual tray click'}
 Json @{Status=if($activated){'CURRENT_RELEASE_NON_REPRODUCTION'}else{'CURRENT_RELEASE_FAILURE'};ProductExperiments=1;TrayRenderedAndLocated=$true;ActualTrayActivation=$activated;SameApp=$script:App;OS='Server2022 build20348';OriginalWindows25H2='UNTESTED';HistoricalAttribution='UNKNOWN'} final-result
 if(-not $activated){exit 1}
}catch{try{Desktop-Snapshot "$script:Stage-exception"|Out-Null}catch{};$_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt);Json @{Status='ENV_BLOCK';Error="$_";RestartInputAttempted=$script:Triggered;ProductExperiments=0;Verdict='No valid completed shell transition outcome'} final-result;exit 2}
finally{try{Stop-Clip}catch{};foreach($a in $script:Owned){try{Stop-Owned $a}catch{}};Stop-Transcript}
