$ErrorActionPreference = 'Stop'
$serial = New-Object System.IO.Ports.SerialPort 'COM1', 115200, 'None', 8, 'One'
$serial.Open()
function Report([string]$stage, $data) {
  $record = @{ stage=$stage; utc=[DateTime]::UtcNow.ToString('o'); data=$data }
  $serial.WriteLine('ISSUE1054 ' + ($record | ConvertTo-Json -Compress -Depth 8))
}
try {
  $os = Get-CimInstance Win32_OperatingSystem
  Report 'windows-identity' @{ caption=$os.Caption; version=$os.Version; build=$os.BuildNumber; architecture=$os.OSArchitecture; sku=$os.OperatingSystemSKU }
  if ($os.Caption -notmatch 'Enterprise Evaluation' -or $os.Version -notmatch '^10\.0\.19045') { throw 'Unexpected Windows edition or build' }
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
  Report 'guest-blocked' @{ message=$_.Exception.Message }
  exit 1
} finally {
  $serial.Close()
}
