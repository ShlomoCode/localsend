$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
New-Item -ItemType Directory evidence -Force|Out-Null
$observations=@()
function Capture([string]$label){
 $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$image=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$g=[Drawing.Graphics]::FromImage($image)
 try{$g.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$image.Save((Join-Path $PWD "evidence/desktop-$label.png"))}finally{$g.Dispose();$image.Dispose()}
}
Capture 'before-setup'
function SetupPane {
 $all=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 return @($all|Where-Object {try{$_.Current.Name -eq 'Windows Setup' -and $_.Current.ControlType -eq [Windows.Automation.ControlType]::Pane -and !$_.Current.IsOffscreen}catch{$false}}|Select-Object -First 1)
}
function PageSignature($pane){
 $all=$pane.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 return (@($all|ForEach-Object {try{"$($_.Current.Name)|$($_.Current.IsOffscreen)|$($_.Current.BoundingRectangle)"}catch{}})-join "`n")
}
for($attempt=0;$attempt -lt 10;$attempt++){
 $setup=SetupPane
 if(!$setup.Count){break}
 $all=$setup[0].FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 $signature=PageSignature $setup[0]
 $names=@($all|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled;offscreen=$_.Current.IsOffscreen}}catch{}})
 $button=@($all|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.IsEnabled -and ($_.Current.Name -like 'Next*' -or $_.Current.Name -eq 'Accept')}|Select-Object -Last 1)
 $entry=@{attempt=$attempt;names=$names;utc=[DateTime]::UtcNow.ToString('o')}
 if(!$button.Count){$entry.result='No enabled Next/Accept in Windows Setup';$observations+=$entry;break}
 $entry.button=$button[0].Current.Name
 try{$button[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$entry.method='UI Automation Invoke'}
 catch{$entry.result="Setup Invoke unavailable: $_";$observations+=$entry;break}
 $observations+=$entry
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 do{
  Start-Sleep -Milliseconds 250
  $next=SetupPane
  if(!$next.Count -or (PageSignature $next[0]) -ne $signature){break}
 }while([DateTime]::UtcNow -lt $deadline)
 Capture "setup-$attempt"
}
ConvertTo-Json -InputObject @($observations) -Depth 6|Set-Content evidence/desktop-setup-actions.json
Capture 'after-setup'
$remaining=SetupPane
if($remaining.Count){
 $remaining[0].FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;offscreen=$_.Current.IsOffscreen}}catch{}}|ConvertTo-Json -Depth 5|Set-Content evidence/desktop-setup-blocker.json
 throw 'Windows privacy setup remains visible; desktop is not ready'
}
