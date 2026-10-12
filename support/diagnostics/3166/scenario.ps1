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
function Find-Tray([int]$Seconds=12){
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);$opened=$false
 do{Check-Budget;$icon=Tray-Control 'LocalSend';if($icon){return $icon};if(-not $opened){$chevron=Tray-Control 'Show hidden icons';if(-not $chevron){$chevron=Tray-Control 'Notification Chevron'};if($chevron){Shell-Click $chevron;$opened=$true}};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 return $null
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
 $rows=@($tree|Where-Object {$_.Name -eq 'Windows Explorer' -and $_.Type -in @(50029,50007)})
 Json @{Shell=$OldShell;Rows=$rows;Tree=$tree} actual-explorer-row
 if($rows.Count -ne 1){Save-Desktop task-manager-row-missing;throw 'ENV_BLOCK: unique native Windows Explorer Processes row unavailable'}
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
 $script:App=Launch-App app 53316 C:\s3166
 $script:Stage='tray-control';$oldShell=Shell;Desktop-Snapshot tray-working-control-before|Out-Null
 $icon=Find-Tray;if(-not $icon){throw 'ENV_BLOCK: named visible LocalSend tray icon unavailable'};Json $icon actual-control-tray
 # Native minimize is a user caption action, so actual tray activation must show the window.
 Click-Name $script:App Minimize 50000
 if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd) -and -not [Tray3166Native]::Iconic([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: actual minimize control did not minimize app'}
 $icon=Find-Tray;if(-not $icon){throw 'ENV_BLOCK: actual tray control unavailable after ordinary minimize'};Shell-Click $icon;Wait-Visible $script:App;Desktop-Snapshot tray-working-control-after|Out-Null
 $script:Stage='close-to-tray';Click-Name $script:App "Settings`nTab 3 of 3" 50000
 $label=Find-Control $script:App 'Minimize to the System Tray/Menu Bar when closing';$tree=@(Snapshot $script:App)
 $switches=@($tree|Where-Object {$_.Type -eq 50002 -and $_.Enabled -and $_.Left -ge $label.Right -and $_.Top -le $label.Bottom -and $_.Bottom -ge $label.Top})
 Json @{Label=$label;Switches=$switches;Tree=$tree} close-to-tray-control;Save-Desktop close-to-tray-setting-before
 if($switches.Count -ne 1){throw 'ENV_BLOCK: unique label-bound close-to-tray checkbox unavailable'}
 $profile=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json
 if($profile.'flutter.ls_minimize_to_tray' -ne $true){Click-Control $script:App $switches[0]}
 $end=[DateTime]::UtcNow.AddSeconds(5);do{Check-Budget;$profile=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json;if($profile.'flutter.ls_minimize_to_tray' -eq $true){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 Json @{Path=$script:App.Profile;MinimizeToTray=$profile.'flutter.ls_minimize_to_tray';ObservedOnly=$true} close-to-tray-setting-readback;Save-Desktop close-to-tray-setting-after
 if($profile.'flutter.ls_minimize_to_tray' -ne $true){throw 'ENV_BLOCK: actual ordinary setting did not persist true'}
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
 $icon=Find-Tray
 if(-not $icon){Json @{Status='CURRENT_RELEASE_FAILURE';ProductExperiments=1;Symptom='No actual LocalSend tray icon after valid Explorer Restart';SameApp=$script:App;OS='Server2022 build20348';HistoricalAttribution='UNKNOWN'} final-result;exit 1}
 Json $icon actual-after-tray;Shell-Click $icon
 $end=[DateTime]::UtcNow.AddSeconds(12);$activated=$false;do{Check-Budget;$null=Alive $script:App;if([Tray3166Native]::Visible([IntPtr]$script:App.Hwnd) -and [Issue3456Native]::GetForegroundWindow().ToInt64() -eq $script:App.Hwnd){$activated=$true;break};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $end)
 Desktop-Snapshot actual-tray-activation-after|Out-Null
 Json @{Status=if($activated){'CURRENT_RELEASE_NON_REPRODUCTION'}else{'CURRENT_RELEASE_FAILURE'};ProductExperiments=1;TrayRenderedAndLocated=$true;ActualTrayActivation=$activated;SameApp=$script:App;OS='Server2022 build20348';OriginalWindows25H2='UNTESTED';HistoricalAttribution='UNKNOWN'} final-result
 if(-not $activated){exit 1}
}catch{try{Desktop-Snapshot "$script:Stage-exception"|Out-Null}catch{};$_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt);Json @{Status='ENV_BLOCK';Error="$_";RestartInputAttempted=$script:Triggered;ProductExperiments=0;Verdict='No valid completed shell transition outcome'} final-result;exit 2}
finally{try{Stop-Clip}catch{};foreach($a in $script:Owned){try{Stop-Owned $a}catch{}};Stop-Transcript}
