$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'reused/windows3393-ui.ps1'
# Compile the existing native helper and capture the actual initialized window
# before the iOS helper starts its finite background interval.
& $script -Action snapshot -Label windows-ui-prewarmed
[Console]::Out.WriteLine('ISSUE1591_RPC:'+(@{ready=$true;pid=$PID}|ConvertTo-Json -Compress))
while($null -ne ($line=[Console]::In.ReadLine())){
 $request=$null
 try{
  $request=$line|ConvertFrom-Json
  if($request.action -notin @('click','snapshot')){throw 'Unsupported Windows UI action'}
  if($request.label -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid evidence label'}
  & $script -Action $request.action -X ([int]$request.x) -Y ([int]$request.y) -Label $request.label -RequireForeground:([bool]$request.foreground) -UseControlSequence:([bool]$request.sequence)
  $result=@{id=$request.id;ok=$true;utc=[DateTime]::UtcNow.ToString('o')}
 }catch{$result=@{id=$request.id;ok=$false;error=$_.Exception.ToString();utc=[DateTime]::UtcNow.ToString('o')}}
 [Console]::Out.WriteLine('ISSUE1591_RPC:'+($result|ConvertTo-Json -Compress))
}
