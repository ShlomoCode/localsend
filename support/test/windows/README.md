# Windows E2E tests

These tests verify real Windows desktop behavior and preserve evidence of regressions. See the [workflow](../../../.github/workflows/windows_e2e.yml) for execution settings and the [test files](e2e/) for scenarios and setup requirements.

## Write a regression test

Start each test with a short explanation and links to the issues it guards. Use Given–When–Then to describe the setup, user action, and observable result. The test owns its full lifecycle, including environment preparation, fixtures, assertions, evidence, and cleanup. Keep reusable mechanics in helpers and scenario decisions in the test.

Verify that the test catches the reported defect, not a setup or automation failure. Where possible, compare a failing baseline with a working control under the same conditions.

Run tests in a disposable Windows environment. They can change installed applications and desktop state. Read the test's setup requirements before running it locally.

## Review evidence

Download the evidence artifact from the run summary, extract it, and open `index.html`. Review the captures alongside the test results and logs.

Give screenshots and recordings captions that explain the scenario, what the viewer should inspect, and whether the capture shows an assertion or a diagnostic. Clearly distinguish the baseline, the corrected version, and any control run. See the [report helper](helpers/write_evidence_report.ps1) for the caption format and supported media.

## Share icons

The [share-icon regression test](e2e/share_icon.e2e.ps1) checks the LocalSend logo in Explorer's Share with menu and the Windows Share picker. It requires the baseline to fail specifically on the missing icons and the corrected installer to render both logos.
