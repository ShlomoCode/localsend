param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline,[string]$PrelaunchPhase,[string]$PhaseContext,[string]$PhaseTag)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot prelaunch.ps1)
if($PrelaunchPhase){Run-PrelaunchPhase}
Start-Transcript (Join-Path $Evidence scenario-original.txt)
$script:Results=@();$script:QualifiedInput=$false
function Codes([string]$Text){return @($Text.ToCharArray()|ForEach-Object {'U+{0:X4}' -f [int]$_})}
function Observe($Name){Json @(Snapshot $script:App) "$Name-tree";Save-Desktop $Name}
function Bind-Alias([string]$Expected){
 $end=[DateTime]::UtcNow.AddSeconds(25);$previous=$null
 for($page=0;$page -le 8;$page++){
  Check-Budget;if([DateTime]::UtcNow -ge $end){throw 'ENV_BLOCK: bounded alias navigation deadline'}
  $tree=@(Snapshot $script:App);Json $tree "$script:Stage-alias-page-$page";Save-Desktop "$script:Stage-alias-page-$page"
  $matches=@($tree|Where-Object {$_.Name -ceq $Expected -and $_.Type -eq 50000 -and $_.Enabled -and $_.Pid -eq $script:App.Id})
  if($matches.Count -gt 1){throw 'ENV_BLOCK: alias button ambiguous'}
  if($matches.Count -eq 1){
   $views=@($tree|Where-Object {$_.ClassName -ceq 'FLUTTERVIEW' -and $_.Pid -eq $script:App.Id -and $_.Enabled})
   if($views.Count -ne 1 -or $matches[0].Left -lt $views[0].Left -or $matches[0].Right -gt $views[0].Right -or $matches[0].Top -lt $views[0].Top -or $matches[0].Bottom -gt $views[0].Bottom){throw 'ENV_BLOCK: full alias button outside actual viewport'}
   return $matches[0]
  }
  $signature=($tree|ForEach-Object {"$($_.Name)|$($_.Type)|$($_.Top)|$($_.Bottom)"}) -join "`n"
  if($page -eq 8 -or $signature -ceq $previous){throw 'ENV_BLOCK: named current alias button not reachable'};$previous=$signature
  $views=@($tree|Where-Object {$_.ClassName -ceq 'FLUTTERVIEW' -and $_.Pid -eq $script:App.Id -and $_.Enabled})
  if($views.Count -ne 1){throw 'ENV_BLOCK: owned Flutter viewport unavailable for ordinary wheel'};$view=$views[0]
  $h=Focus-App $script:App;$nav=Find-SettingsNavigation $script:App
  # Scroll in the content area to the right of the proven maximized rail.
  if(-not [Tray89Native]::Zoomed([IntPtr]$h) -or $nav.Right -ge $view.Right){throw 'ENV_BLOCK: maximized content viewport not qualified'}
  $x=[int](($nav.Right+$view.Right)/2);$y=[int](($view.Top+$view.Bottom)/2)
  if(-not [Issue89Native]::SetCursorPos($x,$y)){throw 'ENV_BLOCK: wheel cursor positioning failed'}
  if([Issue89Native]::GetForegroundWindow().ToInt64() -ne $h){throw 'ENV_BLOCK: foreground stolen before wheel'}
  Write-Event wheel @{App=$script:App;View=$view;Navigation=$nav;X=$x;Y=$y;Delta=-720}
  [Issue89Native]::mouse_event(0x800,0,0,4294966576,[UIntPtr]::Zero);Start-Sleep -Milliseconds 350
 }
}
function Settings {
 if(-not [Tray89Native]::Zoomed([IntPtr]$script:App.Hwnd)){
  Click-Name $script:App Maximize 50000
  $end=[DateTime]::UtcNow.AddSeconds(5);do{Check-Budget;if([Tray89Native]::Zoomed([IntPtr]$script:App.Hwnd)){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
  if(-not [Tray89Native]::Zoomed([IntPtr]$script:App.Hwnd)){throw 'ENV_BLOCK: native maximize did not complete'}
 }
 Click-Control $script:App (Find-SettingsNavigation $script:App)
}
function Edit-Alias([string]$Expected,[string]$Target){
 $script:QualifiedInput=$false;Settings
 $button=Bind-Alias $Expected;Click-Control $script:App $button
 $title=Find-Control $script:App 'Device name' 50020
 $confirm=Find-Control $script:App Confirm 50000
 $tree=@(Snapshot $script:App);$edits=@($tree|Where-Object {$_.Type -eq 50004 -and $_.Enabled -and $_.Pid -eq $script:App.Id})
 if($edits.Count -ne 1){throw 'ENV_BLOCK: unique actual alias dialog edit unavailable'};$edit=$edits[0]
 if($edit.Value -cne $Expected){throw 'ENV_BLOCK: alias edit initial value mismatch'}
 if($title.Bottom -gt $edit.Top -or $edit.Bottom -gt $confirm.Top){throw 'ENV_BLOCK: alias dialog source order/geometry mismatch'}
 Json @{Title=$title;Edit=$edit;Confirm=$confirm;Tree=$tree;Expected=$Expected;Target=$Target;TargetUnits=Codes $Target} "$script:Stage-dialog-binding"
 Click-Control $script:App $edit
 $focused=@(Snapshot $script:App|Where-Object {$_.Type -eq 50004 -and $_.Focused -and $_.Enabled})
 if($focused.Count -ne 1 -or $focused[0].Left -ne $edit.Left -or $focused[0].Top -ne $edit.Top){throw 'ENV_BLOCK: alias edit keyboard focus mismatch'}
 [Clipboard89]::SetText($Target)
 $clipboard=[Clipboard89]::GetText();if($clipboard -cne $Target){throw 'ENV_BLOCK: exact Unicode clipboard input mismatch'}
 if(Test-Path (Join-Path $Evidence capture-qualified.json)){try{Start-Clip $script:Stage}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "$script:Stage-recorder-block"}}
 Write-Event aliasPaste @{App=$script:App;Edit=$edit;Text=$Target;Units=Codes $Target;Clipboard=$clipboard}
 [System.Windows.Forms.SendKeys]::SendWait('^a^v');Start-Sleep -Milliseconds 350
 $after=@(Snapshot $script:App|Where-Object {$_.Type -eq 50004 -and $_.Focused -and $_.Enabled})
 if($after.Count -ne 1){throw 'ENV_BLOCK: pasted alias edit focus unavailable'}
 # Copy from the actual focused field; intended clipboard data alone is insufficient.
 [Clipboard89]::SetText('issue89-readback-sentinel');[System.Windows.Forms.SendKeys]::SendWait('^a^c');Start-Sleep -Milliseconds 250
 $actual=[Clipboard89]::GetText();Json @{Expected=$Target;Actual=$actual;ExpectedUnits=Codes $Target;ActualUnits=Codes $actual;NativeValue=$after[0].Value;ActualEdit=$after[0]} "$script:Stage-paste-readback"
 if($actual -cne $Target -or $after[0].Value -cne $Target){throw 'ENV_BLOCK: actual pasted alias Unicode/native value mismatch'}
 $script:QualifiedInput=$true;Observe "$script:Stage-paste-qualified"
 Click-Name $script:App Confirm 50000
 try{Stop-Clip}catch{Json @{Status='RECORDER_BLOCK';Error="$_"} "$script:Stage-recorder-stop-block"}
 $closedEnd=[DateTime]::UtcNow.AddSeconds(5)
 do{Check-Budget;$remaining=@(Snapshot $script:App|Where-Object {$_.Type -eq 50004 -or ($_.Name -ceq 'Confirm' -and $_.Type -eq 50000)});if($remaining.Count -eq 0){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $closedEnd)
 if($remaining.Count -ne 0){throw 'ENV_BLOCK: ordinary alias Confirm closure not qualified'}
 $end=[DateTime]::UtcNow.AddSeconds(8);$persisted=$false
 do{Check-Budget;$null=Assert-App $script:App;$p=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json;if($p.'flutter.ls_alias' -ceq $Target){$persisted=$true;break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 Json @{Persisted=$persisted;Actual=$p.'flutter.ls_alias';Expected=$Target;Path=$script:App.Profile} "$script:Stage-persisted"
 if(-not $persisted){throw 'PRODUCT_FAILURE: qualified alias did not persist'}
 $nav=Find-SettingsNavigation $script:App
 $receive=Find-Control $script:App "Receive`nTab 1 of 3" 50020;Click-Control $script:App $receive
 $null=Find-Control $script:App 'Receive via link' 50000
 $receiveTree=@(Snapshot $script:App)
 if(@($receiveTree|Where-Object {$_.Name -ceq $Target -and $_.Type -eq 50000}).Count -ne 0){throw 'ENV_BLOCK: Settings alias button persists after Receive input'}
 Observe "$script:Stage-receive-transition"
 Click-Control $script:App (Find-SettingsNavigation $script:App);$null=Bind-Alias $Target;Observe "$script:Stage-same-pid-responsive"
 $before=$script:App;Stop-Owned $before
 $script:App=Launch-App app 53089 C:\s89 (Join-Path $PSScriptRoot scenario.ps1) -PreserveProfile
 Settings;$null=Bind-Alias $Target;Observe "$script:Stage-relaunch-persisted"
 $script:Results+=@{Condition=$script:Stage;Target=$Target;Units=Codes $Target;Before=$before;After=$script:App;PasteQualified=$true;SamePidResponsive=$true;PersistedRelaunch=$true;Status='CURRENT_RELEASE_NON_REPRODUCTION'}
 Json $script:Results conditions
}
try{
 . (Join-Path $PSScriptRoot ui.ps1);. (Join-Path $PSScriptRoot navigation.ps1)
 $os=Get-CimInstance Win32_OperatingSystem
 Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Architecture=$env:PROCESSOR_ARCHITECTURE;Desktop=[System.Windows.Forms.SystemInformation]::VirtualScreen;Difference='Server2022 AMD64 / official 1.18.2; reporter Windows version and artifact unknown'} environment
 if($os.Caption -notmatch 'Windows Server 2022' -or $os.BuildNumber -ne '20348' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'ENV_BLOCK: selected Windows environment mismatch'}
 $desktop=[Issue89Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw 'ENV_BLOCK: input desktop absent'};[Issue89Native]::CloseDesktop($desktop)|Out-Null
 if(Test-Path C:\s89){throw 'ENV_BLOCK: issue89 profile root pre-exists unowned'};New-Item -ItemType Directory C:\s89|Out-Null
 $script:Archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip
 Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip' -UseBasicParsing -OutFile $script:Archive -TimeoutSec 90
 $hash=(Get-FileHash $script:Archive).Hash;Json @{Path=$script:Archive;Sha256=$hash;Source='official release ZIP'} archive
 if($hash -ne '737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a'){throw 'ENV_BLOCK: official release archive mismatch'}
 $script:App=Launch-App app 53089 C:\s89 (Join-Path $PSScriptRoot scenario.ps1)
 $script:Stage='ascii-control';Edit-Alias '89-app' 'xxxx-nuc'
 $script:Stage='apostrophe-only';Edit-Alias 'xxxx-nuc' ('xxxx'+[char]0x2019+'nuc')
 $script:Stage='apostrophe-terminal-quote';Edit-Alias ('xxxx'+[char]0x2019+'nuc') ('xxxx'+[char]0x2019+'nuc'+[char]0x201D)
 Json @{Status='CURRENT_RELEASE_NON_REPRODUCTION';ProductExperiments=3;Conditions=$script:Results;HistoricalVersion='UNKNOWN';HistoricalOutcome='UNRESOLVED'} final-result
}catch{
try{Observe "$script:Stage-exception"}catch{Json @{Error="$_";App=$script:App;ObservedUtc=[DateTime]::UtcNow.ToString('o')} exception-observation-error}
 $live=if($script:App){Get-Process -Id $script:App.Id -ErrorAction SilentlyContinue}else{$null}
 Json @{Expected=$script:App;Actual=if($live){$live|Select-Object Id,Path,StartTime,Responding,MainWindowHandle}else{$null};QualifiedInput=$script:QualifiedInput} exception-process-observation
 $_|Format-List * -Force|Out-File (Join-Path $Evidence scenario-original-error.txt)
 $product=$script:QualifiedInput -and ("$_" -like 'PRODUCT_FAILURE:*')
 Json @{Status=if($product){'CURRENT_RELEASE_FAILURE_NEEDS_REVIEW'}else{'ENV_BLOCK'};Error="$_";Stage=$script:Stage;QualifiedInput=$script:QualifiedInput;CompletedConditions=$script:Results;ProductExperiments=$script:Results.Count;HistoricalOutcome='UNRESOLVED'} final-result;exit 2
}finally{try{Stop-Clip}catch{};foreach($a in $script:Owned){try{Stop-Owned $a}catch{Json @{App=$a;Error="$_"} "cleanup-error-$($a.Id)"}};Stop-Transcript}
