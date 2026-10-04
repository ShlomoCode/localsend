# Linux autostart E2E checks

Run the **Linux E2E** workflow manually from GitHub Actions on the branch or tag to check. It builds LocalSend once and runs six autostart cases: visible startup, hidden startup, and disabled autostart for both native and AppImage launches. The AppImage comes from that build and runs through its FUSE mount. Each case changes settings through AT-SPI, closes the app, then checks the result in a fresh KDE login with its own Xvfb display, session D-Bus, and runtime directory. KDE session restore is disabled.

For the complete suite, leave packaging set to `all` and the test filter empty. For a focused run, set the filter to `autostart`; choose `native` or `appimage` to run only those three scenarios. The equivalent terminal trigger is:

```bash
gh workflow run linux-tray-e2e.yml --ref <branch-or-tag>
```

The reusable workflow also accepts `workflow_call` inputs named `packaging` (`all`, `native`, or `appimage`) and `test_filter` (a pytest `-k` expression). New `test_*.py` files under `support/tests/linux_e2e/` are discovered automatically.

For a local run, build a Linux release bundle and install KDE Plasma, Xvfb, D-Bus, `xdotool`, `python3-pyatspi`, `at-spi2-core`, and FUSE. To run the AppImage cases, package the same bundle using the pinned appimagetool and runtime versions in the workflow:

```bash
python3 support/tests/prepare_appimage_e2e.py app/build/linux/x64/release/bundle \
  --output 'linux-e2e-appimage with spaces' \
  --appimagetool /path/to/appimagetool.AppImage --runtime-file /path/to/runtime-x86_64
python3 -m venv --system-site-packages /tmp/localsend-e2e-venv
/tmp/localsend-e2e-venv/bin/python -m pip install -r support/tests/requirements.txt
```

Run the tests from an ordinary Linux shell. The harness starts a private KDE X11 login for each stage:

```bash
/tmp/localsend-e2e-venv/bin/python support/tests/run_linux_e2e.py \
  app/build/linux/x64/release/bundle --output linux-e2e-results \
  --filter autostart \
  --appimage 'linux-e2e-appimage with spaces/LocalSend-e2e-x86_64.AppImage'
```

Add `--packaging appimage` to run only the AppImage cases, or `--packaging native` to run only native cases (which need no AppImage). The runner writes `report.json`, `junit.xml`, and per-case application and login logs to the output directory. The workflow uploads those results, the source revision, the test summary, and AppImage preparation output when applicable. A failed case or unavailable required environment fails the run.
