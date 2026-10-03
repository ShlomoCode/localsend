# Linux E2E release checks

Before a release, start **Linux E2E** from GitHub Actions with **Run workflow** and choose the branch or tag containing the release candidate. The job builds that revision once, packages the same bundle as a real Flatpak, starts KDE Plasma on Linux with a real session D-Bus, and runs the pytest suite in `support/tests/linux_e2e/`. It runs only when triggered manually. Leave packaging set to `all` and the test filter empty for a release check; choose `native` or `flatpak` and a pytest `-k` expression for a focused run. Native-only runs skip Flatpak packaging. A failed test makes the job fail; the uploaded artifact includes the source revision, pytest results and application logs, JSON and JUnit reports, the Flatpak preparation log, and the Plasma session log.

The Flatpak package starts from LocalSend's current Flathub deployment. It keeps the Freedesktop runtime, Ayatana libraries, permissions, and exported icons, then replaces the executable and Flutter assets with the bundle built from the selected revision. The test launches that installed package through `flatpak run`, checks `/.flatpak-info` in its sandbox, and reads its KDE StatusNotifierItem through the host session D-Bus. GTK resolves themed icons from the host's exported icon directory; cache icons must be directly readable on the host. The icon file's bytes must match the selected light or dark asset. The test keeps the same Flatpak instance and tray item across live theme changes, then checks a fresh startup in the other theme.

From a terminal, the equivalent trigger is `gh workflow run linux-e2e.yml --ref <release-branch-or-tag>`.

Locally, install Flatpak, the official LocalSend Flathub app, Python GTK introspection, and a Linux release bundle. Package the bundle before starting a fresh KDE session:

```bash
python3 support/tests/prepare_flatpak_e2e.py app/build/linux/x64/release/bundle --output linux-e2e-flatpak
```

Create the test environment with system packages enabled so Python can use the host's GTK introspection:

```bash
python3 -m venv --system-site-packages /tmp/localsend-e2e-venv
/tmp/localsend-e2e-venv/bin/python -m pip install -r support/tests/requirements.txt
```

In that KDE session with D-Bus, include `$HOME/.local/share/flatpak/exports/share` in `XDG_DATA_DIRS` and run:

```bash
/tmp/localsend-e2e-venv/bin/python support/tests/run_linux_e2e.py app/build/linux/x64/release/bundle --output linux-e2e-results
```

Add scenarios as `test_*.py` in `support/tests/linux_e2e/`. The `desktop` fixture sets and restores KDE themes; `launch_app` starts and stops an owned application, parametrized for native and Flatpak packaging. Assertions check the actual tray icon bytes and keep the same process, Flatpak instance, and D-Bus tray item during live changes. Tests use pytest without AI, API keys, or paid services.

The runner executes the whole suite even if a scenario fails. `report.json` records setup, test, and cleanup outcomes, and `junit.xml` provides standard test results. Application output is written to a separate log per scenario. An unavailable desktop or package is a failure, never a skipped test.

For a focused local run, append `--packaging native --filter startup` to the runner command. New `test_*.py` files are collected automatically; the workflow needs no list of scenarios.
