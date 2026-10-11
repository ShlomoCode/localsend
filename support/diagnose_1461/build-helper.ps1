$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$sdk=$env:ANDROID_HOME
if(-not $sdk){$sdk=$env:ANDROID_SDK_ROOT}
if(-not $sdk -or -not $env:RELAY_TOKEN){throw 'Android SDK and private relay token required'}
& (Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager.bat') 'platforms;android-35' 'build-tools;35.0.0'
if($LASTEXITCODE){throw 'SDK setup failed'}
$androidJar=Join-Path $sdk 'platforms/android-35/android.jar'
$tools=Join-Path $sdk 'build-tools/35.0.0'
$temp=Join-Path $env:RUNNER_TEMP 'helper1461'
foreach($name in @('classes','dex','assets')){New-Item -ItemType Directory -Force (Join-Path $temp $name)|Out-Null}
$source=Join-Path $root 'support/cloud_transport/android'
[IO.File]::WriteAllText((Join-Path $temp 'assets/config.json'),(ConvertTo-Json -Compress @{endpoint='http://bs-local.com:8080';token=$env:RELAY_TOKEN;transport='legacy'}))
& javac -source 8 -target 8 -classpath $androidJar -d (Join-Path $temp 'classes') @(Get-ChildItem $source -Filter '*.java'|ForEach-Object FullName)
if($LASTEXITCODE){throw 'Java helper compile failed'}
& (Join-Path $tools 'd8.bat') --lib $androidJar --min-api 26 --output (Join-Path $temp 'dex') @(Get-ChildItem (Join-Path $temp 'classes') -Recurse -Filter '*.class'|ForEach-Object FullName)
if($LASTEXITCODE){throw 'DEX failed'}
$unsigned=Join-Path $temp 'unsigned.apk'
& (Join-Path $tools 'aapt.exe') package -f -M (Join-Path $source 'AndroidManifest.xml') -I $androidJar -A (Join-Path $temp 'assets') -F $unsigned
if($LASTEXITCODE){throw 'APK packaging failed'}
& jar uf $unsigned -C (Join-Path $temp 'dex') classes.dex
if($LASTEXITCODE){throw 'DEX insertion failed'}
& (Join-Path $tools 'zipalign.exe') -f 4 $unsigned (Join-Path $temp 'aligned.apk')
if($LASTEXITCODE){throw 'APK alignment failed'}
& keytool -genkeypair -keystore (Join-Path $temp 'debug.jks') -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 2 -dname 'CN=Issue1461 diagnostic'
if($LASTEXITCODE){throw 'Diagnostic key creation failed'}
$apk=Join-Path $temp 'helper.apk'
& (Join-Path $tools 'apksigner.bat') sign --ks (Join-Path $temp 'debug.jks') --ks-pass pass:android --out $apk (Join-Path $temp 'aligned.apk')
if($LASTEXITCODE){throw 'APK signing failed'}
& (Join-Path $tools 'apksigner.bat') verify $apk
if($LASTEXITCODE){throw 'APK signature check failed'}
[IO.File]::AppendAllText($env:GITHUB_ENV,"CLOUD_TRANSPORT_APK=$apk`n")
Remove-Item (Join-Path $temp 'assets/config.json')
