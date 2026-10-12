param([Parameter(Mandatory)] [string]$Evidence, [Parameter(Mandatory)] [DateTime]$Deadline)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
New-Item -ItemType Directory -Force $Evidence | Out-Null
Start-Transcript (Join-Path $Evidence worker-transcript.txt)
$script:Stage = "desktop"
$script:Status = "ENV_BLOCK"
$script:OwnedInstallation = $false
function Check-Budget {
    if ([DateTime]::UtcNow -ge $Deadline) { throw "ENV_BLOCK: task deadline reached" }
    $bytes = (Get-ChildItem $Evidence -File -Recurse | Measure-Object Length -Sum).Sum
    if ($bytes -gt 768MB) { throw "ENV_BLOCK: 768 MiB evidence budget reached; preserve existing originals" }
}
. (Join-Path $PSScriptRoot ui.ps1)
. (Join-Path $PSScriptRoot inventory.ps1)
try {
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, ProductType |
        ConvertTo-Json | Set-Content (Join-Path $Evidence environment.json)
    $PSVersionTable | Out-String | Set-Content (Join-Path $Evidence powershell.txt)
    whoami.exe /all | Out-File (Join-Path $Evidence account.txt)
    query.exe session | Out-File (Join-Path $Evidence sessions.txt)
    Get-Service AppXSvc, StateRepository, ClipSVC -ErrorAction Continue | Format-List * | Out-File (Join-Path $Evidence services.txt)
    Get-Command Add-AppxPackage | Format-List * | Out-File (Join-Path $Evidence Add-AppxPackage-command.txt)
    Get-AppxPackage | Format-List * | Out-File (Join-Path $Evidence ordinary-Appx-inventory.txt)
    if (-not [Environment]::Is64BitProcess -or -not [Environment]::UserInteractive) { throw "ENV_BLOCK: interactive native x64 PowerShell required" }
    if ((App-Processes).Count -gt 0 -or (Get-AppxPackage LocalSend.App)) { throw "ENV_BLOCK: pre-existing LocalSend; preserve unrelated installation" }
    if (Test-Path "$env:ProgramFiles\LocalSend") { throw "ENV_BLOCK: pre-existing install directory" }
    $desktopHandle = [Issue3456Native]::OpenInputDesktop(0, $false, 0x0100)
    if ($desktopHandle -eq [IntPtr]::Zero) { throw "ENV_BLOCK: input desktop inaccessible" }
    [Issue3456Native]::CloseDesktop($desktopHandle) | Out-Null
    Save-Desktop desktop-initial
    Save-Tree desktop-initial
    # Prove foreground and keyboard delivery on a fresh native window.
    $note = Start-Process notepad.exe -PassThru
    $noteWindow = Wait-Ui @("Untitled - Notepad")
    Focus-Window $noteWindow
    Send-Keys "issue3456-input-ready"
    Save-Desktop input-ready
    $edit = Wait-Ui @("Text Editor", "Text editor") $noteWindow
    $text = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($text -notlike "*issue3456-input-ready*") { throw "ENV_BLOCK: keyboard delivery control failed" }
    $note.Kill()
    if (-not (Get-Command Add-AppxPackage).Parameters.ContainsKey("ExternalLocation")) { throw "ENV_BLOCK: sparse external-location API missing" }
    $script:Stage = "artifact-download"
    $work = Join-Path $env:RUNNER_TEMP Issue3456
    New-Item -ItemType Directory -Force $work | Out-Null
    foreach ($artifact in @(
        @{ File = "LocalSend-1.18.2-windows-x86-64.exe"; Sha = "122783e6abb4b0a1f1603d896f46a03aeda3004479ebd3175cab4ddac6b60919" },
        @{ File = "LocalSend-1.18.2-windows-x86-64.zip"; Sha = "737aab1829d901e1d798cddd1e5fdc06ba9dfcc9ea50cfe3805e047005d5e71a" }
    )) {
        Check-Budget
        $path = Join-Path $work $artifact.File
        Invoke-WebRequest "https://github.com/localsend/localsend/releases/download/v1.18.2/$($artifact.File)" -OutFile $path -TimeoutSec 90
        $hash = (Get-FileHash $path -Algorithm SHA256).Hash
        Write-Event officialArtifact @{ File = $artifact.File; Sha256 = $hash }
        if ($hash -ne $artifact.Sha) { throw "ENV_BLOCK: official artifact hash mismatch" }
    }
    $installer = Join-Path $work LocalSend-1.18.2-windows-x86-64.exe
    $signature = Get-AuthenticodeSignature $installer
    $signature | Format-List * | Out-File (Join-Path $Evidence installer-signature.txt)
    if ($signature.Status -ne "Valid") { throw "ENV_BLOCK: official installer signature is not valid" }
    $script:Stage = "ordinary-install"
    $script:ExpectedExe = "$env:ProgramFiles\LocalSend\localsend_app.exe"
    Assert-CleanLaunch
    Start-Clip ordinary-install
    $setup = Start-Process $installer -ArgumentList "/LOG=`"$(Join-Path $Evidence installer-original.log)`"" -PassThru
    [ordered]@{ Id = $setup.Id; Path = $installer; StartUtc = $setup.StartTime.ToUniversalTime().ToString("o") } |
        ConvertTo-Json | Set-Content (Join-Path $Evidence owned-installer.json)
    # Keep default privilege choice and default directory. No silent flags or package registration commands.
    $language = Find-Ui @("English")
    if ($language) { Click-Ui (Wait-Ui @("OK")) }
    $end = [DateTime]::UtcNow.AddSeconds(100)
    $selectedDesktop = $false; $clickedFinish = $false
    do {
        Check-Budget
        $mode = Find-Ui @("Install for all users (recommended)")
        if ($mode) { Save-Desktop installer-default-mode; Click-Ui $mode }
        $task = Find-Ui @("Create a desktop shortcut")
        if ($task) {
            $toggle = $task.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::Off) { Click-Ui $task }
            $selectedDesktop = $true
        }
        $finish = Find-Ui @("Finish")
        if ($finish) { Save-Desktop installer-finish; Click-Ui $finish; $clickedFinish = $true; break }
        $button = Find-Ui @("Next >", "Next", "Install", "OK")
        if ($button) { Click-Ui $button }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $end)
    Stop-Clip
    $installDir = "$env:ProgramFiles\LocalSend"
    if (Test-Path $installDir) {
        $script:OwnedInstallation = $true
        Set-Content (Join-Path $Evidence owned-install.txt) $installDir
        # Preserve raw installed bytes even when a later environment gate fails.
        Save-InstalledInventory $installDir
    }
    if (-not $selectedDesktop -or -not $clickedFinish) { throw "ENV_BLOCK: ordinary wizard/desktop shortcut/first-launch path incomplete" }
    $first = Wait-App
    if (-not $first) { throw "ENV_BLOCK: first ordinary launch unavailable" }
    Save-Desktop first-launch
    Save-Tree first-launch
    Write-Event firstLaunch @{ Pid = $first.Id; Path = $first.Path; Handle = "$($first.MainWindowHandle)" }
    Save-PackageInventory at-first-launch | Out-Null
    $end = [DateTime]::UtcNow.AddSeconds(25)
    do { $package = @(Get-AppxPackage LocalSend.App); if ($package.Count -eq 1) { break }; Start-Sleep -Milliseconds 500 } while ([DateTime]::UtcNow -lt $end)
    Save-PackageInventory after-first-launch | Out-Null
    if ($package.Count -ne 1) { throw "ENV_BLOCK: ordinary installation did not register one sparse identity" }
    $actualExe = Join-Path $installDir localsend_app.exe
    [xml]$sidecar = Get-Content "$actualExe.manifest" -Raw
    [xml]$helper = Get-Content (Join-Path $Evidence installed/helper-AppxManifest.xml) -Raw
    [xml]$embedded = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $Evidence installed/embedded-RT_MANIFEST.bin)))
    $identity = $helper.Package.Identity
    $msixNode = $sidecar.SelectSingleNode("//*[local-name()=msix]")
    if (-not $msixNode) { $msixNode = $embedded.SelectSingleNode("//*[local-name()=msix]") }
    Write-Event identity @{ Sidecar = $sidecar.OuterXml; Embedded = $embedded.OuterXml; HelperPublisher = $identity.Publisher; RegisteredPublisher = $package[0].Publisher }
    if (-not $msixNode -or $msixNode.publisher -ne $identity.Publisher -or $package[0].Publisher -ne $identity.Publisher -or
        $msixNode.packageName -ne $identity.Name -or $msixNode.applicationId -ne $helper.Package.Applications.Application.Id -or
        $msixNode.NamespaceURI -ne "urn:schemas-microsoft-com:msix.v1") { throw "ENV_BLOCK: measured sparse identity contract mismatch; preserve inventory for analysis" }
    # About text is an independent app-level receipt when the accessible control exists.
    $about = Find-Ui @("About")
    if ($about) { Click-Ui $about; Save-Desktop app-about; Save-Tree app-about; Send-Keys "{ESC}" }
    else { Write-Event appVersionLimit @{ AboutAccessible = $false; Build64Verified = $false; Receipt = "Installed EXE file/product version retained; +64 app-level version unverified" } }
    $script:Stage = "share-qualification"
    Initialize-NativePicker
    try {
        $null = [Windows.ApplicationModel.DataTransfer.DataTransferManager,Windows.ApplicationModel.DataTransfer,ContentType=WindowsRuntime]
        $supported = [Windows.ApplicationModel.DataTransfer.DataTransferManager]::IsSupported()
        Write-Event DataTransferManager @{ IsSupported = $supported }
        if (-not $supported) { throw "DataTransferManager.IsSupported returned false" }
    } catch { throw "ENV_BLOCK: Share API qualification failed: $_" }
    Quit-App
    $script:Stage = "native-relaunch"
    foreach ($method in @("start-menu", "desktop-shortcut")) {
        foreach ($attempt in 1..2) {
            Assert-CleanLaunch
            Start-Clip "$method-$attempt"
            if ($method -eq "start-menu") {
                Send-Keys "^{ESC}"
                Send-Keys "LocalSend"
                $entry = Wait-StartMenuEntry
                Save-Desktop "$method-$attempt-before"
                Click-Ui $entry
            } else {
                $desktopFolder = if (Test-Path "$env:PUBLIC\Desktop\LocalSend.lnk") { "$env:PUBLIC\Desktop" } else { "$env:USERPROFILE\Desktop" }
                Start-Process explorer.exe -ArgumentList "`"$desktopFolder`""
                $window = Wait-Ui @("Desktop", "Desktop - File Explorer")
                Focus-Window $window
                Click-Ui (Wait-Ui @("LocalSend", "LocalSend.lnk") $window) -Double
            }
            $app = Wait-App
            Save-Desktop "$method-$attempt-result"
            Save-Tree "$method-$attempt-result"
            Write-Event relaunch @{ Method = $method; Attempt = $attempt; Opened = [bool]$app; Pid = $(if ($app) { $app.Id } else { $null }) }
            Save-PackageInventory "$method-$attempt" | Out-Null
            Stop-Clip
            if ($app) { Quit-App } else { Send-Keys "{ESC}" }
        }
    }
    $script:Stage = "powershell-controls"
    foreach ($method in @("Start-Process", "direct-ampersand")) {
        Assert-CleanLaunch
        Start-Clip $method
        try {
            if ($method -eq "Start-Process") { Start-Process -FilePath $actualExe -PassThru | Format-List * | Out-File (Join-Path $Evidence StartProcess-original.txt) }
            else {
                # Keep '&' in its own native PowerShell so an interactive GUI wait cannot deadlock the driver.
                $direct = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot direct-control.ps1)`" -Exe `"$actualExe`" -Evidence `"$Evidence`"" -PassThru -RedirectStandardOutput (Join-Path $Evidence direct-child-stdout-original.txt) -RedirectStandardError (Join-Path $Evidence direct-child-stderr-original.txt)
                Write-Event directInvocation @{ PowerShellPid = $direct.Id; Exe = $actualExe; Syntax = "&" }
            }
            $app = Wait-App
            Write-Event launchControl @{ Method = $method; Opened = [bool]$app }
        } catch {
            $_ | Format-List * -Force | Out-File (Join-Path $Evidence "$method-original-error.txt")
            $_.Exception | Format-List * -Force | Out-File (Join-Path $Evidence "$method-exception.txt")
            Write-Event launchError @{ Method = $method; HResult = $_.Exception.HResult; NativeErrorCode = $_.Exception.NativeErrorCode; Message = $_.Exception.Message }
        }
        Save-Desktop "$method-result"
        Save-PackageInventory $method | Out-Null
        Stop-Clip
        Quit-App
    }
    $script:Stage = "official-portable-control"
    $portable = Join-Path $env:USERPROFILE Issue3456Portable
    Expand-Archive (Join-Path $work LocalSend-1.18.2-windows-x86-64.zip) $portable
    $portableExe = @(Get-ChildItem $portable -Filter localsend_app.exe -Recurse)[0].FullName
    if (-not $portableExe) { throw "ENV_BLOCK: portable executable missing" }
    $portableRoot = Split-Path $portableExe
    if ((Test-Path "$portableExe.manifest") -or (Get-ChildItem $portableRoot -Filter *.msix)) { throw "ENV_BLOCK: portable control unexpectedly has sparse payload" }
    # LocalSend selects this external portable settings file when it exists. Executable/signature remain unchanged.
    Set-Content (Join-Path $portableRoot settings.json) "{}"
    Get-FileHash $portableExe | Format-List * | Out-File (Join-Path $Evidence portable-exe-hash.txt)
    (Get-Item $portableExe).VersionInfo | Format-List * | Out-File (Join-Path $Evidence portable-version.txt)
    Get-AuthenticodeSignature $portableExe | Format-List * | Out-File (Join-Path $Evidence portable-signature.txt)
    foreach ($attempt in 1..2) {
        $script:ExpectedExe = $portableExe
        Assert-CleanLaunch
        Start-Clip "portable-$attempt"
        Start-Process $portableExe
        $app = Wait-App
        if (-not $app) { throw "ENV_BLOCK: ordinary portable working control unavailable" }
        Save-Desktop "portable-$attempt"
        Write-Event portableControl @{ Attempt = $attempt; Pid = $app.Id; Exe = $portableExe; SeparateProfile = (Join-Path $portableRoot settings.json) }
        Stop-Clip
        Quit-App
    }
    Copy-Item (Join-Path $portableRoot settings.json) (Join-Path $Evidence portable-settings-final.json)
    $script:Stage = "actual-explorer-share"
    $script:ExpectedExe = $actualExe
    Assert-CleanLaunch
    $fixtureDir = Join-Path $env:USERPROFILE Issue3456Fixture
    New-Item -ItemType Directory -Force $fixtureDir | Out-Null
    $fixture = Join-Path $fixtureDir share-3456.txt
    Set-Content $fixture "Issue 3456 unchanged official installer native Explorer Share fixture"
    Get-FileHash $fixture | Format-List * | Out-File (Join-Path $Evidence fixture-hash.txt)
    Start-Clip explorer-share-delivery
    Open-Share $fixtureDir | Out-Null
    Click-Ui (Wait-NativePickerTarget)
    $shared = Wait-App
    if (-not $shared) { throw "ENV_BLOCK: Share target did not open app" }
    $appWindow = [System.Windows.Automation.AutomationElement]::FromHandle($shared.MainWindowHandle)
    Wait-Ui @("share-3456.txt") $appWindow | Out-Null
    Save-Desktop share-delivered
    Save-Tree share-delivered
    Write-Event actualExplorerShare @{ Fixture = $fixture; AppPid = $shared.Id; DeliveredFilename = "share-3456.txt"; OtherTargetControl = "not exercised; LocalSend delivery is the end-to-end control" }
    Stop-Clip
    Quit-App
    $script:Status = "SCREENING_COMPLETE"
} catch {
    $script:Failure = "$_"
    $_ | Format-List * -Force | Out-File (Join-Path $Evidence original-error.txt)
    $_.Exception | Format-List * -Force | Out-File (Join-Path $Evidence original-exception.txt)
    try { Save-Desktop failure; Save-Tree failure } catch { "$_" | Set-Content (Join-Path $Evidence capture-failure.txt) }
} finally {
    try { Stop-Clip } catch { "$_" | Set-Content (Join-Path $Evidence recording-stop-error.txt) }
    [ordered]@{ Status = $script:Status; Stage = $script:Stage; Error = $script:Failure; EnvironmentDelta = "Native Windows Server 2022 x64; reporter Windows 10 Pro 19045 x64"; ProductVerdict = "NONE; raw screening observations require evidence review"; OwnedInstallation = $script:OwnedInstallation } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence result.json)
    Stop-Transcript
}
if ($script:Status -ne "SCREENING_COMPLETE") { exit 2 }
