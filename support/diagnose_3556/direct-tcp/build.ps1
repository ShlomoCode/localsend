$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if (-not $env:GITHUB_ENV -or -not $env:TCP_TOKEN -or -not $env:TCP_MARKER) { throw 'Cloud job environment required.' }
$private=Join-Path $env:RUNNER_TEMP ('direct-tcp-'+[Guid]::NewGuid().ToString('N'))
foreach ($dir in @('classes','dex','assets')) { [void][IO.Directory]::CreateDirectory((Join-Path $private $dir)) }
$sdk=$env:ANDROID_HOME
if (-not $sdk) { $sdk=$env:ANDROID_SDK_ROOT }
function Checked([string]$tool,[string[]]$arguments) { & $tool @arguments | Out-Host; if ($LASTEXITCODE -ne 0) { throw "Tool failed: $tool" } }
Checked (Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager.bat') @('platforms;android-35','build-tools;35.0.0',('--sdk_root='+$sdk))
$tools=Join-Path $sdk 'build-tools/35.0.0'; $android=Join-Path $sdk 'platforms/android-35/android.jar'
$config=Join-Path $private 'assets/config.json'
[IO.File]::WriteAllText($config,(ConvertTo-Json -Compress @{host='bs-local.com';token=$env:TCP_TOKEN;marker=$env:TCP_MARKER}),[Text.UTF8Encoding]::new($false))
try {
 Checked (Join-Path $env:JAVA_HOME 'bin/javac.exe') @('-source','8','-target','8','-classpath',$android,'-d',(Join-Path $private 'classes'),(Join-Path $PSScriptRoot 'MainActivity.java'))
 $classes=@(Get-ChildItem (Join-Path $private 'classes') -Recurse -Filter '*.class' | ForEach-Object FullName)
 Checked (Join-Path $tools 'd8.bat') (@('--lib',$android,'--min-api','29','--output',(Join-Path $private 'dex'))+$classes)
 $unsigned=Join-Path $private 'unsigned.apk'; $aligned=Join-Path $private 'aligned.apk'; $apk=Join-Path $private 'helper.apk'; $key=Join-Path $private 'key.jks'
 Checked (Join-Path $tools 'aapt.exe') @('package','-f','-M',(Join-Path $PSScriptRoot 'AndroidManifest.xml'),'-I',$android,'-A',(Join-Path $private 'assets'),'-F',$unsigned)
 Checked (Join-Path $env:JAVA_HOME 'bin/jar.exe') @('uf',$unsigned,'-C',(Join-Path $private 'dex'),'classes.dex')
 Checked (Join-Path $tools 'zipalign.exe') @('-f','4',$unsigned,$aligned)
 Checked (Join-Path $env:JAVA_HOME 'bin/keytool.exe') @('-genkeypair','-keystore',$key,'-alias','diagnostic','-storepass','android','-keypass','android','-keyalg','RSA','-validity','2','-dname','CN=Temporary direct TCP diagnostic')
 Checked (Join-Path $tools 'apksigner.bat') @('sign','--ks',$key,'--ks-pass','pass:android','--out',$apk,$aligned)
 Checked (Join-Path $tools 'apksigner.bat') @('verify',$apk)
 [IO.File]::AppendAllText($env:GITHUB_ENV,"TCP_HELPER_APK=$apk`n",[Text.UTF8Encoding]::new($false))
} finally { Remove-Item -LiteralPath $config -Force }
