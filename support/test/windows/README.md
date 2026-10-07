# Windows share icon regression

The [E2E workflow](../../../.github/workflows/test_windows_share_icon.yml) builds two installers from identical signed LocalSend 1.18.2 binaries. The baseline omits the two visual-resource deployment lines. The candidate uses the repository's Inno Setup recipe.

The Given–When–Then scenario runs on an interactive Windows desktop:

- **Given:** Install LocalSend and select a text file in File Explorer.
- **When:** Open **Share with** and **More options**, select LocalSend once to add it to recent share targets, then reopen **Share with**.
- **Then:** The rendered LocalSend logo matches its reference image in both the share picker and the recent-target submenu.

The workflow verifies a working candidate first, requires both icon assertions to fail on the baseline, and verifies the candidate again. Setup failures fail the workflow. Artifacts include screenshots, icon crops, match scores, UI Automation evidence, installer logs, and environment details.

To test an installer locally, use a disposable Windows VM with an English UI and an interactive desktop. The script replaces its LocalSend test installation and restarts Explorer:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File support/test/windows/share_icon_e2e.ps1 -InstallerPath C:\build\localsend.exe -EvidenceDirectory C:\evidence
```

The installer must include a trusted, signed MSIX helper. The workflow reuses the official signed helper; it does not need signing credentials. Windows 11 ARM runs the x64 installer through emulation. Windows Server 2025 provides an additional x64 check.
