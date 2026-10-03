# Linux E2E release checks

Before a release, start **Linux E2E** from GitHub Actions with **Run workflow** and choose the branch or tag containing the release candidate. The job builds that revision once, packages the same bundle as a real Flatpak, starts KDE Plasma on Linux with a real session D-Bus, and runs every `linux_*_e2e.py` test. It runs only when triggered manually. A failed test makes the job fail; the uploaded artifact includes the source revision, per-test output and application logs, a JSON report, the Flatpak preparation log, and the Plasma session log.

The Flatpak package starts from LocalSend's current Flathub deployment. It keeps the Freedesktop runtime, Ayatana libraries, permissions, and exported icons, then replaces the executable and Flutter assets with the bundle built from the selected revision. The test launches that installed package through `flatpak run`, checks `/.flatpak-info` in its sandbox, and reads its KDE StatusNotifierItem through the host session D-Bus. GTK resolves themed icons from the host's exported icon directory; cache icons must be directly readable on the host. The icon file's bytes must match the selected light or dark asset. The test keeps the same Flatpak instance and tray item across live theme changes, then checks a fresh startup in the other theme.

From a terminal, the equivalent trigger is `gh workflow run linux-tray-e2e.yml --ref <release-branch-or-tag>`.

Locally, install Flatpak, the official LocalSend Flathub app, Python GTK introspection, and a Linux release bundle. Package the bundle before starting a fresh KDE session:

```bash
python3 support/tests/prepare_flatpak_e2e.py app/build/linux/x64/release/bundle --output linux-e2e-flatpak
```

In that KDE session with D-Bus, include `$HOME/.local/share/flatpak/exports/share` in `XDG_DATA_DIRS` and run:

```bash
python3 support/tests/run_linux_e2e.py app/build/linux/x64/release/bundle --output linux-e2e-results
```

Each discovered test receives the bundle path and `--log <path>` for its application log. Add a test as `support/tests/linux_<feature>_e2e.py`, return zero only on success, and clean up its application processes and session changes before exiting. The runner executes all tests even if one fails and records each exit code in `report.json`.
