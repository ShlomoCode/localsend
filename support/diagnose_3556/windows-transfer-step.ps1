# Keep BrowserStack Local, private uploads, and the controller in one hosted step.
param(
 [string]$BrowserStackLocalPath='C:/tmp/bs-local-bin/BrowserStackLocal.exe',
 [string]$EvidenceDirectory,
 [string]$BaselineUrl='https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-1.18.2-android-arm64v8.apk'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$coldFileDiagnostic=$env:COLD_FILE_DIAGNOSTIC -eq '1'
$coldShareDiagnostic=$env:COLD_SHARE_DIAGNOSTIC -eq '1'
$coldDiagnostic=$coldFileDiagnostic -or $coldShareDiagnostic
$historicalShareReference=$coldShareDiagnostic -and -not [string]::IsNullOrWhiteSpace($env:COLD_SHARE_HISTORICAL_HELPER_APP)
if(-not $EvidenceDirectory) { $EvidenceDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) 'evidence/windows-transfer' }
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$required=@('BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY')
if(-not $historicalShareReference){$required+=@('FIXTURE_3556_APK')}
if($coldDiagnostic){$required+=@('COLD_JOB_DEADLINE_UTC')}
else{$required+=@('BS_LOCAL_ID','RELAY_TOKEN','CLOUD_TRANSPORT_APK')}
foreach($name in $required) {
 if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required process environment variable missing: $name" }
}
$requiredFiles=@()
if(-not $historicalShareReference){$requiredFiles+=@($env:FIXTURE_3556_APK)}
if(-not $coldDiagnostic){$requiredFiles+=@($BrowserStackLocalPath,$env:CLOUD_TRANSPORT_APK)}
foreach($file in $requiredFiles) {
 if(-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'A required BrowserStack Local executable or helper APK is missing.' }
}
$private=Join-Path ([IO.Path]::GetTempPath()) ('issue3556-transfer-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($private)
$local=$null; $stdoutStream=$null; $stderrStream=$null; $copyTasks=@(); $exitCode=1
$secretValues=@($env:BROWSERSTACK_USERNAME,$env:BROWSERSTACK_ACCESS_KEY,$env:RELAY_TOKEN,$env:COLD_SHARE_HISTORICAL_HELPER_APP)
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
 if($coldDiagnostic){
  foreach($module in @('windows-transfer-control.mjs','cold-file-scenario.mjs','cold-share-scenario.mjs')){
   & node --check (Join-Path $PSScriptRoot $module)
   if($LASTEXITCODE -ne 0){throw "Syntax failed before provider upload: $module"}
  }
  if(($coldFileDiagnostic -and $coldShareDiagnostic) -or $env:LARGE_TRANSFER_DIAGNOSTIC -eq '1' -or $env:MODERATE_TRANSFER_CONTROL -eq '1' -or $env:SHARE_AFTER_CONTROL -eq '1'){throw 'Cold File rejects transfer and Share controls before provider upload.'}
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'cold-workflow-binding.json'),(ConvertTo-Json @{
   scenario=$(if($coldShareDiagnostic){'cold-share-onset'}else{'cold-file-onset'}); fixtureOnly=$true; browserStackLocal=$false; preWindowTransferControl=$false
   syntaxChecked=@('windows-transfer-control.mjs','cold-file-scenario.mjs','cold-share-scenario.mjs'); sourceCommit=$env:GITHUB_SHA
   cleanupAgeMinutes=25; artifactRetentionMinutes=5; workflowMinutes=45; deadlineUtc=$env:COLD_JOB_DEADLINE_UTC; requiredMinutesBeforeSessionPost=30
   outcomeGate='First touch and full ten-minute onset coverage remain unverified until original decoded video frames align with native input/log evidence.'
  }),[Text.UTF8Encoding]::new($false))
 }else{
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
 }
 if($coldShareDiagnostic -and -not $historicalShareReference){
  if((Get-Item -LiteralPath $env:FIXTURE_3556_APK).Length -ne 24984 -or (Get-FileHash -LiteralPath $env:FIXTURE_3556_APK -Algorithm SHA256).Hash.ToLowerInvariant() -ne '1064d8872a88e33def446c895c76f2da1f6df5f0d0f4ee7c00992d17414843af'){throw 'Historical helper APK unavailable or identity differs; no session allocation.'}
  $archive=[IO.Compression.ZipFile]::OpenRead($env:FIXTURE_3556_APK)
  try{
   $seed=$archive.GetEntry('assets/seed.mp4')
   if(-not $seed -or $seed.Length -ne 7355){throw 'Historical embedded seed missing or wrong size.'}
   $seedStream=$seed.Open();$sha=[Security.Cryptography.SHA256]::Create()
   try{$seedHash=[Convert]::ToHexString($sha.ComputeHash($seedStream)).ToLowerInvariant()}finally{$seedStream.Dispose();$sha.Dispose()}
   if($seedHash -ne 'a5b810580805d9ef75e40d4dc9f3088fcaacd67fa48680019778587af1170a33'){throw 'Historical embedded seed differs; no session allocation.'}
  }finally{$archive.Dispose()}
 }
 if($historicalShareReference){
  $env:HELPER_APP=$env:COLD_SHARE_HISTORICAL_HELPER_APP
  $seedHash='a5b810580805d9ef75e40d4dc9f3088fcaacd67fa48680019778587af1170a33'
 }else{$env:HELPER_APP=Upload-App -ApkPath $env:FIXTURE_3556_APK -Label 'fixture'}
 if($coldShareDiagnostic){
  $referenceBytes=[Text.Encoding]::UTF8.GetBytes($env:HELPER_APP);$sha=[Security.Cryptography.SHA256]::Create()
  try{$referenceHash=[Convert]::ToHexString($sha.ComputeHash($referenceBytes)).ToLowerInvariant()}finally{$sha.Dispose()}
  if($historicalShareReference -and $referenceHash -ne '35b26d081e501726490aba415889ac6eb52f8220c86b053a2a01dc5dc276cfe3'){throw 'Configured historical helper reference differs from admitted provenance binding.'}
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'cold-share-helper.json'),(ConvertTo-Json @{
   apkSha256='1064d8872a88e33def446c895c76f2da1f6df5f0d0f4ee7c00992d17414843af';apkBytes=24984
   seedSha256=$seedHash;seedBytes=7355;uploadReferenceSha256=$referenceHash;uploadAccepted=(-not $historicalShareReference)
   uploadUtc=$(if($historicalShareReference){'2026-10-12T00:15:47Z'}else{[DateTime]::UtcNow.ToString('o')})
   runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT;route=$(if($historicalShareReference){'historical-private-reference'}else{'verified-local-apk-upload'})
   provenance=$(if($historicalShareReference){'Root-admitted build receipt -> immutable upload step -> prior session metadata -> authenticated recent app record; local APK, raw upload response, and server-side binary hash unavailable'}else{'Exact local APK and embedded seed verified before supported private upload'})
   fixtureByteEquality='Recipe identity only; prior 16GB file/hash unavailable'
  }),[Text.UTF8Encoding]::new($false))
 }
 if(-not $coldDiagnostic){$env:RELAY_APP=Upload-App -ApkPath $env:CLOUD_TRANSPORT_APK -Label 'relay'}
 if($coldDiagnostic -or ($env:RELAY_TRANSPORT -and $env:RELAY_TRANSPORT -ne 'legacy')){
  $baselinePath=Join-Path $private 'original-1.18.2-arm64.apk'
  Invoke-WebRequest $BaselineUrl -OutFile $baselinePath -TimeoutSec 120
  $baselineHash=(Get-FileHash $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if($baselineHash -ne '82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3'){throw 'Original Android release APK SHA-256 differs; no session is created.'}
  [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'original-android-apk.json'),(ConvertTo-Json @{
   release='1.18.2'; architecture='arm64v8'; sha256=$baselineHash; bytes=(Get-Item $baselinePath).Length
   provenance='Original downloaded release APK verified before private file upload; no build or modification'
  }),[Text.UTF8Encoding]::new($false))
  $env:BASELINE_APP=Upload-App -ApkPath $baselinePath -Label 'baseline'
 }else{$env:BASELINE_APP=Upload-App -RemoteUrl $BaselineUrl -Label 'baseline'}
 if($coldShareDiagnostic -and -not $historicalShareReference){
  if((Get-Item -LiteralPath $env:FIXTURE_3556_APK).Length -ne 24984 -or (Get-FileHash -LiteralPath $env:FIXTURE_3556_APK -Algorithm SHA256).Hash.ToLowerInvariant() -ne '1064d8872a88e33def446c895c76f2da1f6df5f0d0f4ee7c00992d17414843af'){throw 'Historical local helper bytes changed before controller admission.'}
  $receiptPath=Join-Path $EvidenceDirectory 'cold-share-helper.json';$receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
  $receipt | Add-Member -NotePropertyName prePostIdentityUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
  $receipt | Add-Member -NotePropertyName localApkVerifiedBeforeController -NotePropertyValue $true
  [IO.File]::WriteAllText($receiptPath,(ConvertTo-Json $receipt),[Text.UTF8Encoding]::new($false))
 }
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
 if($env:CLOUD_TRANSPORT_APK -and (Test-Path -LiteralPath $env:CLOUD_TRANSPORT_APK)) { Remove-Item -LiteralPath $env:CLOUD_TRANSPORT_APK -Force }
}
exit $exitCode

