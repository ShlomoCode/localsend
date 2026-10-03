# Linux E2E release checks

Before a release, start **Linux E2E** from GitHub Actions with **Run workflow** and choose the branch or tag containing the release candidate. The job builds that revision once, starts KDE Plasma on Linux with a real session D-Bus, and runs every `linux_*_e2e.py` test. It runs only when triggered manually. A failed test makes the job fail; the uploaded artifact includes the source revision, per-test output and application logs, a JSON report, and the Plasma session log.

From a terminal, the equivalent trigger is `gh workflow run linux-tray-e2e.yml --ref <release-branch-or-tag>`.

Locally, in an active KDE session with D-Bus, build the Linux release bundle and run:

```bash
python3 support/tests/run_linux_e2e.py app/build/linux/x64/release/bundle --output linux-e2e-results
```

Each discovered test receives the bundle path and `--log <path>` for its application log. Add a test as `support/tests/linux_<feature>_e2e.py`, return zero only on success, and clean up its application processes and session changes before exiting. The runner executes all tests even if one fails and records each exit code in `report.json`.
