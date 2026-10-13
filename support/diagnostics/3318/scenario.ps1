param([Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][DateTime]$Deadline,[string]$PrelaunchPhase,[string]$PhaseContext,[string]$PhaseTag)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot prelaunch.ps1)
if($PrelaunchPhase){Run-PrelaunchPhase}
$script:Recorder=$null;$script:Outcome='NONE';$script:ProductStarted=$null;$script:SectionObservation=0
$receiveName=@('Receive','Quick Save','Quick Save for "Favorites"','Require PIN','Save to folder','Auto Finish','Save to history') -join "`n"
function Inside($C,$B){return $C.Left -ge $B.Left -and $C.Right -le $B.Right -and $C.Top -ge $B.Top -and $C.Bottom -le $B.Bottom}
function Rail($App){
 $tree=@(Snapshot $App);$views=@($tree|Where-Object ClassName -eq 'FLUTTERVIEW');if($views.Count -ne 1){throw 'ENV_BLOCK: unique live native client missing'}
 $rails=@();foreach($name in @("Receive`nTab 1 of 3","Send`nTab 2 of 3","Settings`nTab 3 of 3")){
  $c=@($tree|Where-Object {$_.Name -ceq $name -and $_.Type -eq 50020 -and $_.Enabled -and $_.Pid -eq $App.Id})
  if($c.Count -ne 1 -or -not (Inside $c[0] $views[0])){throw 'ENV_BLOCK: exact live three-label rail qualification failed'};$rails+=$c[0]
 }
 if($rails[0].Left -ne $rails[1].Left -or $rails[1].Left -ne $rails[2].Left -or $rails[0].Right -ne $rails[1].Right -or $rails[1].Right -ne $rails[2].Right -or $rails[0].Bottom -gt $rails[1].Top -or $rails[1].Bottom -gt $rails[2].Top){throw 'ENV_BLOCK: all-three rail geometry is not aligned/ordered'}
 Json @{Client=$views[0];Rails=$rails;Tree=$tree} "$script:Stage-rail-binding";return [pscustomobject]@{View=$views[0];Items=$rails;Tree=$tree}
}
function Settled-Receive($App){
 $end=[DateTime]::UtcNow.AddSeconds(5);$previous=$null
 do{
  Check-Budget;$rail=Rail $App;$h=Assert-App $App;$section=[Controls3536]::SnapshotSection($h,$App.Id,$receiveName,50026)
  $sample=[pscustomobject]@{NativeScope='exact Receive element.FindAll(Descendants)';Client=$rail.View;Rails=$rail.Items;Section=$section;FullTree=$rail.Tree}
  $script:SectionObservation++;$receipt="$script:Stage-section-$script:SectionObservation";Write-Event uia-section $sample;Json $sample $receipt;Save-Desktop $receipt
  $signature=@{Client=$rail.View;Rails=$rail.Items;Section=$section}|ConvertTo-Json -Depth 16 -Compress
  Check-Budget;if([DateTime]::UtcNow -ge $end){throw 'ENV_BLOCK: Receive sample completed after five-second settle deadline'}
  if($null -ne $previous -and $signature -ceq $previous){
   Check-Budget;if([DateTime]::UtcNow -ge $end){throw 'ENV_BLOCK: Receive stable acceptance after five-second settle deadline'}
   return [pscustomobject]@{Rail=$rail;Section=$section;StableSamples=2}
  }
  $previous=$signature;Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $end)
 throw 'ENV_BLOCK: Receive ancestry/geometry did not settle within five seconds'
}
function Receive-Rows($App,[switch]$AllowIncomplete){
 $settled=Settled-Receive $App;$rail=$settled.Rail;$g=$settled.Section.Group
 if(-not $g.Enabled -or $g.Name -cne $receiveName -or $g.Type -ne 50026 -or $g.Pid -ne $App.Id){throw 'ENV_BLOCK: exact release Receive ancestry identity invalid'}
 if(-not (Inside $g $rail.View) -or $g.Left -lt $rail.Items[2].Right){throw 'ENV_BLOCK: complete Receive section not visible outside navigation'}
 $checks=@($settled.Section.Descendants|Where-Object Type -eq 50002|Sort-Object Top)
 $buttons=@($settled.Section.Descendants|Where-Object Type -eq 50000)
 if($checks.Count -eq 0 -and $buttons.Count -eq 0){throw 'ENV_BLOCK: native Receive ancestry has no visible row controls; no wheel or product input permitted'}
 if(@($checks+$buttons|Where-Object {-not (Inside $_ $g) -or -not (Inside $_ $rail.View)}).Count -gt 0){throw 'ENV_BLOCK: Receive ancestry descendants outside owned section/client'}
 if(@($checks+$buttons|Where-Object {-not $_.Enabled -or $_.Pid -ne $App.Id}).Count -gt 0 -or @($checks|Where-Object {$_.Toggle -notin @(0,1)}).Count -gt 0){throw 'ENV_BLOCK: partial Receive control ownership/state invalid'}
 if($checks.Count -gt 5 -or $buttons.Count -gt 1){throw 'ENV_BLOCK: ambiguous release Receive control count'}
 $edgeClipped=@($checks+$buttons|Where-Object {$_.Top -le $rail.View.Top -or $_.Bottom -ge $rail.View.Bottom}).Count -gt 0
 if($checks.Count -ne 5 -or $buttons.Count -ne 1 -or $edgeClipped){
  if(-not $AllowIncomplete){throw 'ENV_BLOCK: complete release Receive row control count differs'}
  $binding=[pscustomobject]@{Status='INCOMPLETE';NativeScope=$settled.Section;StableSamples=$settled.StableSamples;Composite=$g;Client=$rail.View;Rails=$rail.Items;SwitchCount=$checks.Count;ButtonCount=$buttons.Count;EdgeClipped=$edgeClipped;Rows=@();Tree=$rail.Tree}
  Json $binding "$script:Stage-receive-incomplete";return $binding
 }
 if($buttons[0].Right-$buttons[0].Left -le $checks[0].Right-$checks[0].Left){throw 'ENV_BLOCK: Receive destination geometry differs from wide release button'}
 $ordered=@($checks+$buttons|Sort-Object Top);$labels=@('Quick Save','Quick Save for "Favorites"','Require PIN','Save to folder','Auto Finish','Save to history');$rows=@()
 for($i=0;$i -lt 6;$i++){$c=$ordered[$i]
  if(-not $c.Enabled -or $c.Pid -ne $App.Id -or ($i -eq 3 -and $c.Type -ne 50000) -or ($i -ne 3 -and ($c.Type -ne 50002 -or $c.Toggle -notin @(0,1)))){throw 'ENV_BLOCK: Receive row type/state/ownership invalid'}
  if($i -gt 0 -and $c.Top -le $ordered[$i-1].Bottom){throw 'ENV_BLOCK: Receive row order invalid'}
  if($i -ne 3 -and ($c.Left -ne $checks[0].Left -or $c.Right -ne $checks[0].Right)){throw 'ENV_BLOCK: Receive switch column alignment differs'}
  $top=if($i -eq 0){$g.Top}else{[int](($ordered[$i-1].Bottom+$c.Top)/2)};$bottom=if($i -eq 5){$g.Bottom}else{[int](($c.Bottom+$ordered[$i+1].Top)/2)}
  $rows+=[pscustomobject]@{Label=$labels[$i];Ordinal=$i;Control=$c;Row=[pscustomobject]@{Left=$g.Left;Right=$g.Right;Top=$top;Bottom=$bottom}}
 }
 $binding=[pscustomobject]@{Status='COMPLETE';NativeScope=$settled.Section;StableSamples=$settled.StableSamples;Contract='v1.18.2 Receive, no advanced/gallery row';Composite=$g;Client=$rail.View;Rails=$rail.Items;Rows=$rows;Tree=$rail.Tree};Json $binding "$script:Stage-receive-binding";return $binding
}
function Pixels($B,$Name){
 Check-Budget;$screen=[System.Windows.Forms.SystemInformation]::VirtualScreen;if(-not (Inside $B $screen)){throw 'ENV_BLOCK: crop outside desktop'}
 $size=[Drawing.Size]::new($B.Right-$B.Left,$B.Bottom-$B.Top);$bitmap=[Drawing.Bitmap]::new($size.Width,$size.Height);$g=[Drawing.Graphics]::FromImage($bitmap)
 try{$g.CopyFromScreen([Drawing.Point]::new($B.Left,$B.Top),[Drawing.Point]::Empty,$size);$bitmap.Save((Join-Path $Evidence "$Name.png"),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$bitmap.Dispose()};Json $B "$Name-bounds"
}
function Read-Setting($Key,$Default){$p=Get-Content $script:App.Profile -Raw -Encoding UTF8|ConvertFrom-Json;$prop=$p.PSObject.Properties[$Key];return [pscustomobject]@{Present=$null -ne $prop;Value=if($prop){$prop.Value}else{$Default};ProfileSha256=(Get-FileHash $script:App.Profile).Hash}}
function Observe($Label,$Key,$Default,$Name){$binding=Receive-Rows $script:App;$r=@($binding.Rows|Where-Object Label -ceq $Label);if($r.Count -ne 1){throw 'ENV_BLOCK: row ambiguous'};$setting=Read-Setting $Key $Default;Save-Desktop $Name;Pixels $r[0].Row "$Name-row";Json @{Row=$r[0];Setting=$setting;ObservedOnly=$true} "$Name-readback";return [pscustomobject]@{Row=$r[0];Setting=$setting}}
function Dialog-Controls([int]$Seconds=5){
 $end=[DateTime]::UtcNow.AddSeconds($Seconds);do{Check-Budget;$tree=@(Snapshot $script:App);$title=@($tree|Where-Object Name -ceq 'Enter PIN');$edit=@($tree|Where-Object {$_.Type -eq 50004 -and $_.Enabled});$confirm=@($tree|Where-Object {$_.Name -ceq 'Confirm' -and $_.Type -eq 50000 -and $_.Enabled});$cancel=@($tree|Where-Object {$_.Name -ceq 'Cancel' -and $_.Type -eq 50000 -and $_.Enabled})
  if($title.Count -eq 1 -and $edit.Count -eq 1 -and $confirm.Count -eq 1 -and $cancel.Count -eq 1){Json @{Title=$title[0];Edit=$edit[0];Confirm=$confirm[0];Cancel=$cancel[0];Tree=$tree} "$script:Stage-dialog-binding";return [pscustomobject]@{Edit=$edit[0];Confirm=$confirm[0];Cancel=$cancel[0]}}
  Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $end);Json @{Title=$title;Edits=$edit;Confirm=$confirm;Cancel=$cancel;Tree=$tree} "$script:Stage-dialog-unqualified";return $null
}
try{
 . (Join-Path $PSScriptRoot ui.ps1)
 $os=Get-CimInstance Win32_OperatingSystem;Json @{OS=$os|Select-Object Caption,Version,BuildNumber,OSArchitecture;RunnerImage=$env:ImageVersion;Desktop=[Windows.Forms.SystemInformation]::VirtualScreen;Difference='Windows Server2022 AMD64 build20348, report Windows11 x64/latest unknown; current official1.18.2 observation only'} environment
 if($os.Caption -notmatch 'Windows Server 2022' -or $os.BuildNumber -ne '20348' -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'ENV_BLOCK: assigned environment mismatch'}
 $desktop=[Issue3456Native]::OpenInputDesktop(0,$false,0x100);if($desktop -eq [IntPtr]::Zero){throw 'ENV_BLOCK: input desktop absent'};[Issue3456Native]::CloseDesktop($desktop)|Out-Null
 if(Test-Path C:\s3318){throw 'ENV_BLOCK: existing unowned case root'};New-Item -ItemType Directory C:\s3318|Out-Null
 $script:Archive=Join-Path $Evidence LocalSend-1.18.2-windows-x86-64.zip;Invoke-WebRequest 'https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-windows-x86-64.zip' -UseBasicParsing -OutFile $script:Archive -TimeoutSec 90
 $hash=(Get-FileHash $script:Archive).Hash;Json @{Path=$script:Archive;Sha256=$hash} archive;if($hash -ne '737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a'){throw 'ENV_BLOCK: ZIP hash differs'}
 $script:App=Launch-App app 53318 C:\s3318 (Join-Path $PSScriptRoot scenario.ps1)
 $script:Stage='navigation';Click-Name $script:App Maximize 50000;Save-Desktop rail-before; $rail=Rail $script:App;Click-Control $script:App $rail.Items[2]
 $end=[DateTime]::UtcNow.AddSeconds(5);do{$tree=@(Snapshot $script:App);if(@($tree|Where-Object Name -ceq "General`nTheme`nColor`nLanguage`nMinimize to the System Tray/Menu Bar when closing`nAutostart after login`nAnimations").Count -eq 1){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
 Save-Desktop settings-page;if(@($tree|Where-Object Name -ceq "General`nTheme`nColor`nLanguage`nMinimize to the System Tray/Menu Bar when closing`nAutostart after login`nAnimations").Count -ne 1){throw 'ENV_BLOCK: actual Settings click did not qualify Settings page'}
 $script:Stage='receive-visibility';for($attempt=0;$attempt -lt 12;$attempt++){
  $binding=Receive-Rows $script:App -AllowIncomplete;Save-Desktop "receive-scroll-$attempt-before";Pixels $binding.Composite "receive-scroll-$attempt-section";Json $binding "receive-scroll-$attempt-binding"
  if($binding.Status -eq 'COMPLETE'){break}
  $h=Focus-App $script:App;$live=Receive-Rows $script:App -AllowIncomplete;if($live.Status -eq 'COMPLETE'){break};$x=[int](($live.Rails[2].Right+$live.Client.Right)/2);$y=[int](($live.Client.Top+$live.Client.Bottom)/2)
  if(-not [Issue3456Native]::SetCursorPos($x,$y)){throw 'ENV_BLOCK: scroll cursor failed'};if([Issue3456Native]::GetForegroundWindow().ToInt64() -ne $h){throw 'ENV_BLOCK: scroll foreground lost'}
  Write-Event wheel @{Client=$live.Client;Rails=$live.Rails;X=$x;Y=$y;Delta=-120};[Issue3456Native]::mouse_event(0x800,0,0,4294967176,[UIntPtr]::Zero);Start-Sleep -Milliseconds 200;Save-Desktop "receive-scroll-$attempt-after";$afterBinding=Receive-Rows $script:App -AllowIncomplete;Json $afterBinding "receive-scroll-$attempt-after-binding"
 }
 $binding=Receive-Rows $script:App;$rows=@($binding.Rows);Save-Desktop receive-qualified
 $script:ProductStarted=[DateTime]::UtcNow;$productEnd=$script:ProductStarted.AddSeconds(120);if($productEnd -lt $Deadline){$Deadline=$productEnd}
 $script:Stage='ordinary-control';$before=Observe 'Auto Finish' 'flutter.ls_auto_finish' $false ordinary-before;$initial=[bool]$before.Setting.Value
 if(($before.Row.Control.Toggle -eq 1) -ne $initial){throw 'ENV_BLOCK: ordinary initial readback mismatch'}
 Click-Control $script:App $before.Row.Control;Start-Sleep -Milliseconds 500;$after=Observe 'Auto Finish' 'flutter.ls_auto_finish' $false ordinary-after
 if(-not $after.Setting.Present -or [bool]$after.Setting.Value -eq $initial -or ($after.Row.Control.Toggle -eq 1) -eq $initial){$script:Outcome='INPUT_OR_PAGE_FAILURE';throw 'PRODUCT_OBSERVATION: ordinary Receive control failed'}
 Click-Control $script:App $after.Row.Control;Start-Sleep -Milliseconds 500;$restored=Observe 'Auto Finish' 'flutter.ls_auto_finish' $false ordinary-restored
 if([bool]$restored.Setting.Value -ne $initial -or ($restored.Row.Control.Toggle -eq 1) -ne $initial){throw 'ENV_BLOCK: working control restore failed'}
 $script:Stage='require-pin';$pin=Observe 'Require PIN' 'flutter.ls_receive_pin' $null pin-before;if($pin.Setting.Present -or $pin.Row.Control.Toggle -ne 0){throw 'ENV_BLOCK: fresh target must be absent/off without target preference write'}
 if(Test-Path (Join-Path $Evidence capture-qualified.json)){try{Start-Clip require-pin-dialog}catch{Json @{Error="$_";Status='RECORDER_BLOCK'} recording-block}}
 Click-Control $script:App $pin.Row.Control;$dialog=Dialog-Controls;Save-Desktop pin-dialog-appearance
 if(-not $dialog){$tree=@(Snapshot $script:App);$script:Outcome=if(@($tree|Where-Object {$_.Type -eq 50004 -or $_.Name -ceq 'Confirm' -or $_.Name -ceq 'Cancel'}).Count -gt 0){'DIALOG_BINDING_BLOCK'}else{'ABSENT_DIALOG_OBSERVATION'};throw 'PRODUCT_OBSERVATION: actual PIN dialog absent or not qualified'}
 Type-Control $script:App $dialog.Edit '2468';$dialog=Dialog-Controls 2;if(-not $dialog -or $dialog.Edit.Value -cne '2468'){throw 'ENV_BLOCK: actual edit paste readback missing'};Save-Desktop pin-dialog-entered
 Click-Control $script:App $dialog.Confirm;Start-Sleep -Milliseconds 700;$enabled=Observe 'Require PIN' 'flutter.ls_receive_pin' $null pin-enabled
 if(-not $enabled.Setting.Present -or $enabled.Setting.Value -cne '2468' -or $enabled.Row.Control.Toggle -ne 1){$script:Outcome='CONFIRMATION_FAILURE_OBSERVATION';throw 'PRODUCT_OBSERVATION: actual confirmed PIN did not enable and persist'}
 Click-Control $script:App $enabled.Row.Control;Start-Sleep -Milliseconds 700;$disabled=Observe 'Require PIN' 'flutter.ls_receive_pin' $null pin-disabled
 if($disabled.Setting.Present -or $disabled.Row.Control.Toggle -ne 0){$script:Outcome='DISABLE_FAILURE_OBSERVATION';throw 'PRODUCT_OBSERVATION: actual PIN disable did not clear'}
 $script:Outcome='CURRENT_RELEASE_NON_REPRODUCTION';Json @{Status=$script:Outcome;OfficialVersion='1.18.2';OSDifference='Server2022 versus Windows11';NoHistoricalOrFixAttribution=$true;OrdinaryControlRestored=$true;ConfirmedPinEnabled=$true;PinDisabled=$true} product-result
}catch{Save-Desktop final-error;$_|Format-List * -Force|Out-File (Join-Path $Evidence error-original.txt);Json @{Status=if($script:Outcome -eq 'NONE'){'ENV_BLOCK'}else{$script:Outcome};Error="$_";DeterministicFailure=$false;CauseProven=$false} product-result;exit 2}
finally{if($script:Recorder){try{Stop-Clip}catch{Json @{Error="$_"} recording-stop-block}};if($script:ProductStarted){Json @{Started=$script:ProductStarted;Ended=[DateTime]::UtcNow;MaximumSeconds=120} product-clock};foreach($a in $script:Owned){Stop-Owned $a}}
