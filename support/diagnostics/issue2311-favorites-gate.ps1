param(
 [Parameter(Mandatory=$true)][ValidateSet('Preflight','Validate')][string]$Mode,
 [Parameter(Mandatory=$true)][string]$OutputPath,
 [string[]]$CapturePaths=@(),
 [string[]]$ActionPaths=@(),
 [uint32]$ExpectedPid=0,
 [long]$ExpectedHwnd=0,
 [string]$ReleaseReportPath='evidence/release-ui-report.json'
)
$ErrorActionPreference='Stop'
$rectangle=@{x=85;y=185;width=230;height=160}
$references=@(
 @{role='template';name='favorites-positive-template.png';sha256='00fd6e2b68f07bf10fd7fdbe6be4f5cb1dde0a84720ca6758cfd8d66f14dc990'},
 @{role='positive-control';name='favorites-positive-control.png';sha256='56e7574e1589745ab2d5c234d178a39f7aa89b72873a8a6acd67cab4d9ff8be2'},
 @{role='negative-control';name='favorites-negative-control.png';sha256='ec9f371b355c2506b91d1c2b46edc418bb983544b733f69321b127b58e462662'}
)
$report=[ordered]@{schema=1;mode=$Mode;utc=[DateTime]::UtcNow.ToString('o');expectedPid=$ExpectedPid;expectedHwnd=$ExpectedHwnd;
 expectedGeometry=@{width=400;height=493};rectangle=$rectangle;comparison='Exact ARGB equality at every interior pixel; no threshold';
 references=@();templateGeometry=$null;releasePin=$null;liveIdentity=$null;observations=@();passed=$false;error=$null}
$template=$null
function CompareFavorites([string]$Path){
 $resolved=(Resolve-Path -LiteralPath $Path).Path
 $hash=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
 $bitmap=[System.Drawing.Bitmap]::new($resolved)
 try{
  $geometry=@{width=$bitmap.Width;height=$bitmap.Height}
  $geometryMatches=$bitmap.Width -eq 400 -and $bitmap.Height -eq 493
  $mismatches=0;$samples=@()
  if($geometryMatches){
   for($y=$rectangle.y;$y -lt ($rectangle.y+$rectangle.height);$y++){
    for($x=$rectangle.x;$x -lt ($rectangle.x+$rectangle.width);$x++){
     $expected=$template.GetPixel($x,$y).ToArgb();$actual=$bitmap.GetPixel($x,$y).ToArgb()
     if($actual -ne $expected){$mismatches++;if($samples.Count -lt 8){$samples+=@{x=$x;y=$y;expectedArgb=$expected;actualArgb=$actual}}}
    }
   }
  }
  return @{path=$resolved;sha256=$hash;geometry=$geometry;geometryMatches=$geometryMatches;rectangle=$rectangle;
   pixelsCompared=$(if($geometryMatches){$rectangle.width*$rectangle.height}else{0});mismatchedPixels=$(if($geometryMatches){$mismatches}else{$null});
   mismatchSamples=$samples;exactMatch=($geometryMatches -and $mismatches -eq 0)}
 }finally{$bitmap.Dispose()}
}
try{
 if($env:OS -ne 'Windows_NT' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:GITHUB_REPOSITORY -ne 'ShlomoCode/localsend'){throw 'Favorites gate runs only in the authorized fork Windows Actions environment'}
 Add-Type -AssemblyName System.Drawing
 foreach($reference in $references){
  $path=Join-Path $PSScriptRoot $reference.name
  $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  $report.references+=@{role=$reference.role;path=$path;expectedSha256=$reference.sha256;actualSha256=$actual}
  if($actual -cne $reference.sha256){throw "Untouched Favorites reference hash differs: $($reference.name)"}
 }
 $template=[System.Drawing.Bitmap]::new((Join-Path $PSScriptRoot $references[0].name))
 $report.templateGeometry=@{width=$template.Width;height=$template.Height}
 if($template.Width -ne 400 -or $template.Height -ne 493){throw 'Favorites template geometry differs from the reviewed 400x493 source'}
 if($Mode -eq 'Preflight'){
  $positive=CompareFavorites (Join-Path $PSScriptRoot $references[1].name);$positive.role='independent-positive-control';$positive.expectedMatch=$true
  $report.observations+=@($positive)
  $negative=CompareFavorites (Join-Path $PSScriptRoot $references[2].name);$negative.role='independent-negative-control';$negative.expectedMatch=$false
  $report.observations+=@($negative)
  if(!$positive.exactMatch -or !$negative.geometryMatches -or $negative.exactMatch){throw 'Favorites cloud preflight did not prove positive match and negative mismatch'}
 }else{
  if(!$ExpectedPid -or $ExpectedHwnd -le 0 -or $CapturePaths.Count -lt 1 -or $CapturePaths.Count -gt 2 -or $CapturePaths.Count -ne $ActionPaths.Count){throw 'Supply one or two capture/action pairs and the fresh original sender PID/HWND'}
  $releasePath=(Resolve-Path -LiteralPath $ReleaseReportPath).Path
  $release=Get-Content -LiteralPath $releasePath -Raw|ConvertFrom-Json
  $expectedArchive='a4ffb41fcbc3bd0f2f0cbd30b62a58d9a478eaf1da63eb410886886064abe70c'
  $report.releasePin=@{reportPath=$releasePath;reportSha256=(Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash.ToLowerInvariant();
   expectedRelease='v1.17.0';observedRelease=$release.release;expectedArchitecture='x86-64';observedArchitecture=$release.assetArchitecture;
   observedExecutableArchitecture=$release.executable.architecture;expectedArchiveSha256=$expectedArchive;observedArchiveSha256=$release.archive.sha256}
  if($release.release -cne 'v1.17.0' -or $release.assetArchitecture -cne 'x86-64' -or $release.executable.architecture -cne 'x86-64' -or $release.archive.sha256 -ine $expectedArchive){throw 'Runtime sender release/architecture/archive differs from the untouched Favorites template source'}
  Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class FavoritesGateIdentity {
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd,StringBuilder name,int count);
}
'@
  $livePid=0u;$liveClass=[Text.StringBuilder]::new(256)
  $isWindow=[FavoritesGateIdentity]::IsWindow([IntPtr]$ExpectedHwnd)
  [void][FavoritesGateIdentity]::GetWindowThreadProcessId([IntPtr]$ExpectedHwnd,[ref]$livePid)
  [void][FavoritesGateIdentity]::GetClassName([IntPtr]$ExpectedHwnd,$liveClass,256)
  $report.liveIdentity=@{utc=[DateTime]::UtcNow.ToString('o');hwnd=$ExpectedHwnd;isWindow=$isWindow;pid=$livePid;class=$liveClass.ToString();expectedPid=$ExpectedPid}
  if(!$isWindow -or $livePid -ne $ExpectedPid -or $liveClass.ToString() -cne 'FLUTTER_RUNNER_WIN32_WINDOW'){throw 'Live sender HWND/PID/class differs from the supplied original identity'}
  $seenCaptures=@();$seenActions=@()
  for($index=0;$index -lt $CapturePaths.Count;$index++){
   $capture=(Resolve-Path -LiteralPath $CapturePaths[$index]).Path
   $actionPath=(Resolve-Path -LiteralPath $ActionPaths[$index]).Path
   if($capture -in $seenCaptures -or $actionPath -in $seenActions){throw 'Runtime capture/action pairs must be distinct evidence files'}
   $seenCaptures+=@($capture);$seenActions+=@($actionPath)
   if($actionPath -ine ([IO.Path]::ChangeExtension($capture,$null)+'-action.json')){throw 'Capture and action evidence filenames are not paired'}
   $action=Get-Content -LiteralPath $actionPath -Raw|ConvertFrom-Json
   $binding=@{actionPath=$actionPath;actionSha256=(Get-FileHash -LiteralPath $actionPath -Algorithm SHA256).Hash.ToLowerInvariant();
    action=$action.action;actionUtc=$action.utc;observedPid=$action.appPid;observedHwnd=$action.window;expectedPid=$ExpectedPid;expectedHwnd=$ExpectedHwnd;
    matches=($action.action -in @('snapshot','click') -and $action.appPid -eq $ExpectedPid -and $action.window -eq $ExpectedHwnd)}
   $observation=CompareFavorites $capture;$observation.role='runtime-capture';$observation.expectedMatch=$true;$observation.binding=$binding
   $report.observations+=@($observation)
   if(!$binding.matches){throw 'Favorites screenshot action does not bind to the fresh original sender PID/HWND'}
   if(!$observation.exactMatch){throw 'Favorites interior differs from the exact reviewed positive panel'}
  }
 }
 $report.passed=$true
}catch{
 $report.error=$_.Exception.Message
}finally{
 if($null -ne $template){$template.Dispose()}
 $absoluteOutput=[IO.Path]::GetFullPath($OutputPath)
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($absoluteOutput))
 $report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $absoluteOutput
}
if(!$report.passed){throw "Favorites readiness gate failed; raw report retained at $OutputPath. $($report.error)"}
