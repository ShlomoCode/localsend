param(
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
    [string]$EvidenceDirectory,
    [string]$AndroidSdkRoot = $env:ANDROID_HOME
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not $EvidenceDirectory) { $EvidenceDirectory = Join-Path $RepositoryRoot 'evidence/helper-build' }
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $AndroidSdkRoot) { $AndroidSdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $AndroidSdkRoot -or -not (Test-Path $AndroidSdkRoot)) { throw 'An installed Android SDK is required.' }
if (-not $env:GITHUB_ENV) { throw 'Run this script in GitHub Actions with GITHUB_ENV available.' }
if ([string]::IsNullOrWhiteSpace($env:RELAY_TOKEN)) { throw 'The job environment must provide RELAY_TOKEN.' }
$platform = Get-ChildItem (Join-Path $AndroidSdkRoot 'platforms') -Directory |
    Where-Object { $_.Name -match '^android-\d+$' -and [int]($_.Name.Substring(8)) -ge 35 } |
    Sort-Object { [int]($_.Name.Substring(8)) } -Descending | Select-Object -First 1
if (-not $platform) { throw 'An installed API 35 or later android.jar is required for the transport manifest.' }
$tools = Get-ChildItem (Join-Path $AndroidSdkRoot 'build-tools') -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' -and (Test-Path (Join-Path $_.FullName 'd8.bat')) } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $tools) { throw 'Installed Android build-tools with d8 are required.' }
$javaRoot = $env:JAVA_HOME_17_X64
if (-not $javaRoot) { $javaRoot = $env:JAVA_HOME }
if (-not $javaRoot) { throw 'JAVA_HOME_17_X64 or JAVA_HOME must point to Java 17.' }
$java = Join-Path $javaRoot 'bin/java.exe'
$javac = Join-Path $javaRoot 'bin/javac.exe'
$keytool = Join-Path $javaRoot 'bin/keytool.exe'
$javaVersion = & $java -version 2>&1 | Out-String
if ($javaVersion -notmatch 'version "17[.\"]') { throw "Java 17 is required; observed: $javaVersion" }
$androidJar = Join-Path $platform.FullName 'android.jar'
foreach ($name in @('d8.bat', 'aapt.exe', 'zipalign.exe', 'apksigner.bat')) {
    if (-not (Test-Path (Join-Path $tools.FullName $name))) { throw "Missing SDK build tool: $name" }
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
function Build-Helper([string]$SourceDirectory, [string]$BuildDirectory, [int]$MinApi, [string]$ApkName) {
    $classes = Join-Path $BuildDirectory 'classes'
    $dex = Join-Path $BuildDirectory 'dex'
    foreach ($dir in @($classes, $dex)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $sources = @(Get-ChildItem $SourceDirectory -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })
    if ($sources.Count -eq 0) { throw "No Java helper source in $SourceDirectory" }
    Invoke-Checked $javac (@('--release', '8', '-encoding', 'UTF-8', '-classpath', $androidJar, '-d', $classes) + $sources)
    $classFiles = @(Get-ChildItem $classes -Recurse -Filter '*.class' | ForEach-Object { $_.FullName })
    if ($classFiles.Count -eq 0) { throw 'javac produced no helper classes.' }
    Invoke-Checked (Join-Path $tools.FullName 'd8.bat') (@('--min-api', [string]$MinApi, '--lib', $androidJar, '--output', $dex) + $classFiles)
    $unsigned = Join-Path $BuildDirectory 'unsigned.apk'
    $aligned = Join-Path $BuildDirectory 'aligned.apk'
    $apk = Join-Path $BuildDirectory $ApkName
    Invoke-Checked (Join-Path $tools.FullName 'aapt.exe') @('package', '-f', '-M', (Join-Path $SourceDirectory 'AndroidManifest.xml'),
        '-I', $androidJar, '-A', (Join-Path $BuildDirectory 'assets'), '-F', $unsigned)
    Push-Location $dex
    try { Invoke-Checked (Join-Path $tools.FullName 'aapt.exe') @('add', $unsigned, 'classes.dex') }
    finally { Pop-Location }
    Invoke-Checked (Join-Path $tools.FullName 'zipalign.exe') @('-f', '4', $unsigned, $aligned)
    $key = Join-Path $BuildDirectory 'diagnostic-signing.jks'
    Invoke-Checked $keytool @('-genkeypair', '-keystore', $key, '-storepass', 'diagnostic2096', '-keypass', 'diagnostic2096',
        '-alias', 'diagnostic2096', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '2', '-dname', 'CN=Issue 2096 diagnostic helper')
    Invoke-Checked (Join-Path $tools.FullName 'apksigner.bat') @('sign', '--ks', $key, '--ks-key-alias', 'diagnostic2096',
        '--ks-pass', 'pass:diagnostic2096', '--key-pass', 'pass:diagnostic2096', '--out', $apk, $aligned)
    Invoke-Checked (Join-Path $tools.FullName 'apksigner.bat') @('verify', $apk)
    foreach ($name in @('unsigned.apk', 'aligned.apk', 'diagnostic-signing.jks')) {
        Remove-Item -LiteralPath (Join-Path $BuildDirectory $name) -Force
    }
    return $apk
}
# Keep capability-bearing assets and APKs outside all artifact/evidence directories.
$fixtureTemp = Join-Path ([IO.Path]::GetTempPath()) ('fixture2096-' + [Guid]::NewGuid().ToString('N'))
$relayTemp = Join-Path ([IO.Path]::GetTempPath()) ('cloudtransport-' + [Guid]::NewGuid().ToString('N'))
$configPath = Join-Path $relayTemp 'assets/config.json'
$previousJava = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaRoot
    foreach ($dir in @($fixtureTemp, $relayTemp)) { New-Item -ItemType Directory -Force (Join-Path $dir 'assets') | Out-Null }
    Copy-Item (Join-Path $RepositoryRoot 'support/diagnose_2096/android/assets/*') (Join-Path $fixtureTemp 'assets') -Recurse
    $config = @{ endpoint = 'http://bs-local.com:8080'; token = $env:RELAY_TOKEN; transport = 'legacy'; peerAbsoluteMs = 900000 }
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -Compress $config), [Text.UTF8Encoding]::new($false))
    $fixtureApk = Build-Helper (Join-Path $RepositoryRoot 'support/diagnose_2096/android') $fixtureTemp 29 'issue2096-helper.apk'
    $relayApk = Build-Helper (Join-Path $RepositoryRoot 'support/cloud_transport/android') $relayTemp 26 'cloud-transport-helper.apk'
    $env:FIXTURE_2096_APK = $fixtureApk
    $env:CLOUD_TRANSPORT_APK = $relayApk
    $env:DIAG2096_BUILD_TOOLS = $tools.FullName
    [IO.File]::AppendAllText($env:GITHUB_ENV, "FIXTURE_2096_APK=$fixtureApk" + [Environment]::NewLine +
        "CLOUD_TRANSPORT_APK=$relayApk" + [Environment]::NewLine +
        "DIAG2096_BUILD_TOOLS=" + $tools.FullName + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
    $report = @{ sdkPlatform = $platform.Name; buildTools = $tools.Name; java = 17; release = 8; fixtureMinApi = 29; transportMinApi = 26;
        fixtureApk = @{ bytes = (Get-Item $fixtureApk).Length; sha256 = (Get-FileHash $fixtureApk -Algorithm SHA256).Hash };
        cloudTransport = 'Private capability-bearing APK; path and hash excluded from evidence'; transport = 'legacy'; peerAbsoluteMs = 900000 }
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'build.json'), (ConvertTo-Json $report -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-Host 'Fixture and transport APKs built and verified; private paths exported in this process and through GITHUB_ENV.'
} catch {
    foreach ($dir in @($fixtureTemp, $relayTemp)) {
        if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    throw
} finally {
    $env:JAVA_HOME = $previousJava
    if (Test-Path $configPath) { Remove-Item -LiteralPath $configPath -Force }
}
