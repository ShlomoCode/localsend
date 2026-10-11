$ErrorActionPreference = 'Stop'
$output = 'C:\tmp\helper'
New-Item -ItemType Directory -Force "$output/classes", "$output/dex", "$output/assets" | Out-Null
if (-not $env:ANDROID_HOME -or -not (Test-Path "$env:ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager.bat")) {
  $env:ANDROID_HOME = 'C:\tmp\android-sdk'
  New-Item -ItemType Directory -Force "$env:ANDROID_HOME/cmdline-tools" | Out-Null
  Invoke-WebRequest https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip -OutFile C:\tmp\cmdline.zip
  Expand-Archive C:\tmp\cmdline.zip C:\tmp\cmdline -Force
  Move-Item C:\tmp\cmdline\cmdline-tools "$env:ANDROID_HOME/cmdline-tools/latest" -Force
}
1..100 | ForEach-Object { 'y' } | & "$env:ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager.bat" 'platforms;android-35' 'build-tools;35.0.0'
if ($LASTEXITCODE -ne 0) { throw 'Android SDK preparation failed' }
@{endpoint='http://bs-local.com:8080';token=$env:RELAY_TOKEN} | ConvertTo-Json -Compress | Set-Content "$output/assets/config.json"
$source = @(Get-ChildItem support/cloud_transport/android -Filter '*.java' | ForEach-Object FullName)
& javac -source 8 -target 8 -classpath "$env:ANDROID_HOME/platforms/android-35/android.jar" -d "$output/classes" @source
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
$classes = @(Get-ChildItem "$output/classes/org/localsend/cloudtransport" -Filter '*.class' | ForEach-Object FullName)
& "$env:ANDROID_HOME/build-tools/35.0.0/d8.bat" --lib "$env:ANDROID_HOME/platforms/android-35/android.jar" --min-api 26 --output "$output/dex" @classes
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }
& "$env:ANDROID_HOME/build-tools/35.0.0/aapt.exe" package -f -M support/cloud_transport/android/AndroidManifest.xml -I "$env:ANDROID_HOME/platforms/android-35/android.jar" -A "$output/assets" -F "$output/unsigned.apk"
if ($LASTEXITCODE -ne 0) { throw 'aapt failed' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open("$output/unsigned.apk", [System.IO.Compression.ZipArchiveMode]::Update)
try { [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, "$output/dex/classes.dex", 'classes.dex') | Out-Null } finally { $archive.Dispose() }
& keytool -genkeypair -keystore "$output/debug.jks" -alias androiddebugkey -storepass android -keypass android -keyalg RSA -validity 2 -dname 'CN=Cloud diagnostic'
& "$env:ANDROID_HOME/build-tools/35.0.0/apksigner.bat" sign --ks "$output/debug.jks" --ks-pass pass:android --out "$output/cloud-transport-helper.apk" "$output/unsigned.apk"
if ($LASTEXITCODE -ne 0) { throw 'APK signing failed' }
& "$env:ANDROID_HOME/build-tools/35.0.0/apksigner.bat" verify "$output/cloud-transport-helper.apk"
if ($LASTEXITCODE -ne 0) { throw 'APK verification failed' }
