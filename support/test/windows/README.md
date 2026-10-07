# Windows share icon regression

The [E2E workflow](../../../.github/workflows/test_windows_share_icon.yml) builds two installers from identical signed LocalSend 1.18.2 binaries. The baseline omits the two visual-resource deployment lines. The candidate uses the repository's Inno Setup recipe.

The Given–When–Then scenario runs on an interactive Windows desktop:

- **Given:** Install LocalSend and select a text file in File Explorer.
- **When:** Open **Share with** and **More options**, select LocalSend once to add it to recent share targets, then reopen **Share with**.
- **Then:** The rendered LocalSend logo matches its reference image in both the share picker and the recent-target submenu.

The workflow verifies a working candidate first, requires both icon assertions to fail on the baseline, and verifies the candidate again. Setup failures fail the workflow. Artifacts include screenshots, icon crops, match scores, UI Automation evidence, installer logs, and environment details.

To test an installer locally, use a disposable Windows VM with an English UI, an interactive desktop, and the Windows SDK. Generate the native UI Automation interop assembly first. The script replaces its LocalSend test installation and restarts Explorer:

```powershell
$tlbimp = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows" -Filter TlbImp.exe -Recurse | Select-Object -First 1
$env:UIA3_INTEROP_PATH = Join-Path $env:TEMP 'LocalSend.UIA3.dll'
& $tlbimp.FullName "$env:WINDIR\System32\UIAutomationCore.dll" /namespace:LocalSend.UIA3 "/out:$env:UIA3_INTEROP_PATH" /silent
powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File support/test/windows/share_icon_e2e.ps1 -InstallerPath C:\build\localsend.exe -EvidenceDirectory C:\evidence
```

The installer must include a trusted, signed MSIX helper. The workflow reuses the official signed helper; it does not need signing credentials. Windows 11 ARM runs the x64 installer through emulation. The logo similarity threshold is 0.75; verified fixed menu and picker scores are 0.806 and 0.899.
