$ErrorActionPreference = 'Stop'
$serial = $null
$handshake = [Diagnostics.Stopwatch]::StartNew()
$handshakeLimitMs = 120000
$preparationStage = 'serial-open'
function RemainingHandshakeMs {
  $remaining = $handshakeLimitMs - $handshake.ElapsedMilliseconds
  if ($remaining -le 0) { throw 'First-logon network handshake deadline exceeded' }
  return [int]$remaining
}
function Report([string]$stage, $data) {
  $record = @{ stage=$stage; utc=[DateTime]::UtcNow.ToString('o'); data=$data }
  if ($stage -in @('bootstrap-entry','windows-identity','probe-session','waiting-for-network','network-wait-progress','network-ready')) {
    $data.handshakeElapsedMs = $handshake.ElapsedMilliseconds
    $serial.WriteTimeout = [Math]::Min(1000, (RemainingHandshakeMs))
  }
  $serial.WriteLine('ISSUE1054 ' + ($record | ConvertTo-Json -Compress -Depth 8))
}
# CIM's provider timeout alone is not a total wall-clock bound. Each small query
# runs in an owned child process, whose entire lifetime uses the same stopwatch.
function BoundedSnapshot([string]$query, [long]$stageDeadlineMs = 120000) {
  $childCode = '$ErrorActionPreference="Stop"; try { & { ' + $query + ' } | ConvertTo-Json -Compress -Depth 8 } catch { [Console]::Out.WriteLine("query-failed"); exit 1 }'
  $start = New-Object Diagnostics.ProcessStartInfo
  $start.FileName = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
  $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $child = New-Object Diagnostics.Process
  $child.StartInfo = $start
  $started = $false
  try {
    $allowance = [Math]::Min(10000, [Math]::Min((RemainingHandshakeMs), $stageDeadlineMs - $handshake.ElapsedMilliseconds))
    if ($allowance -le 0) { throw 'Bounded preparation query timed out' }
    $queryDeadlineMs = $handshake.ElapsedMilliseconds + $allowance
    if (-not $child.Start()) { throw 'Could not start bounded preparation query' }
    $started = $true
    # Include process startup time instead of renewing the allowance after Start.
    $allowance = [Math]::Min($queryDeadlineMs - $handshake.ElapsedMilliseconds, (RemainingHandshakeMs))
    if ($allowance -le 0) { throw 'Bounded preparation query timed out' }
    if (-not $child.WaitForExit([int]$allowance)) { throw 'Bounded preparation query timed out' }
    $null = RemainingHandshakeMs
    if ($child.ExitCode -ne 0) { throw 'Bounded preparation query failed' }
    $result = $child.StandardOutput.ReadToEnd() | ConvertFrom-Json
    $null = RemainingHandshakeMs
    return $result
  } finally {
    if ($started -and -not $child.HasExited) {
      $child.Kill()
      # Reap only within the original budget; never grant cleanup a new wait.
      $cleanupMs = [Math]::Max(0, [Math]::Min(1000, $handshakeLimitMs - $handshake.ElapsedMilliseconds))
      $null = $child.WaitForExit([int]$cleanupMs)
    }
    $child.Dispose()
  }
}
$networkQuery = @'
$adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter "MACAddress='52:54:00:12:34:56'" -OperationTimeoutSec 3)
if ($adapters.Count -ne 1) { @{ count=$adapters.Count }; return }
$adapter = $adapters[0]
$index = [int]$adapter.InterfaceIndex
$addresses = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetIPAddress -Filter "InterfaceIndex=$index AND AddressFamily=2" -OperationTimeoutSec 3 | ForEach-Object { @{ address=$_.IPAddress; prefixLength=$_.PrefixLength; addressState=[int]$_.AddressState } })
$routes = @(Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetRoute -Filter "InterfaceIndex=$index AND AddressFamily=2 AND DestinationPrefix='0.0.0.0/0'" -OperationTimeoutSec 3 | ForEach-Object { @{ interfaceIndex=[int]$_.InterfaceIndex; destination=$_.DestinationPrefix; nextHop=$_.NextHop } })
@{ count=1; adapter=@{ mac=$adapter.MACAddress; interfaceIndex=$index; name=$adapter.NetConnectionID; description=$adapter.Name; netEnabled=($adapter.NetEnabled -eq $true); connectionStatus=[int]$adapter.NetConnectionStatus; ipv4=$addresses; defaultRoutes=$routes } }
'@
try {
  $serial = New-Object System.IO.Ports.SerialPort 'COM1', 115200, 'None', 8, 'One'
  $serial.WriteTimeout = 1000
  $serial.Open()
  Report 'bootstrap-entry' @{ handshakeLimitSeconds=120 }
  $preparationStage = 'windows-identity'
  $os = BoundedSnapshot 'Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3 | Select-Object Caption, Version, BuildNumber, OSArchitecture, OperatingSystemSKU'
  Report 'windows-identity' @{ caption=$os.Caption; version=$os.Version; build=$os.BuildNumber; architecture=$os.OSArchitecture; sku=$os.OperatingSystemSKU }
  if ($os.Caption -notmatch 'Enterprise Evaluation' -or $os.Version -notmatch '^10\.0\.19045') { throw 'Unexpected Windows edition or build' }
  $preparationStage = 'probe-session'
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
  $interactiveUser = (BoundedSnapshot 'Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 3 | Select-Object UserName').UserName
  if ($identity.Name -ine 'Sender\Probe' -or $interactiveUser -ine $identity.Name -or $sessionId -le 0 -or -not [Environment]::UserInteractive -or $identity.User.Value -notmatch '^S-1-5-21-') {
    throw 'Expected interactive Probe first-logon session was not observed'
  }
  Report 'probe-session' @{ account='Probe'; identity=$identity.Name; sid=$identity.User.Value; sessionId=$sessionId; userInteractive=[Environment]::UserInteractive; interactiveUser=$interactiveUser }
  $preparationStage = 'disconnected-adapter'
  $adapterInitUntilMs = [Math]::Min($handshakeLimitMs, $handshake.ElapsedMilliseconds + 15000)
  do {
    $network = BoundedSnapshot $networkQuery $adapterInitUntilMs
    if ($network.count -eq 1) { break }
    if ($network.count -gt 1 -or $handshake.ElapsedMilliseconds -ge $adapterInitUntilMs) { throw 'Expected single e1000 adapter was not observed' }
    Start-Sleep -Milliseconds ([Math]::Min(500, (RemainingHandshakeMs)))
  } while ($true)
  $adapter = $network.adapter
  if ($adapter.description -notmatch 'Intel.*PRO/1000' -or $adapter.interfaceIndex -le 0 -or -not $adapter.netEnabled -or $adapter.connectionStatus -ne 7) {
    throw 'Expected e1000 adapter is not media disconnected'
  }
  $interfaceIndex = $adapter.interfaceIndex
  $preparationStage = 'preparation-status'
  $status = BoundedSnapshot @'
$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
@{ installedRevision=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR).UBR; setup=@{ SystemSetupInProgress=$setup.SystemSetupInProgress; OOBEInProgress=$setup.OOBEInProgress; SetupPhase=$setup.SetupPhase; SetupType=$setup.SetupType }; pending=@{ rebootRequired=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'); packagesPending=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') } }
'@
  Report 'waiting-for-network' @{ expectedMac='52:54:00:12:34:56'; adapter=$adapter; setup=$status.setup; pending=$status.pending; installedRevision=$status.installedRevision; handshakeLimitSeconds=120 }
  $preparationStage = 'network-restore'
  do {
    Report 'network-wait-progress' @{ expectedMac='52:54:00:12:34:56'; interfaceIndex=$interfaceIndex; queryBoundary='before' }
    $network = BoundedSnapshot $networkQuery
    Report 'network-wait-progress' @{ expectedMac='52:54:00:12:34:56'; interfaceIndex=$interfaceIndex; queryBoundary='after' }
    if ($network.count -ne 1 -or $network.adapter.interfaceIndex -ne $interfaceIndex -or $network.adapter.description -notmatch 'Intel.*PRO/1000') { throw 'Expected adapter identity changed during restore' }
    $adapter = $network.adapter
    $validAddresses = @($adapter.ipv4 | Where-Object { $_.addressState -eq 4 -and $_.address -match '^(\d{1,3}\.){3}\d{1,3}$' -and $_.address -notmatch '^(0\.|127\.|169\.254\.|22[4-9]\.|23\d\.|24\d\.|25[0-5]\.)' })
    $validRoutes = @($adapter.defaultRoutes | Where-Object { $_.interfaceIndex -eq $interfaceIndex -and $_.destination -eq '0.0.0.0/0' -and $_.nextHop -notmatch '^(0\.|127\.|169\.254\.)' })
    if ($adapter.netEnabled -and $adapter.connectionStatus -eq 2 -and $validAddresses.Count -gt 0 -and $validRoutes.Count -gt 0) { break }
    Start-Sleep -Milliseconds ([Math]::Min(500, (RemainingHandshakeMs)))
  } while ($true)
  Report 'network-ready' @{ expectedMac='52:54:00:12:34:56'; adapter=$adapter }
  $null = RemainingHandshakeMs
  $preparationStage = $null
  # Ordinary activation only. Do not set a key, reset timers, or alter licensing.
  $activationOutput = (& cscript.exe //Nologo "$env:windir\System32\slmgr.vbs" /ato 2>&1 | Out-String)
  $expiryOutput = (& cscript.exe //Nologo "$env:windir\System32\slmgr.vbs" /xpr 2>&1 | Out-String)
  $licenses = @(Get-CimInstance SoftwareLicensingProduct | Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey })
  Report 'windows-license' @{ activation=$activationOutput; expiry=$expiryOutput; products=@($licenses | Select-Object Name, Description, LicenseStatus, GracePeriodRemaining) }
  if (-not ($licenses | Where-Object { $_.LicenseStatus -eq 1 })) { throw 'Evaluation is not licensed; stop before app gate' }
  Report 'network' @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress, PrefixLength)
  $installer = Join-Path $PSScriptRoot 'LocalSend-1.15.3-windows-x86-64.exe'
  $signature = Get-AuthenticodeSignature $installer
  Report 'official-installer' @{ hash=(Get-FileHash $installer -Algorithm SHA256).Hash; bytes=(Get-Item $installer).Length; signature=$signature.Status.ToString(); signer=$signature.SignerCertificate.Subject }
  # Official 1.15.3 Windows signature status is unknown; preserve it accurately.
  $setup = Start-Process $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
  Report 'installer-result' @{ exitCode=$setup.ExitCode }
  if ($setup.ExitCode -ne 0) { throw "Installer failed: $($setup.ExitCode)" }
  $candidates = @("$env:ProgramFiles\LocalSend\localsend_app.exe", "$env:LOCALAPPDATA\Programs\LocalSend\localsend_app.exe")
  $app = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $app) { throw 'Official installed app not found in ordinary install paths' }
  Report 'installed-app' @{ path=$app; hash=(Get-FileHash $app -Algorithm SHA256).Hash; version=(Get-Item $app).VersionInfo.ProductVersion }
  $process = Start-Process $app -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  do {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    if ($process.HasExited) { throw 'Official LocalSend exited before a real window appeared' }
  } until ($process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
  if ($process.MainWindowHandle -eq 0) { throw 'No official LocalSend native window within 60 seconds' }
  Report 'app-window-ready' @{ pid=$process.Id; title=$process.MainWindowTitle; handle=$process.MainWindowHandle.ToInt64(); responding=$process.Responding }
  # Keep the real process and selection state available for subsequent VNC input.
} catch {
  # No password, command line, full registry branch or Panther content is emitted.
  if ($serial -and $serial.IsOpen) {
    $serial.WriteTimeout = 1000
    if ($preparationStage) {
      $safeReasons = @('First-logon network handshake deadline exceeded','Could not start bounded preparation query','Bounded preparation query timed out','Bounded preparation query failed','Unexpected Windows edition or build','Expected interactive Probe first-logon session was not observed','Expected single e1000 adapter was not observed','Expected e1000 adapter is not media disconnected','Expected adapter identity changed during restore')
      $failureReason = 'Preparation runtime or query failure'
      if ($_.Exception.Message -in $safeReasons) { $failureReason = $_.Exception.Message }
      Report 'guest-blocked' @{ preparationStage=$preparationStage; failureReason=$failureReason; errorType=$_.Exception.GetType().Name; hresult=$_.Exception.HResult; handshakeElapsedMs=$handshake.ElapsedMilliseconds }
    } else {
      Report 'guest-blocked' @{ message=$_.Exception.Message }
    }
  }
  exit 1
} finally {
  if ($serial) { $serial.Close(); $serial.Dispose() }
}
