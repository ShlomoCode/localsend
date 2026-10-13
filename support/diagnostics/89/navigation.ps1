function Find-SettingsNavigation($App){
 $tree=@(Snapshot $App);$views=@($tree|Where-Object {$_.ClassName -eq 'FLUTTERVIEW' -and $_.Pid -eq $App.Id -and $_.Enabled})
 if($views.Count -ne 1){throw 'ENV_BLOCK: unique owned Flutter client unavailable for navigation'}
 $view=$views[0];$zoomed=[Tray89Native]::Zoomed([IntPtr]$App.Hwnd);$expectedType=if($zoomed){50020}else{50000};$items=@()
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
 if([Tray89Native]::Zoomed([IntPtr]$App.Hwnd) -ne $zoomed){throw 'ENV_BLOCK: native window state changed during navigation binding'}
 Json @{View=$view;Zoomed=$zoomed;ExpectedType=$expectedType;AllThree=$items;Tree=$tree} "$script:Stage-navigation-binding"
 Save-Desktop "$script:Stage-navigation-bound"
 return $items[2]
}
