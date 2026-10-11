# Keep BrowserStack Local, private uploads, and the controller in one hosted step.
param(
 [string]$BrowserStackLocalPath='C:/tmp/bs-local-bin/BrowserStackLocal.exe',
 [string]$EvidenceDirectory,
 [string]$BaselineUrl='https://github.com/localsend/localsend/releases/download/v1.14.0/LocalSend-1.14.0.apk'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if(-not $EvidenceDirectory) { $EvidenceDirectory=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) 'evidence/issue1461' }
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($name in @('BROWSERSTACK_USERNAME','BROWSERSTACK_ACCESS_KEY','BS_LOCAL_ID','RELAY_TOKEN','CLOUD_TRANSPORT_APK')) {
 if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required process environment variable missing: $name" }
}
foreach($file in @($BrowserStackLocalPath,$env:CLOUD_TRANSPORT_APK)) {
 if(-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'A required BrowserStack Local executable or helper APK is missing.' }
}
$private=Join-Path ([IO.Path]::GetTempPath()) ('issue1461-transfer-'+[Guid]::NewGuid().ToString('N'))
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
function Read-OfficialApkCompatibility {
 param([string]$ApkPath)
 $sdk=$env:ANDROID_HOME
 if(-not $sdk) { $sdk=$env:ANDROID_SDK_ROOT }
 if(-not $sdk) { throw 'Android SDK path is required for official APK manifest compatibility evidence.' }
 $aapt=Join-Path $sdk 'build-tools/35.0.0/aapt.exe'
 if(-not (Test-Path -LiteralPath $aapt -PathType Leaf)) { throw 'Installed Android build-tools 35.0.0 aapt is required for APK compatibility evidence.' }
 $rawPath=Join-Path $EvidenceDirectory 'original-android-apk-badging.txt'
 $stderrPath=Join-Path $EvidenceDirectory 'original-android-apk-badging.stderr.txt'
 & $aapt dump badging $ApkPath 1> $rawPath 2> $stderrPath
 if($LASTEXITCODE -ne 0) { throw 'aapt could not read the official APK; compatibility is unknown.' }
 $raw=Get-Content -LiteralPath $rawPath -Raw
 $packageLines=[regex]::Matches($raw,"(?m)^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'[^\r\n]*\r?$")
 $minLines=[regex]::Matches($raw,"(?m)^sdkVersion:'([0-9]+)'\r?$")
 $targetLines=[regex]::Matches($raw,"(?m)^targetSdkVersion:'([0-9]+)'\r?$")
 $abiLines=[regex]::Matches($raw,"(?m)^native-code:([^\r\n]+)\r?$")
 foreach($field in @('package','sdkVersion','targetSdkVersion','native-code')) {
  if([regex]::Matches($raw,('(?m)^'+[regex]::Escape($field)+':')).Count -ne 1) { throw "Official APK $field evidence is missing or ambiguous." }
 }
 if($packageLines.Count -ne 1 -or $minLines.Count -ne 1 -or $targetLines.Count -ne 1 -or $abiLines.Count -ne 1) {
  throw 'Official APK package, version, SDK or ABI evidence is missing or ambiguous; device selection is blocked.'
 }
 $package=$packageLines[0].Groups[1].Value; $versionName=$packageLines[0].Groups[3].Value
 if($package -ne 'org.localsend.localsend_app' -or $versionName -ne '1.14.0') { throw 'Downloaded APK identity does not match the official LocalSend 1.14.0 baseline.' }
 $minSdk=0; $targetSdk=0
 if(-not [int]::TryParse($minLines[0].Groups[1].Value,[ref]$minSdk) -or $minSdk -lt 1 -or
    -not [int]::TryParse($targetLines[0].Groups[1].Value,[ref]$targetSdk) -or $targetSdk -lt $minSdk) { throw 'Official APK numeric SDK requirements are invalid.' }
 $abiText=$abiLines[0].Groups[1].Value
 $abiMatches=[regex]::Matches($abiText,"'([a-zA-Z0-9_-]+)'")
 $abiRemainder=[regex]::Replace($abiText,"'([a-zA-Z0-9_-]+)'",'').Trim()
 $abis=@($abiMatches | ForEach-Object { $_.Groups[1].Value })
 if($abis.Count -eq 0 -or $abiRemainder -or @($abis | Select-Object -Unique).Count -ne $abis.Count) { throw 'Official APK native-code ABI evidence is missing or ambiguous.' }
 $compatibilityPath=Join-Path $EvidenceDirectory 'original-android-apk-compatibility.json'
 $compatibility=@{
  source=$BaselineUrl; sha256=(Get-FileHash $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant(); bytes=(Get-Item $ApkPath).Length
  tool='aapt dump badging'; buildToolsVersion='35.0.0'; package=$package; versionCode=$packageLines[0].Groups[2].Value; versionName=$versionName
  minSdk=$minSdk; targetSdk=$targetSdk; nativeCodeAbis=$abis; observedUtc=[DateTime]::UtcNow.ToString('o')
  rawEvidence=[IO.Path]::GetFileName($rawPath); stderrEvidence=[IO.Path]::GetFileName($stderrPath)
 }
 [IO.File]::WriteAllText($compatibilityPath,(ConvertTo-Json -Depth 5 $compatibility),[Text.UTF8Encoding]::new($false))
 $env:BASELINE_APK_MIN_SDK=[string]$minSdk
 $env:BASELINE_APK_TARGET_SDK=[string]$targetSdk
 $env:BASELINE_APK_COMPATIBILITY_PATH=$compatibilityPath
}
try {
 $baselinePath=Join-Path $private 'original-1.14.0.apk'
 Invoke-WebRequest $BaselineUrl -OutFile $baselinePath -TimeoutSec 120
 [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'original-android-apk.json'),(ConvertTo-Json @{ release='1.14.0'; sha256=(Get-FileHash $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant(); bytes=(Get-Item $baselinePath).Length; source=$BaselineUrl }))
 Read-OfficialApkCompatibility -ApkPath $baselinePath
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
 $env:RELAY_APP=Upload-App -ApkPath $env:CLOUD_TRANSPORT_APK -Label 'relay'
 $env:BASELINE_APP=Upload-App -ApkPath $baselinePath -Label 'baseline'
 $env:TRANSFER_EVIDENCE_DIRECTORY=$EvidenceDirectory
 & node (Join-Path $PSScriptRoot 'control.mjs')
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
 foreach($name in @('HELPER_APP','RELAY_APP','BASELINE_APP','BASELINE_APK_MIN_SDK','BASELINE_APK_TARGET_SDK','BASELINE_APK_COMPATIBILITY_PATH')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
 if(Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
 # Remove this single-run capability APK after its private upload and session use.
 if(Test-Path -LiteralPath $env:CLOUD_TRANSPORT_APK) { Remove-Item -LiteralPath $env:CLOUD_TRANSPORT_APK -Force }
}
exit $exitCode

