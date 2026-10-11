# Keep BrowserStack Local, private uploads, and the controller in one hosted step.
param(
 [string]$BrowserStackLocalPath='C:/tmp/bs-local-bin/BrowserStackLocal.exe',
 [string]$EvidenceDirectory,
 [string]$BaselineUrl='https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-android-arm64v8.apk'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if(-not $EvidenceDirectory) { $EvidenceDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) 'evidence/windows-transfer' }
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($name in @('BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','BS_LOCAL_ID','RELAY_TOKEN','FIXTURE_3556_APK','CLOUD_TRANSPORT_APK')) {
 if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required process environment variable missing: $name" }
}
foreach($file in @($BrowserStackLocalPath,$env:FIXTURE_3556_APK,$env:CLOUD_TRANSPORT_APK)) {
 if(-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'A required BrowserStack Local executable or helper APK is missing.' }
}
$private=Join-Path ([IO.Path]::GetTempPath()) ('issue3556-transfer-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($private)
$local=$null; $stdoutStream=$null; $stderrStream=$null; $copyTasks=@(); $exitCode=1
$secretValues=@($env:BROWSERSTACK_USERNAME,$env:BROWSERSTACK_ACCESS_KEY,$env:RELAY_TOKEN)
function Redact([string]$Text) {
 foreach($value in $secretValues) { if($value) { $Text=$Text.Replace($value,'[redacted]') } }
 return $Text
}
function Upload-App {
 param([string]$ApkPath,[string]$RemoteUrl,[string]$Label)
 # Supply authentication through curl's stdin config, not its process arguments or logs.
 $credential=$env:BROWSERSTACK_USERNAME+':'+$env:BROWSERSTACK_ACCESS_KEY
 $escaped=$credential.Replace('\','\\').Replace('"','\"')
 $config='user = "'+$escaped+'"'
 $responsePath=Join-Path $private ($Label+'-upload.json')
 $curlArgs=@('--fail','--silent','--show-error','--max-time','300','--config','-','https://api-cloud.browserstack.com/app-automate/upload')
 if($ApkPath) { $curlArgs+=@('--form',('file=@'+$ApkPath)) }
 else { $curlArgs+=@('--form',('url='+$RemoteUrl)) }
 $curlArgs+=@('--output',$responsePath)
 $config | & curl.exe @curlArgs
 if($LASTEXITCODE -ne 0) { throw "$Label private upload failed; no response or app reference is published." }
 $response=Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
 if(-not $response.app_url -or $response.app_url -notmatch '^bs://[a-zA-Z0-9]+$') { throw "$Label upload did not return an app reference." }
 $script:secretValues+=[string]$response.app_url
 return [string]$response.app_url
}
try {
 $localLog=Join-Path $private 'local.log'
 $stdoutPath=Join-Path $private 'local.stdout.txt'; $stderrPath=Join-Path $private 'local.stderr.txt'
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=[IO.Path]::GetFullPath($BrowserStackLocalPath)
 $start.UseShellExecute=$false; $start.CreateNoWindow=$true
 $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
 foreach($argument in @('--key',$env:BROWSERSTACK_ACCESS_KEY,'--local-identifier',$env:BS_LOCAL_ID,'--force-local','--only-automate','--verbose','3','--log-file',$localLog)) {
  [void]$start.ArgumentList.Add($argument)
 }
 $local=[Diagnostics.Process]::new(); $local.StartInfo=$start
 if(-not $local.Start()) { throw 'Could not start the owned BrowserStack Local process.' }
 $stdoutStream=[IO.FileStream]::new($stdoutPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
 $stderrStream=[IO.FileStream]::new($stderrPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite,1,[IO.FileOptions]::Asynchronous)
 $copyTasks=@($local.StandardOutput.BaseStream.CopyToAsync($stdoutStream),$local.StandardError.BaseStream.CopyToAsync($stderrStream))
 $deadline=[DateTime]::UtcNow.AddSeconds(120); $ready=$false
 do {
  if($local.HasExited) { throw 'Owned BrowserStack Local exited before readiness; inspect redacted logs.' }
  $text=''
  foreach($log in @($localLog,$stdoutPath,$stderrPath)) {
   if(Test-Path -LiteralPath $log) {
    try {
     $stream=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
     $reader=[IO.StreamReader]::new($stream)
     try { $text+=$reader.ReadToEnd() } finally { $reader.Dispose() }
    } catch {}
   }
  }
  $ready=$text -match '(?i)You can now access your local|Local Testing successfully connected|BrowserStackLocal is connected|Local connection established|Connected to BrowserStack'
  if(-not $ready) { Start-Sleep -Milliseconds 500 }
 } until($ready -or [DateTime]::UtcNow -ge $deadline)
 if(-not $ready) { throw 'Owned BrowserStack Local readiness exceeded 120 seconds.' }
 [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'local-ready.json'),(ConvertTo-Json @{
  ownedProcessId=$local.Id; localIdentifier=$env:BS_LOCAL_ID; readyUtc=[DateTime]::UtcNow.ToString('o')
  method='Foreground owned native process readiness message; same step lifetime'
 }),[Text.UTF8Encoding]::new($false))
 $env:HELPER_APP=Upload-App -ApkPath $env:FIXTURE_3556_APK -Label 'fixture'
 $env:RELAY_APP=Upload-App -ApkPath $env:CLOUD_TRANSPORT_APK -Label 'relay'
 $env:BASELINE_APP=Upload-App -RemoteUrl $BaselineUrl -Label 'baseline'
 $env:TRANSFER_EVIDENCE_DIRECTORY=$EvidenceDirectory
 & node (Join-Path $PSScriptRoot 'windows-transfer-control.mjs')
 $exitCode=$LASTEXITCODE
 if($exitCode -ne 0) { throw 'Actual app-to-app controller failed; inspect the preserved evidence.' }
} catch {
 [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'step-error.txt'),(Redact $_.Exception.ToString()),[Text.UTF8Encoding]::new($false))
 $exitCode=1
} finally {
 # Terminate only the child created by this invocation, never unrelated tunnels or device sessions.
 if($local -and -not $local.HasExited) {
  try { $local.Kill($true); [void]$local.WaitForExit(10000) } catch {
   [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'local-cleanup-error.txt'),(Redact $_.Exception.ToString()),[Text.UTF8Encoding]::new($false))
  }
 }
 foreach($task in $copyTasks) { try { [void]$task.Wait(5000) } catch {} }
 if($stdoutStream) { $stdoutStream.Dispose() }; if($stderrStream) { $stderrStream.Dispose() }
 foreach($name in @('local.log','local.stdout.txt','local.stderr.txt')) {
  $source=Join-Path $private $name
  if(Test-Path -LiteralPath $source) {
   [IO.File]::WriteAllText((Join-Path $EvidenceDirectory $name),(Redact ([IO.File]::ReadAllText($source))),[Text.UTF8Encoding]::new($false))
  }
 }
 foreach($name in @('HELPER_APP','RELAY_APP','BASELINE_APP')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
 if(Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
 # Remove this single-run capability APK after its private upload and session use.
 if(Test-Path -LiteralPath $env:CLOUD_TRANSPORT_APK) { Remove-Item -LiteralPath $env:CLOUD_TRANSPORT_APK -Force }
}
exit $exitCode

