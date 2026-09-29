param(
  [Parameter(Mandatory = $true)][ValidateSet('1.17.0', '1.18.2')][string] $Version,
  [Parameter(Mandatory = $true)][ValidateSet('failure', 'success')][string] $ExpectedMissingOutcome,
  [string] $CliPath = $env:LS_CLI_PATH,
  [string] $OutputDirectory = $env:LS_MISSING_DESTINATION_OUTPUT
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  throw 'Set LS_MISSING_DESTINATION_OUTPUT or pass -OutputDirectory.'
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$releaseDirectory = Join-Path $OutputDirectory "release-$Version"
$archiveName = "LocalSend-$Version-windows-x86-64.zip"
$archiveUrl = "https://github.com/localsend/localsend/releases/download/v$Version/$archiveName"
$archivePath = Join-Path $OutputDirectory $archiveName
$reportPath = Join-Path $OutputDirectory 'report.json'
$receiver = $null

if ([string]::IsNullOrWhiteSpace($CliPath) -or -not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
  throw 'Set LS_CLI_PATH or pass -CliPath with a built headless LocalSend CLI.'
}
$CliPath = [IO.Path]::GetFullPath($CliPath)

function Write-PortableSettings([string] $ExecutableDirectory, [string] $Destination) {
  if ($Version -eq '1.17.0') {
    $settings = [ordered]@{
      'flutter.ls_version' = 2
      'flutter.ls_alias' = "E2E Receiver $Version"
      'flutter.ls_port' = 53317
      'flutter.ls_destination' = $Destination
      'flutter.ls_quick_save' = $true
      'flutter.ls_quick_save_from_favorites' = $false
      'flutter.ls_https' = $true
    }
  } else {
    $settings = [ordered]@{
      'flutter.ls_version' = 3
      'flutter.ls_alias' = "E2E Receiver $Version"
      'flutter.ls_port' = 53317
      'flutter.ls_destination' = $Destination
      'flutter.ls_quick_save' = 'on'
      'flutter.ls_https' = $true
    }
  }
  [IO.File]::WriteAllText(
    (Join-Path $ExecutableDirectory 'settings.json'),
    (ConvertTo-Json -InputObject $settings -Depth 4),
    [Text.UTF8Encoding]::new($false)
  )
}

function Wait-ForTcpPort([int] $Port, [int] $TimeoutSeconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $client = [Net.Sockets.TcpClient]::new()
    try {
      $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(250) -and $client.Connected) {
        $client.EndConnect($async)
        return $true
      }
    } catch {
    } finally {
      $client.Dispose()
    }
    Start-Sleep -Milliseconds 250
  } until ([DateTime]::UtcNow -ge $deadline)
  return $false
}

function Stop-Receiver {
  if ($null -ne $script:receiver) {
    try {
      if (-not $script:receiver.HasExited) {
        Stop-Process -Id $script:receiver.Id -Force
        $script:receiver.WaitForExit(10000) | Out-Null
      }
    } catch {
    }
    $script:receiver = $null
  }
  Get-Process -Name 'localsend_app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Start-Receiver([IO.FileInfo] $Executable, [string] $CaseName) {
  if (Wait-ForTcpPort -Port 53317 -TimeoutSeconds 1) {
    throw "Port 53317 was already occupied before receiver launch for case $CaseName."
  }
  $stdout = Join-Path $OutputDirectory "$CaseName-receiver.stdout.log"
  $stderr = Join-Path $OutputDirectory "$CaseName-receiver.stderr.log"
  $script:receiver = Start-Process -FilePath $Executable.FullName -WorkingDirectory $Executable.DirectoryName -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if (-not (Wait-ForTcpPort -Port 53317 -TimeoutSeconds 40)) {
    throw "Receiver $Version did not listen on 127.0.0.1:53317 for case $CaseName."
  }
  $script:receiver.Refresh()
  if ($script:receiver.HasExited) { throw "Receiver $Version exited during startup for case $CaseName." }
}

function Invoke-Send([string] $Fixture, [string] $CaseName, [int] $TimeoutSeconds = 45) {
  $stdout = Join-Path $OutputDirectory "$CaseName-sender.stdout.log"
  $stderr = Join-Path $OutputDirectory "$CaseName-sender.stderr.log"
  $arguments = @('--port', '53318', '--alias', 'E2E-Sender', 'send', '--to', '127.0.0.1', $Fixture)
  $process = Start-Process -FilePath $CliPath -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
  if ($timedOut) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit(10000) | Out-Null
  } else {
    $process.WaitForExit()
  }
  $process.Refresh()
  $exitCode = if ($timedOut) { $null } else { $process.ExitCode }
  return [ordered]@{
    timedOut = $timedOut
    exitCode = $exitCode
    elapsedLimitSeconds = $TimeoutSeconds
    stdout = if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout) } else { '' }
    stderr = if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr) } else { '' }
  }
}

function Capture-Desktop([string] $CaseName) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    try {
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
      } finally {
        $graphics.Dispose()
      }
      $path = Join-Path $OutputDirectory "$CaseName-desktop.png"
      $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
      return $path
    } finally {
      $bitmap.Dispose()
    }
  } catch {
    return "capture-error: $($_.Exception.Message)"
  }
}

$report = [ordered]@{
  platform = 'windows'
  os = [Environment]::OSVersion.VersionString
  osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
  version = $Version
  expectedMissingOutcome = $ExpectedMissingOutcome
  release = $null
  cli = $null
  fixture = $null
  control = $null
  missingDestinationRuns = @()
  verdict = 'inconclusive'
  errors = @()
  startedUtc = [DateTime]::UtcNow.ToString('o')
}

try {
  Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -MaximumRedirection 10
  Expand-Archive -LiteralPath $archivePath -DestinationPath $releaseDirectory -Force
  $executables = @(Get-ChildItem -LiteralPath $releaseDirectory -Recurse -File -Filter 'localsend_app.exe')
  if ($executables.Count -ne 1) { throw "Expected one localsend_app.exe, found $($executables.Count)." }
  $executable = $executables[0]
  $report.release = [ordered]@{
    tag = "v$Version"
    assetUrl = $archiveUrl
    assetBytes = (Get-Item -LiteralPath $archivePath).Length
    assetSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    executable = $executable.FullName
    executableVersion = $executable.VersionInfo.FileVersion
    executableSha256 = (Get-FileHash -LiteralPath $executable.FullName -Algorithm SHA256).Hash
  }
  $report.cli = [ordered]@{
    sourceCommit = $env:GITHUB_SHA
    path = $CliPath
    bytes = (Get-Item -LiteralPath $CliPath).Length
    sha256 = (Get-FileHash -LiteralPath $CliPath -Algorithm SHA256).Hash
  }

  $fixturePath = Join-Path $OutputDirectory 'flat-file-16MiB.bin'
  $stream = [IO.File]::Open($fixturePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.SetLength(16MB) } finally { $stream.Dispose() }
  $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
  $report.fixture = [ordered]@{ path = $fixturePath; bytes = (Get-Item $fixturePath).Length; sha256 = $fixtureHash; flatFile = $true }

  $controlDestination = Join-Path $OutputDirectory 'control-destination'
  [IO.Directory]::CreateDirectory($controlDestination) | Out-Null
  Write-PortableSettings -ExecutableDirectory $executable.DirectoryName -Destination $controlDestination
  Start-Receiver -Executable $executable -CaseName 'control'
  $controlSend = Invoke-Send -Fixture $fixturePath -CaseName 'control'
  Start-Sleep -Seconds 2
  $receiver.Refresh()
  $controlReceiverAlive = (-not $receiver.HasExited) -and (Wait-ForTcpPort -Port 53317 -TimeoutSeconds 2)
  $controlReceived = Join-Path $controlDestination (Split-Path -Leaf $fixturePath)
  $controlMatches = (Test-Path -LiteralPath $controlReceived -PathType Leaf) -and ((Get-FileHash -LiteralPath $controlReceived -Algorithm SHA256).Hash -eq $fixtureHash)
  $report.control = [ordered]@{
    destinationExistedBeforeSend = $true
    sender = $controlSend
    receiverAliveAfterSend = $controlReceiverAlive
    fileExists = Test-Path -LiteralPath $controlReceived -PathType Leaf
    hashMatches = $controlMatches
    screenshot = Capture-Desktop -CaseName 'control-after-send'
  }
  Stop-Receiver
  if ($controlSend.timedOut -or $controlSend.exitCode -ne 0 -or -not $controlMatches -or -not $controlReceiverAlive) {
    throw 'Positive control failed; the sender/receiver setup is not a valid reproduction environment.'
  }

  foreach ($iteration in 1..2) {
    $caseName = "missing-$iteration"
    $destination = Join-Path $OutputDirectory "deleted-destination-$iteration"
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    Write-PortableSettings -ExecutableDirectory $executable.DirectoryName -Destination $destination
    Start-Receiver -Executable $executable -CaseName $caseName
    Remove-Item -LiteralPath $destination -Recurse -Force
    if (Test-Path -LiteralPath $destination) { throw "Could not delete destination for $caseName." }
    $send = Invoke-Send -Fixture $fixturePath -CaseName $caseName
    Start-Sleep -Seconds 2
    $receiver.Refresh()
    $receiverAlive = (-not $receiver.HasExited) -and (Wait-ForTcpPort -Port 53317 -TimeoutSeconds 2)
    $received = Join-Path $destination (Split-Path -Leaf $fixturePath)
    $fileExists = Test-Path -LiteralPath $received -PathType Leaf
    $hashMatches = $fileExists -and ((Get-FileHash -LiteralPath $received -Algorithm SHA256).Hash -eq $fixtureHash)
    $entry = [ordered]@{
      iteration = $iteration
      destinationExistedWhenConfigured = $true
      destinationExistedBeforeSend = $false
      sender = $send
      receiverAliveAfterSend = $receiverAlive
      destinationCreated = Test-Path -LiteralPath $destination -PathType Container
      fileExists = $fileExists
      hashMatches = $hashMatches
      transferSucceeded = (-not $send.timedOut) -and $send.exitCode -eq 0 -and $hashMatches -and $receiverAlive
      screenshot = Capture-Desktop -CaseName "$caseName-after-send"
    }
    $report.missingDestinationRuns += $entry
    Stop-Receiver
  }

  $allSucceeded = @($report.missingDestinationRuns | Where-Object { $_.transferSucceeded }).Count -eq 2
  $allFailedWithoutFile = @($report.missingDestinationRuns | Where-Object { -not $_.transferSucceeded -and -not $_.fileExists -and $_.receiverAliveAfterSend }).Count -eq 2
  if ($ExpectedMissingOutcome -eq 'success' -and $allSucceeded) {
    $report.verdict = 'pass-missing-destination-recreated'
  } elseif ($ExpectedMissingOutcome -eq 'failure' -and $allFailedWithoutFile) {
    $report.verdict = 'reproduced-missing-destination-failure'
  } else {
    throw "Observed missing-destination behavior did not match expected '$ExpectedMissingOutcome'."
  }
} catch {
  $report.errors += $_.Exception.ToString()
} finally {
  Stop-Receiver
  $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
  [IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 12), [Text.UTF8Encoding]::new($false))
  Write-Host ([IO.File]::ReadAllText($reportPath))
}

if ($report.errors.Count -gt 0 -or $report.verdict -eq 'inconclusive') { exit 1 }
