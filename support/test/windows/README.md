# Windows E2E tests

The [workflow](../../../.github/workflows/windows_e2e.yml) runs on every pull request and push to `main`, and supports manual runs. It discovers `e2e/*.e2e.ps1` and runs each file in a separate Windows 11 ARM job. Adding a test requires no workflow change. Helpers belong in `helpers/` and are not discovered as tests.

Each test starts with a short explanation and links to the issues it guards. The file owns its full lifecycle: environment preparation, fixtures and builds, Given–When–Then actions, assertions, evidence, and cleanup. It accepts `-EvidenceDirectory` and exits nonzero on a setup or assertion failure. Keep helpers limited to reusable mechanics; the test file owns its scenario and verdict.

Save images (PNG, JPEG, GIF, WebP) and recordings (MP4, WebM) anywhere inside the evidence directory. The workflow adds an `index.html` gallery with video players and links the downloadable artifact from the run summary, including when a test fails. Extract the artifact and open the gallery to browse screenshots, play recordings, and open original media files alongside the test results and logs. Each test decides what to capture and when; the gallery discovers media without test-specific configuration.

Run a test from the repository root on a disposable Windows VM with an English UI, an interactive desktop, and the Windows SDK:

```powershell
powershell.exe -NoProfile -MTA -ExecutionPolicy Bypass -File support/test/windows/e2e/share_icon.e2e.ps1 -EvidenceDirectory C:\evidence\share_icon
```

## Share icons

`e2e/share_icon.e2e.ps1` guards issue 3495. It builds baseline and candidate installers from identical signed LocalSend 1.18.2 binaries. Only the two visual-resource deployment directives differ. It verifies a working candidate, requires both baseline icon assertions to fail, then verifies the candidate again. Windows 11 ARM runs the x64 installer through emulation.

The test installs runner prerequisites, replaces its LocalSend test installation, and restarts Explorer. It reuses the official signed MSIX helper without signing credentials. Evidence includes screenshots, icon crops, match scores, UI Automation data, installer logs, environment details, and the lifecycle result. The logo similarity threshold is 0.75; verified fixed menu and picker scores are 0.806 and 0.899.
