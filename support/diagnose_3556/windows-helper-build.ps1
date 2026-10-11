# Build the fixture and private relay APKs on a hosted Windows runner.
param(
 [Parameter(Mandatory=$true)][string]$VideoSeedPath,
 [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
 [string]$EvidenceDirectory,
 [string]$AndroidSdkRoot = $env:ANDROID_HOME,
 [string]$RelayEndpoint = 'http://bs-local.com:8080',
 [string]$FfmpegPath = 'ffmpeg',
 [string]$FfprobePath = 'ffprobe'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
$VideoSeedPath=[IO.Path]::GetFullPath($VideoSeedPath)
if(-not $EvidenceDirectory) { $EvidenceDirectory=Join-Path $RepositoryRoot 'evidence/windows-helper-build' }
$EvidenceDirectory=[IO.Path]::GetFullPath($EvidenceDirectory)
if(-not $AndroidSdkRoot) { $AndroidSdkRoot=$env:ANDROID_SDK_ROOT }
if(-not $AndroidSdkRoot -or -not (Test-Path -LiteralPath $AndroidSdkRoot -PathType Container)) { throw 'Set ANDROID_HOME or pass -AndroidSdkRoot for the hosted Android SDK.' }
if(-not $env:GITHUB_ENV) { throw 'Run this helper in GitHub Actions with GITHUB_ENV available.' }
if([string]::IsNullOrWhiteSpace($env:RELAY_TOKEN)) { throw 'Provide RELAY_TOKEN through the job environment. A placeholder token is not accepted.' }
if(-not (Test-Path -LiteralPath $VideoSeedPath -PathType Leaf)) { throw 'Provide a valid MP4 seed through -VideoSeedPath.' }
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
function Invoke-Checked {
 param([string]$Tool,[string[]]$Arguments,[string]$Stage)
 & $Tool @Arguments | Out-Host
 if($LASTEXITCODE -ne 0) { throw "$Stage failed with exit code $LASTEXITCODE." }
}
function Find-JdkTool([string]$Name) {
 if($env:JAVA_HOME) {
  $path=Join-Path $env:JAVA_HOME "bin/$Name.exe"
  if(Test-Path -LiteralPath $path -PathType Leaf) { return $path }
 }
 $command=Get-Command $Name -ErrorAction Stop
 return $command.Source
}
$javac=Find-JdkTool 'javac'; $jar=Find-JdkTool 'jar'; $keytool=Find-JdkTool 'keytool'
$ffmpeg=(Get-Command $FfmpegPath -ErrorAction Stop).Source
$ffprobe=(Get-Command $FfprobePath -ErrorAction Stop).Source
$sdkmanager=Join-Path $AndroidSdkRoot 'cmdline-tools/latest/bin/sdkmanager.bat'
if(-not (Test-Path -LiteralPath $sdkmanager)) {
 $sdkCommand=Get-Command sdkmanager -ErrorAction SilentlyContinue
 if($sdkCommand) { $sdkmanager=$sdkCommand.Source }
 else { throw 'SDK command-line tools must provide cmdline-tools/latest/bin/sdkmanager.bat or sdkmanager on PATH.' }
}
Invoke-Checked $sdkmanager @('platforms;android-35','build-tools;35.0.0',('--sdk_root='+$AndroidSdkRoot)) 'Install SDK 35'
$androidJar=Join-Path $AndroidSdkRoot 'platforms/android-35/android.jar'
$buildTools=Join-Path $AndroidSdkRoot 'build-tools/35.0.0'
$d8=Join-Path $buildTools 'd8.bat'; $aapt=Join-Path $buildTools 'aapt.exe'
$zipalign=Join-Path $buildTools 'zipalign.exe'; $apksigner=Join-Path $buildTools 'apksigner.bat'
foreach($path in @($androidJar,$d8,$aapt,$zipalign,$apksigner)) {
 if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required SDK 35 tool is missing: $path" }
}
# Decode a frame before embedding the seed; do not substitute a renamed data file.
Invoke-Checked $ffmpeg @('-hide_banner','-loglevel','error','-i',$VideoSeedPath,'-map','0:v:0','-frames:v','1','-f','null','NUL') 'Decode video seed'
$probeText=(& $ffprobe -v error -show_format -show_streams -of json $VideoSeedPath) -join [Environment]::NewLine
if($LASTEXITCODE -ne 0) { throw 'ffprobe could not inspect the MP4 seed.' }
$probe=ConvertFrom-Json $probeText
if(@($probe.streams | Where-Object codec_type -eq 'video').Count -eq 0 -or $probe.format.format_name -notmatch 'mp4') {
 throw 'The seed must contain a video stream in an MP4 container.'
}
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'supplied-seed-probe.json'),$probeText,[Text.UTF8Encoding]::new($false))
# Keep the capability-bearing config and APK outside all evidence upload directories.
$fixtureTemp=Join-Path ([IO.Path]::GetTempPath()) ('fixture3556-'+[Guid]::NewGuid().ToString('N'))
$relayTemp=Join-Path ([IO.Path]::GetTempPath()) ('cloudtransport-'+[Guid]::NewGuid().ToString('N'))
function Build-Helper {
 param([string]$SourceDirectory,[string]$BuildDirectory,[int]$MinApi,[string]$ApkName,[string]$CertificateName)
 foreach($name in @('classes','dex','assets')) { [void][IO.Directory]::CreateDirectory((Join-Path $BuildDirectory $name)) }
 $classesDirectory=Join-Path $BuildDirectory 'classes'; $dexDirectory=Join-Path $BuildDirectory 'dex'
 $assetsDirectory=Join-Path $BuildDirectory 'assets'
 $javaSources=@(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.java' -File | ForEach-Object FullName)
 if($javaSources.Count -eq 0) { throw "No Java helper sources found in $SourceDirectory." }
 $compileArguments=@('-source','8','-target','8','-classpath',$androidJar,'-d',$classesDirectory)+$javaSources
 Invoke-Checked $javac $compileArguments 'Compile Java helper'
 $classFiles=@(Get-ChildItem -LiteralPath $classesDirectory -Recurse -Filter '*.class' -File | ForEach-Object FullName)
 if($classFiles.Count -eq 0) { throw 'javac produced no class files.' }
 Invoke-Checked $d8 (@('--lib',$androidJar,'--min-api',[string]$MinApi,'--output',$dexDirectory)+$classFiles) 'Compile helper dex'
 $unsigned=Join-Path $BuildDirectory 'unsigned.apk'
 Invoke-Checked $aapt @('package','-f','-M',(Join-Path $SourceDirectory 'AndroidManifest.xml'),'-I',$androidJar,'-A',$assetsDirectory,'-F',$unsigned) 'Package helper'
 # jar updates this ZIP/APK with classes.dex; no external zip binary is required.
 Invoke-Checked $jar @('uf',$unsigned,'-C',$dexDirectory,'classes.dex') 'Add helper dex'
 $aligned=Join-Path $BuildDirectory 'aligned.apk'
 Invoke-Checked $zipalign @('-f','4',$unsigned,$aligned) 'Align helper APK'
 $keystore=Join-Path $BuildDirectory 'debug.jks'
 Invoke-Checked $keytool @('-genkeypair','-keystore',$keystore,'-alias','androiddebugkey','-storepass','android','-keypass','android','-keyalg','RSA','-validity','2','-dname',"CN=$CertificateName") 'Create helper signing key'
 $apk=Join-Path $BuildDirectory $ApkName
 Invoke-Checked $apksigner @('sign','--ks',$keystore,'--ks-pass','pass:android','--out',$apk,$aligned) 'Sign helper APK'
 Invoke-Checked $apksigner @('verify',$apk) 'Verify helper APK'
 return $apk
}
foreach($root in @($fixtureTemp,$relayTemp)) { [void][IO.Directory]::CreateDirectory((Join-Path $root 'assets')) }
$embeddedSeed=Join-Path $fixtureTemp 'assets/seed.mp4'
if((Get-Item -LiteralPath $VideoSeedPath).Length -ge 1048560) {
 # A supplied 1 MiB MP4 needs a smaller playable seed before MainActivity adds its free box.
 Invoke-Checked $ffmpeg @('-hide_banner','-loglevel','error','-y','-i',$VideoSeedPath,'-map','0:v:0','-an','-t','1','-vf','scale=320:-2','-r','10','-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart',$embeddedSeed) 'Create bounded video seed'
} else { Copy-Item -LiteralPath $VideoSeedPath -Destination $embeddedSeed }
if((Get-Item -LiteralPath $embeddedSeed).Length -ge 1048560) { throw 'Embedded MP4 seed leaves no room for the 16-byte free-box header in the 1 MiB fixture.' }
Invoke-Checked $ffmpeg @('-hide_banner','-loglevel','error','-i',$embeddedSeed,'-map','0:v:0','-frames:v','1','-f','null','NUL') 'Decode embedded video seed'
# JSON serialization handles token escaping without placing the token on a process command line.
$configPath=Join-Path $relayTemp 'assets/config.json'
[IO.File]::WriteAllText($configPath,(ConvertTo-Json -Compress @{ endpoint=$RelayEndpoint; token=$env:RELAY_TOKEN }),[Text.UTF8Encoding]::new($false))
try {
 $fixtureApk=Build-Helper (Join-Path $RepositoryRoot 'support/diagnose_3556/android') $fixtureTemp 29 'fixture3556-helper.apk' 'Issue3556 fixture helper'
 $relayApk=Build-Helper (Join-Path $RepositoryRoot 'support/cloud_transport/android') $relayTemp 26 'cloud-transport-helper.apk' 'Cloud diagnostic'
 foreach($name in @('unsigned.apk','aligned.apk','debug.jks')) {
  $intermediate=Join-Path $relayTemp $name
  if(Test-Path -LiteralPath $intermediate) { Remove-Item -LiteralPath $intermediate -Force }
 }
 # These variables are private job-local paths, not artifact upload instructions.
 [IO.File]::AppendAllText($env:GITHUB_ENV,"FIXTURE_3556_APK=$fixtureApk"+[Environment]::NewLine+"CLOUD_TRANSPORT_APK=$relayApk"+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
 $safeReport=@{
  sdkPlatform=35; buildTools='35.0.0'; sourceCompatibility=8; fixtureMinApi=29; cloudTransportMinApi=26
  suppliedSeed=@{ bytes=(Get-Item $VideoSeedPath).Length; sha256=(Get-FileHash $VideoSeedPath -Algorithm SHA256).Hash }
  embeddedSeed=@{ bytes=(Get-Item $embeddedSeed).Length; sha256=(Get-FileHash $embeddedSeed -Algorithm SHA256).Hash }
  fixtureApk=@{ bytes=(Get-Item $fixtureApk).Length; sha256=(Get-FileHash $fixtureApk -Algorithm SHA256).Hash }
  cloudTransport='Private capability-bearing APK built and signature verified; path and hash excluded from evidence.'
  fixtureGeneration='Existing MainActivity supplies legal MP4 free-box padding, including its 16GB fixture; this build does not change it.'
 }
 [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'build.json'),(ConvertTo-Json $safeReport -Depth 5),[Text.UTF8Encoding]::new($false))
 Write-Host 'Both helper APKs built and verified. Private paths are available through GITHUB_ENV.'
} catch {
 # Remove all capability-bearing material if the paired build cannot finish.
 if(Test-Path -LiteralPath $relayTemp) { Remove-Item -LiteralPath $relayTemp -Recurse -Force }
 throw
} finally {
 # The signed capability APK remains only in TEMP for direct upload to the private device service.
 if(Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
}

