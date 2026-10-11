$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
New-Item -ItemType Directory evidence -Force|Out-Null
$observations=@()
function Capture([string]$label){
 $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$image=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$g=[Drawing.Graphics]::FromImage($image)
 try{$g.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$image.Save((Join-Path $PWD "evidence/desktop-$label.png"))}finally{$g.Dispose();$image.Dispose()}
}
Capture 'before-setup'
for($attempt=0;$attempt -lt 10;$attempt++){
 $root=[Windows.Automation.AutomationElement]::RootElement
 $windows=$root.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)
 $setup=@($windows|Where-Object {$_.Current.Name -eq 'Windows Setup'}|Select-Object -First 1)
 if(!$setup.Count){break}
 $all=$setup[0].FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
 $names=@($all|ForEach-Object {try{@{name=$_.Current.Name;type=$_.Current.ControlType.ProgrammaticName;enabled=$_.Current.IsEnabled}}catch{}})
 $button=@($all|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.IsEnabled -and ($_.Current.Name -like 'Next*' -or $_.Current.Name -eq 'Accept')}|Select-Object -Last 1)
 $entry=@{attempt=$attempt;names=$names;utc=[DateTime]::UtcNow.ToString('o')}
 if(!$button.Count){$entry.result='No enabled Next/Accept in Windows Setup';$observations+=$entry;break}
 $entry.button=$button[0].Current.Name
 try{$button[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$entry.method='UI Automation Invoke'}
 catch{$button[0].SetFocus();[Windows.Forms.SendKeys]::SendWait('{ENTER}');$entry.method='Focused setup button and Enter'}
 $observations+=$entry
 Start-Sleep -Milliseconds 700
 Capture "setup-$attempt"
}
$observations|ConvertTo-Json -Depth 6|Set-Content evidence/desktop-setup-actions.json
Capture 'after-setup'
