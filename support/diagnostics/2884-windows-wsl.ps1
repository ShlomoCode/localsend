# Source-only Windows 11 Enterprise Evaluation 24H2 / actual WSL2 capability gate.
# Official WSL 3.0.1 switches: microsoft/WSL, tag 3.0.1,
# localization/strings/en-US/Resources.resw (install --from-file/--name/--no-launch).
# No LocalSend application or Docker behavior is tested here.
# Requires the Issue2884 interactive administrator created by the answer file.
[CmdletBinding()]
param([string]$ConfigPath = 'C:\Issue2884\config.json')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = 'C:\Issue2884'
$taskName = 'Issue2884-WSL-Proof'
$phasePath = Join-Path $root 'phase.json'
$stage = 'configuration'
$config = $null
$mutex = $null
$hasMutex = $false
$rebooting = $false
$utf8 = New-Object System.Text.UTF8Encoding($false)
$featureNames = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')
$observedFeatureNames = @('Microsoft-Hyper-V-All') + $featureNames
$wslHash = '28b1a0d013640a2ac95898ea705fa186e5b4ff767a1c1b49257161bc106599c6'
$ubuntuHash = 'bb415d824822c4b878125729af451a5d18fb13d1cf5cbed9a7393ad64ac6039e'
$distro = 'Issue2884Ubuntu'

function Protect-Text([string]$Text) {
    if ($null -ne $config) {
        foreach ($name in @('bearerToken', 'localPassword')) {
            $property = $config.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrEmpty([string]$property.Value)) { $Text = $Text.Replace([string]$property.Value, '[REDACTED]') }
        }
    }
    return $Text
}
function Write-Text([string]$Name, [string]$Text) {
    $safe = Protect-Text $Text
    [IO.File]::WriteAllText((Join-Path $root $Name), $safe, $utf8)
    return $safe
}
function Post-Text([string]$Route, [string]$Text) {
    $request = [Net.HttpWebRequest]::Create($config.bridgeUrl + $Route)
    $request.Proxy = $null
    $request.Method = 'POST'
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.Headers['Authorization'] = 'Bearer ' + $config.bearerToken
    $request.ContentType = 'application/octet-stream'
    $bytes = $utf8.GetBytes((Protect-Text $Text))
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    $response = $request.GetResponse()
    try { if ([int]$response.StatusCode -ne 200) { throw 'Bridge rejected artifact' } } finally { $response.Dispose() }
}
function Send-Text([string]$Name, [string]$Text) {
    $safe = Write-Text $Name $Text
    Post-Text ('/artifact/' + $Name) $safe
}
function Send-Json([string]$Name, $Value) { Send-Text $Name ($Value | ConvertTo-Json -Depth 12) }
function Write-SerialTrace($Value) {
    # Host serial capture remains available if DHCP or the artifact bridge fails.
    # Emit only public status fields; never serialize config, command lines or profiles.
    $serial = New-Object IO.Ports.SerialPort('COM1', 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
    $serial.WriteTimeout = 2000
    try {
        $serial.Open()
        $serial.WriteLine((Protect-Text ($Value | ConvertTo-Json -Depth 4 -Compress)))
    } finally { $serial.Dispose() }
}
function Save-Phase([string]$Phase) {
    $value = @{ phase = $Phase; stage = $stage; utc = [DateTime]::UtcNow.ToString('o') }
    # Local durable state is written before upload/reboot. Only these public fields are exported.
    $null = Write-Text 'phase.json' ($value | ConvertTo-Json)
    Write-SerialTrace $value
    Post-Text '/artifact/phase.json' ([IO.File]::ReadAllText($phasePath))
}
function Quote-Argument([string]$Value) {
    # Windows CommandLineToArgvW quoting; preserve quotes and trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Native([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds, [switch]$LinuxOutput) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $File
    $start.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # wsl.exe emits redirected text as UTF-16LE; other native tools use the OEM code page.
    if ($LinuxOutput) {
        $start.StandardOutputEncoding = $utf8
        $start.StandardErrorEncoding = $utf8
    } elseif ([IO.Path]::GetFileName($File) -ieq 'wsl.exe') {
        $start.StandardOutputEncoding = [Text.Encoding]::Unicode
        $start.StandardErrorEncoding = [Text.Encoding]::Unicode
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start $File" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # Terminate only the process tree rooted at this exact owned process ID.
            $killer = Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList @('/PID', $process.Id, '/T', '/F') -PassThru -WindowStyle Hidden
            try {
                if (-not $killer.WaitForExit(15000)) { $killer.Kill(); throw 'Owned process tree termination timed out' }
                if ($killer.ExitCode -ne 0 -and -not $process.HasExited) { throw 'Owned process tree termination failed' }
            } finally { $killer.Dispose() }
            if (-not $process.WaitForExit(15000)) { throw 'Owned process remained alive after timeout' }
        }
        if (-not $stdoutTask.Wait(15000) -or -not $stderrTask.Wait(15000)) { throw 'Native output pipes did not close within deadline' }
        return [pscustomobject]@{
            executable = [IO.Path]::GetFileName($File); arguments = $Arguments
            exitCode = $process.ExitCode; timedOut = $timedOut
            stdout = (Protect-Text $stdoutTask.Result); stderr = (Protect-Text $stderrTask.Result)
        }
    } finally { $process.Dispose() }
}
function Require-Exit($Result, [int[]]$Allowed = @(0)) {
    if ($Result.timedOut -or $Result.exitCode -notin $Allowed) {
        throw ("Native command failed: {0}; exit={1}; timeout={2}; stderr={3}; stdout={4}" -f $Result.executable, $Result.exitCode, $Result.timedOut, $Result.stderr, $Result.stdout)
    }
}
function Get-Features {
    return @($observedFeatureNames | ForEach-Object {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $_
        @{ name = $_; state = [string]$feature.State }
    })
}
function Read-Capabilities([string]$Label, [switch]$RequireVirtualization) {
    $path = Join-Path $root 'cpuid.exe'
    if (-not (Test-Path -LiteralPath $path)) { $path = Download-Payload 'cpuid.exe' $config.cpuidSha256 }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $config.cpuidSha256) { throw 'Native CPUID helper hash mismatch' }
    $native = Invoke-Native $path @() 10
    Send-Json ('cpuid-' + $Label + '.json') $native
    Require-Exit $native
    $cpuid = $native.stdout | ConvertFrom-Json
    if ($cpuid.schemaVersion -ne 1 -or -not $cpuid.cpuidAvailable -or $cpuid.cpuVendor -cne 'AuthenticAMD') { throw 'Native Windows CPUID identity is invalid' }
    $computer = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $boot = Invoke-Native "$env:SystemRoot\System32\bcdedit.exe" @('/enum', '{current}') 30
    Send-Json ('bcd-' + $Label + '.json') $boot
    Require-Exit $boot
    $value = @{ phase = $Label; utc = [DateTime]::UtcNow.ToString('o'); lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o');
        bootConfiguration = $boot; cpuid = $cpuid; cpuidExecutableSha256 = $actualHash;
        hypervisorPresent = [bool]$computer.HypervisorPresent;
        processors = @(Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, VirtualizationFirmwareEnabled, VMMonitorModeExtensions, SecondLevelAddressTranslationExtensions);
        note = 'CPUID and HypervisorPresent are metadata; only actual WSL2 execution establishes Windows nested virtualization.' }
    Send-Json ('capability-' + $Label + '.json') $value
    # Retain BCD/CIM/raw CPU evidence before rejecting this CPUID-visible route.
    # Masked bits do not establish that all Windows/WSL2 routes are unavailable.
    if ($RequireVirtualization -and (-not $cpuid.flags.svm -or -not $cpuid.flags.npt)) { throw 'Selected pre-feature CPUID-visible SVM/NPT route was not qualified; actual WSL2 remains untested' }
    return $value
}
function Download-Payload([string]$Name, [string]$ExpectedHash) {
    $path = Join-Path $root $Name
    $request = [Net.HttpWebRequest]::Create($config.bridgeUrl + '/payload/' + $Name)
    $request.Proxy = $null
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.Headers['Authorization'] = 'Bearer ' + $config.bearerToken
    $response = $request.GetResponse()
    try {
        $inputStream = $response.GetResponseStream()
        $output = [IO.File]::Create($path)
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $buffer = New-Object byte[] 1048576
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($timer.Elapsed.TotalMinutes -gt 5) { throw 'Payload transfer exceeded 5 minutes' }
                $output.Write($buffer, 0, $count)
            }
        } finally { $output.Dispose(); $inputStream.Dispose() }
    } finally { $response.Dispose() }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedHash) { throw "Pinned SHA256 mismatch for $Name" }
    return $path
}
function Export-SetupLogs {
    foreach ($entry in @(@('setupact.log', 'setupact-redacted.txt'), @('setuperr.log', 'setuperr-redacted.txt'))) {
        $path = Join-Path "$env:SystemRoot\Panther" $entry[0]
        if (Test-Path -LiteralPath $path) { Send-Text $entry[1] ([IO.File]::ReadAllText($path)) }
    }
}
function Clear-TemporaryLogon {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $logon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $logon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $logon -Name DefaultPassword -ErrorAction SilentlyContinue
    Remove-ItemProperty $logon -Name AutoLogonCount -ErrorAction SilentlyContinue
}
function Restart-Proof([string]$Phase) {
    Save-Phase $Phase
    $result = Invoke-Native "$env:SystemRoot\System32\shutdown.exe" @('/r', '/t', '5', '/f') 15
    Require-Exit $result
    $script:rebooting = $true
}

try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $mutex = New-Object Threading.Mutex($false, 'Local\Issue2884-WSL-Proof')
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { return }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($config.bridgeUrl -cne 'http://10.0.2.2:8765' -or $config.bearerToken -notmatch '^[a-f0-9]{64}$' -or $config.localPassword -notmatch '^[a-f0-9]{32,128}$') {
        throw 'Invalid ephemeral bridge configuration'
    }
    if ($config.wslSha256 -cne $wslHash -or $config.ubuntuSha256 -cne $ubuntuHash) { throw 'Host payload pins do not match source pins' }
    if ($config.cpuidSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Native CPUID helper pin is missing' }
    $phase = 'initial'
    if (Test-Path -LiteralPath $phasePath) { $phase = (Get-Content -LiteralPath $phasePath -Raw | ConvertFrom-Json).phase }
    if ($phase -in @('complete', 'failed')) { return }
    if ($phase -notin @('initial', 'ordinary_reboot_pending', 'features_reboot_pending', 'msi_reboot_pending')) { throw 'Unexpected phase; refusing a reboot loop' }

    $stage = 'windows_identity'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $localUser = Get-LocalUser -Name Issue2884
    if ($identity.User.Value -ne $localUser.SID.Value -or -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Proof requires the same elevated interactive Issue2884 local administrator; SYSTEM is forbidden'
    }
    if ([Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'WSL proof cannot run in session zero' }
    $os = Get-CimInstance Win32_OperatingSystem
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $windows = @{ caption = $os.Caption; build = $os.BuildNumber; version = $os.Version; displayVersion = $version.DisplayVersion; edition = $version.EditionID; architecture = $env:PROCESSOR_ARCHITECTURE; user = $identity.Name; sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId }
    Send-Json 'windows-identity.json' $windows
    if ($windows.build -ne '26100' -or $windows.displayVersion -ne '24H2' -or $windows.edition -ne 'EnterpriseEval' -or $windows.architecture -ne 'AMD64' -or -not [Environment]::Is64BitProcess) {
        throw 'Native Windows identity is not x64 Windows 11 Enterprise Evaluation 24H2 build 26100'
    }
    $stage = 'firmware_identity'
    $secureBoot = Confirm-SecureBootUEFI
    $tpm = Get-Tpm
    $tpmSpec = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm
    Send-Json 'firmware.json' @{ secureBoot = $secureBoot; tpmPresent = $tpm.TpmPresent; tpmReady = $tpm.TpmReady; tpmSpecVersion = $tpmSpec.SpecVersion; tpmManufacturer = $tpm.ManufacturerIdTxt }
    if (-not $secureBoot -or -not $tpm.TpmPresent -or -not $tpm.TpmReady -or $tpmSpec.SpecVersion -notmatch '(^|,\s*)2\.0(,|$)') { throw 'UEFI Secure Boot and ready TPM 2.0 are required' }

    if ($phase -eq 'initial') {
        $stage = 'pre_feature_capability'
        $before = Get-Features
        Send-Json 'feature-before.json' $before
        $initial = Read-Capabilities 'initial' -RequireVirtualization
        if (@($before | Where-Object { $_.state -ne 'Disabled' }).Count -ne 0) { throw 'Ordinary reboot control requires all observed virtualization features disabled' }
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Issue2884\2884-windows-wsl.ps1'
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force | Out-Null
        # Normal native boot logging applies to both the ordinary control and
        # the feature boot. It changes no recovery or hardware requirements.
        $bootLog = Invoke-Native "$env:SystemRoot\System32\bcdedit.exe" @('/set', '{current}', 'bootlog', 'Yes') 30
        Send-Json 'bcd-enable-bootlog.json' $bootLog
        Require-Exit $bootLog
        $stage = 'ordinary_feature_free_reboot'
        Restart-Proof 'ordinary_reboot_pending'
        return
    }
    if ($phase -eq 'ordinary_reboot_pending') {
        $stage = 'ordinary_reboot_control'
        $before = Get-Features
        Send-Json 'feature-ordinary.json' $before
        $ordinary = Read-Capabilities 'ordinary' -RequireVirtualization
        $initial = Get-Content -LiteralPath (Join-Path $root 'capability-initial.json') -Raw | ConvertFrom-Json
        if (@($before | Where-Object { $_.state -ne 'Disabled' }).Count -ne 0 -or $ordinary.lastBootUtc -eq $initial.lastBootUtc) { throw 'Ordinary reboot did not establish a fresh feature-free boot' }
        $control = @{ status = 'PASS'; stage = $stage; beforeBootUtc = $initial.lastBootUtc; afterBootUtc = $ordinary.lastBootUtc;
            featureStates = $before; cpuidExecutableSha256 = $ordinary.cpuidExecutableSha256; cpuid = $ordinary.cpuid;
            windows = $windows; secureBoot = $secureBoot; tpmReady = $tpm.TpmReady }
        Send-Json 'ordinary-reboot-control.json' $control
        $stage = 'enable_supported_wsl_features'
        foreach ($name in $featureNames) {
            $command = "`$ErrorActionPreference='Stop'; Enable-WindowsOptionalFeature -Online -FeatureName '$name' -All -NoRestart | ConvertTo-Json -Compress"
            $enabled = Invoke-Native "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile', '-Command', $command) 300
            Send-Json ('enable-' + $name + '.json') $enabled
            Require-Exit $enabled
        }
        Send-Json 'feature-pending.json' (Get-Features)
        $bcd = Invoke-Native "$env:SystemRoot\System32\bcdedit.exe" @('/set', 'hypervisorlaunchtype', 'auto') 30
        Send-Json 'bcd-enable-auto.json' $bcd
        Require-Exit $bcd
        Restart-Proof 'features_reboot_pending'
        return
    }
    $stage = 'supported_features_after_reboot'
    $capability = Read-Capabilities $phase
    $after = Get-Features
    Send-Json 'feature-after.json' $after
    if (@($after | Where-Object { $_.name -in $featureNames -and $_.state -ne 'Enabled' }).Count -ne 0 -or
        @($after | Where-Object { $_.name -eq 'Microsoft-Hyper-V-All' -and $_.state -eq 'Disabled' }).Count -ne 1) { throw 'Supported WSL feature pair must be enabled without the full Hyper-V role' }
    $computer = Get-CimInstance Win32_ComputerSystem
    $boot = $capability.bootConfiguration
    if ($boot.stdout -notmatch '(?im)^hypervisorlaunchtype\s+Auto\s*$') { throw 'Native boot configuration does not enable hypervisor launch' }

    if ($phase -eq 'features_reboot_pending') {
        $stage = 'install_pinned_wsl'
        $msi = Download-Payload 'wsl.msi' $wslHash
        $signature = Get-AuthenticodeSignature -LiteralPath $msi
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'WSL MSI must have a valid Microsoft Authenticode signature' }
        $installed = Invoke-Native "$env:SystemRoot\System32\msiexec.exe" @('/i', $msi, '/qn', '/norestart') 300
        Require-Exit $installed @(0, 3010)
        # Always reboot once after MSI installation, including a successful no-restart install.
        Restart-Proof 'msi_reboot_pending'
        return
    }
    $stage = 'wsl_identity'
    $wsl = "$env:SystemRoot\System32\wsl.exe"
    $wslVersion = Invoke-Native $wsl @('--version') 60
    Send-Text 'wsl-version.txt' ($wslVersion | ConvertTo-Json -Depth 4)
    Require-Exit $wslVersion
    if ($wslVersion.stdout -notmatch '(?m)^WSL version:\s*3\.0\.1\.0\s*$') { throw 'Installed WSL version is not the pinned 3.0.1.0 release' }
    $default = Invoke-Native $wsl @('--set-default-version', '2') 60
    Require-Exit $default
    $ubuntu = Download-Payload 'ubuntu.wsl' $ubuntuHash
    $install = Invoke-Native $wsl @('--install', '--from-file', $ubuntu, '--name', $distro, '--no-launch', '--version', '2') 300
    Require-Exit $install
    $list = Invoke-Native $wsl @('--list', '--verbose') 60
    Send-Text 'wsl-list.txt' ($list | ConvertTo-Json -Depth 4)
    Require-Exit $list
    if ($list.stdout -notmatch '(?m)^\s*\*?\s*Issue2884Ubuntu\s+\S+\s+2\s*$') { throw 'The exact installed distribution does not report WSL version 2' }

    $stage = 'actual_wsl2_execution'
    $marker = 'ISSUE2884_ACTUAL_WSL2_EXECUTION'
    $linuxCommand = 'set -eu; printf "ISSUE2884_ACTUAL_WSL2_EXECUTION\n"; uname -r; cat /proc/version; cat /etc/os-release'
    $execution = Invoke-Native $wsl @('-d', $distro, '-u', 'root', '--exec', '/bin/sh', '-c', $linuxCommand) 300 -LinuxOutput
    Send-Text 'wsl-command.txt' ($execution | ConvertTo-Json -Depth 4)
    Require-Exit $execution
    $linuxText = $execution.stdout
    $markerFound = $linuxText -match '(?m)^ISSUE2884_ACTUAL_WSL2_EXECUTION\s*$'
    $kernelFound = $linuxText -match '(?im)^\S*microsoft-standard-WSL2\S*\s*$'
    $procFound = $linuxText -match '(?im)^Linux version .*microsoft.*WSL2'
    $ubuntuFound = $linuxText -match '(?m)^ID=ubuntu\s*$' -and $linuxText -match '(?m)^VERSION_ID="24\.04"\s*$'
    $msiActualHash = (Get-FileHash -LiteralPath (Join-Path $root 'wsl.msi') -Algorithm SHA256).Hash.ToLowerInvariant()
    $ubuntuActualHash = (Get-FileHash -LiteralPath $ubuntu -Algorithm SHA256).Hash.ToLowerInvariant()
    $msiSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $root 'wsl.msi')
    if ($msiActualHash -cne $wslHash -or $ubuntuActualHash -cne $ubuntuHash -or $msiSignature.Status -ne 'Valid' -or $null -eq $msiSignature.SignerCertificate -or $msiSignature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Final payload hash/signature recheck failed' }
    $proof = @{ stage = $stage; distribution = $distro; distributionVersion = 2; wslVersion = '3.0.1.0'; wslMsiSha256 = $msiActualHash; wslMsiSignatureStatus = [string]$msiSignature.Status; wslMsiSigner = $msiSignature.SignerCertificate.Subject; ubuntuPayloadSha256 = $ubuntuActualHash; windows = $windows; secureBoot = $secureBoot; tpmPresent = $tpm.TpmPresent; tpmReady = $tpm.TpmReady; tpmSpecVersion = $tpmSpec.SpecVersion; featureStates = $after; hypervisorPresent = [bool]$computer.HypervisorPresent; cpuid = $capability.cpuid; cpuidExecutableSha256 = $capability.cpuidExecutableSha256; exitCode = $execution.exitCode; timedOut = $execution.timedOut; marker = $marker; markerMatched = $markerFound; kernelMatched = $kernelFound; procVersionMatched = $procFound; ubuntuIdentityMatched = $ubuntuFound; linuxOutput = $linuxText }
    Send-Json 'wsl-proof.json' $proof
    if (-not ($markerFound -and $kernelFound -and $procFound -and $ubuntuFound)) { throw 'Actual Linux output did not establish the marker, Microsoft WSL2 kernel and Ubuntu 24.04 identity' }
    Export-SetupLogs
    Clear-TemporaryLogon
    Write-SerialTrace @{ status = 'PASS'; stage = $stage; exitCode = $execution.exitCode; markerMatched = $markerFound; kernelMatched = $kernelFound; procVersionMatched = $procFound }
    Save-Phase 'complete'
    Post-Text '/result' (@{ status = 'PASS'; stage = $stage; scope = 'Supported Windows 24H2 and actual Hyper-V-backed WSL2 execution only'; proof = $proof } | ConvertTo-Json -Depth 12)
} catch {
    # A JSON parser error may quote malformed secret input before config can be read.
    $errorText = 'Ephemeral configuration is invalid or unreadable'
    if ($stage -ne 'configuration') { $errorText = Protect-Text $_.Exception.Message }
    $failure = @{ status = 'FAIL'; stage = $stage; error = $errorText; utc = [DateTime]::UtcNow.ToString('o') }
    $null = Write-Text 'proof-error.json' ($failure | ConvertTo-Json -Depth 4)
    try { Write-SerialTrace $failure } catch { $null = Write-Text 'serial-error.txt' (Protect-Text $_.Exception.Message) }
    try { Save-Phase 'failed'; Send-Json 'proof-error.json' $failure; Export-SetupLogs } catch { $null = Write-Text 'proof-error.json' ($failure | ConvertTo-Json -Depth 4) }
    try { Clear-TemporaryLogon } catch { }
    try { Post-Text '/result' ($failure | ConvertTo-Json -Depth 4) } catch { }
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    if ($hasMutex -and -not $rebooting) {
        # Deliberately power off the guest so QEMU terminates naturally.
        try { $shutdown = Invoke-Native "$env:SystemRoot\System32\shutdown.exe" @('/s', '/t', '5', '/f') 15; Require-Exit $shutdown } catch { }
    }
}
