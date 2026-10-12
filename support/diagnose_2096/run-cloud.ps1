$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:RUNNER_TEMP ('issue2096-private-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($private)
[void][IO.Directory]::CreateDirectory('evidence/issue2096')
$local=$null;$exitCode=1
$secrets=@($env:BROWSERSTACK_USERNAME,$env:BROWSERSTACK_ACCESS_KEY,$env:RELAY_TOKEN)
function Redact([string]$Text){foreach($secret in $secrets){if($secret){$Text=$Text.Replace($secret,'[redacted]')}};return $Text}
function Save-Json([string]$Name,$Object){[IO.File]::WriteAllText((Join-Path 'evidence/issue2096' $Name),(ConvertTo-Json $Object -Depth 20),[Text.UTF8Encoding]::new($false))}
function Checked([string]$Tool,[string[]]$Arguments){& $Tool @Arguments;if($LASTEXITCODE -ne 0){throw "Cloud source/setup command failed: $Tool"}}
function Upload-App([string]$Apk,[string]$Label){
 $responsePath=Join-Path $private ($Label+'-upload.json')
 $credential=($env:BROWSERSTACK_USERNAME+':'+$env:BROWSERSTACK_ACCESS_KEY).Replace('\','\\').Replace('"','\"')
 ('user = "'+$credential+'"') | & curl.exe --fail --silent --show-error --max-time 180 --config - https://api-cloud.browserstack.com/app-automate/upload --form "file=@$Apk" --output $responsePath
 if($LASTEXITCODE -ne 0){throw "Private upload failed: $Label"}
 $app=(Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json).app_url
 if($app -notmatch '^bs://[a-zA-Z0-9]+$'){throw 'Invalid private uploaded-app reference'}
 $script:secrets+=$app;return $app
}
try{
 if($env:GITHUB_REPOSITORY -ne 'ShlomoCode/localsend' -or $env:GITHUB_SHA -ne $env:EXPECTED_HEAD){throw 'Only exact frozen fork head is admitted'}
 if($env:GITHUB_RUN_ATTEMPT -ne '1'){throw 'One-session admission cannot be reused by a workflow rerun'}
 $env:RELAY_TOKEN=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant();$secrets+=$env:RELAY_TOKEN;Write-Host ('::add-mask::'+$env:RELAY_TOKEN)
 foreach($module in @('controller.mjs','android-scenario.mjs')){Checked 'node' @('--check',"support/diagnose_2096/$module")}
 Checked 'node' @('--check','support/cloud_transport/relay.mjs')
 foreach($script in @('windows_receiver.ps1','build-helper.ps1','run-cloud.ps1')){
  $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PWD "support/diagnose_2096/$script"),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ($errors|Out-String)}
 }
 $receiver=Get-Content support/diagnose_2096/windows_receiver.ps1 -Raw
 foreach($worker in [regex]::Matches($receiver,"(?s)\[IO\.File\]::WriteAllText\(\`$scriptPath,@'\r?\n(.*?)\r?\n'@")){
  $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($worker.Groups[1].Value,[ref]$tokens,[ref]$errors);if($errors.Count){throw ($errors|Out-String)}
 }
 ./support/diagnose_2096/build-helper.ps1
 $android=Join-Path $private 'official-1.16.1-arm64.apk'
 Invoke-WebRequest https://github.com/localsend/localsend/releases/download/v1.16.1/LocalSend-1.16.1-android-arm64v8.apk -OutFile $android
 $apkHash=(Get-FileHash $android -Algorithm SHA256).Hash.ToLowerInvariant()
 if((Get-Item $android).Length -ne 17202055 -or $apkHash -ne 'f575c642d1c9ee37475bf0d30e138d2672e0857216addaebc327041339aeb064'){throw 'Official Android release bytes changed'}
 $tools=$env:DIAG2096_BUILD_TOOLS
 $signature=& (Join-Path $tools 'apksigner.bat') verify --print-certs $android
 if($LASTEXITCODE -ne 0){throw 'Official APK signature verification failed'}
 $signer=[regex]::Match(($signature -join "`n"),'Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]{64})').Groups[1].Value.ToLowerInvariant()
 if(-not $signer){throw 'Official APK signer certificate digest unavailable'}
 $env:EXPECTED_ANDROID_SIGNER_SHA256=$signer
 $badging=& (Join-Path $tools 'aapt.exe') dump badging $android
 if($LASTEXITCODE -ne 0 -or ($badging -join "`n") -notmatch "package: name='org.localsend.localsend_app'.*versionName='1\.16\.1'"){throw 'Official APK package/version identity mismatch'}
 Save-Json 'official-android-identity.json' @{assetId=204138402;bytes=17202055;sha256=$apkHash;signerSha256=$signer;signature=$signature;badging=$badging}
 $zip=Join-Path $private 'official-windows.zip'
 Invoke-WebRequest https://github.com/localsend/localsend/releases/download/v1.16.1/LocalSend-1.16.1-windows-x86-64.zip -OutFile $zip
 $zipHash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
 if((Get-Item $zip).Length -ne 18562913 -or $zipHash -ne '4d9bd4639476c0e4d00dd9da30b7ca78a1dc6e3dafc69e2e8862fdafcc23e163'){throw 'Official Windows release bytes changed'}
 $release=Join-Path $private 'release';Expand-Archive $zip $release
 $executables=@(Get-ChildItem $release -Recurse -Filter localsend_app.exe)
 if($executables.Count -ne 1){throw 'Official Windows archive executable ambiguous'}
 $env:WINDOWS_EXECUTABLE=$executables[0].FullName
 Save-Json 'official-windows-identity.json' @{assetId=204138431;bytes=18562913;sha256=$zipHash;executableHash=(Get-FileHash $env:WINDOWS_EXECUTABLE).Hash;fileVersion=$executables[0].VersionInfo.FileVersion;productVersion=$executables[0].VersionInfo.ProductVersion}
 $env:HELPER_APP=Upload-App $env:FIXTURE_2096_APK 'fixture'
 $env:RELAY_APP=Upload-App $env:CLOUD_TRANSPORT_APK 'transport'
 $env:BASELINE_APP=Upload-App $android 'official'
 foreach($name in @('HELPER_APP','RELAY_APP','BASELINE_APP')){Write-Host ('::add-mask::'+[Environment]::GetEnvironmentVariable($name))}
 $localZip=Join-Path $private 'local.zip';Invoke-WebRequest https://local-downloads.browserstack.com/BrowserStackLocal-win32.zip -OutFile $localZip
 $localDir=Join-Path $private 'local';Expand-Archive $localZip $localDir
 $localExe=Join-Path $localDir 'BrowserStackLocal.exe';$localLog=Join-Path $private 'local.log'
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$localExe;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 foreach($arg in @('--key',$env:BROWSERSTACK_ACCESS_KEY,'--local-identifier',$env:BS_LOCAL_ID,'--force-local','--only-automate','--log-file',$localLog)){[void]$start.ArgumentList.Add($arg)}
 $local=[Diagnostics.Process]::new();$local.StartInfo=$start;if(-not $local.Start()){throw 'Owned BrowserStackLocal startup failed'}
 $end=[DateTime]::UtcNow.AddSeconds(120);$ready=$false
 do{if($local.HasExited){throw 'Owned BrowserStackLocal exited'}
  if(Test-Path $localLog){$ready=(Get-Content $localLog -Raw) -match '(?i)You can now access your local|Local Testing successfully connected|Local connection established|Connected to BrowserStack'}
  if(-not $ready){Start-Sleep -Milliseconds 500}
 }until($ready -or [DateTime]::UtcNow -ge $end)
 if(-not $ready){throw 'Owned BrowserStackLocal readiness deadline'}
 Save-Json 'local-ready.json' @{ready=$true;pid=$local.Id;localIdentifier=$env:BS_LOCAL_ID;sha256=(Get-FileHash $localExe).Hash;utc=[DateTime]::UtcNow.ToString('o')}
 & node support/diagnose_2096/controller.mjs;$exitCode=$LASTEXITCODE
}catch{
 [IO.File]::WriteAllText('evidence/issue2096/setup-error.txt',(Redact $_.Exception.ToString()),[Text.UTF8Encoding]::new($false))
}finally{
 if($local -and -not $local.HasExited){try{$local.Kill($true);[void]$local.WaitForExit(5000)}catch{}}
 if(Test-Path (Join-Path $private 'local.log')){[IO.File]::WriteAllText('evidence/issue2096/local.log',(Redact (Get-Content (Join-Path $private 'local.log') -Raw)),[Text.UTF8Encoding]::new($false))}
 foreach($name in @('CLOUD_TRANSPORT_APK','FIXTURE_2096_APK')){$file=[Environment]::GetEnvironmentVariable($name);if($file -and (Test-Path $file)){Remove-Item -LiteralPath $file -Force}}
 foreach($name in @('HELPER_APP','RELAY_APP','BASELINE_APP','RELAY_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
 Remove-Item -LiteralPath $private -Recurse -Force
}
exit $exitCode
