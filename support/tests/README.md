# Linux autostart E2E checks

Run the **Linux E2E** workflow manually from GitHub Actions on the branch or tag to check. It builds LocalSend once, packages that build as an AppImage, and runs six autostart scenarios: visible startup, hidden startup, and disabled autostart for both native and AppImage launches. The AppImage runs through its actual FUSE mount. Each scenario changes the Flutter settings through AT-SPI, closes the app, and checks the result in a fresh, isolated KDE login with its own display, session D-Bus, and runtime directory. The test confirms that the executable from the selected build starts when expected. KDE session restore is disabled.

For the complete suite, leave packaging set to `all` and the test filter empty. For a focused run, set the filter to `autostart`; choose `native` or `appimage` to run only those three scenarios. The equivalent terminal trigger is:

```bash
gh workflow run linux-tray-e2e.yml --ref <branch-or-tag>
```

The workflow also accepts `workflow_call` inputs named `packaging` and `test_filter`. Its generic runner supports `native`, `flatpak`, and `appimage`, and the workflow can prepare a Flatpak for future scenarios. The current suite has no Flatpak tests: selecting `flatpak` produces no tests and fails the run. New `test_*.py` files under `support/tests/linux_e2e/` are discovered automatically.

For a local run, build a Linux release bundle and install KDE Plasma, Xvfb, D-Bus, `xdotool`, `python3-pyatspi`, `at-spi2-core`, FUSE, and the GTK introspection packages. Package the same bundle as an AppImage using the pinned appimagetool and runtime versions in the workflow:

```bash
python3 support/tests/prepare_appimage_e2e.py app/build/linux/x64/release/bundle \
  --output 'linux-e2e-appimage with spaces' \
  --appimagetool /path/to/appimagetool.AppImage --runtime-file /path/to/runtime-x86_64
python3 -m venv --system-site-packages /tmp/localsend-e2e-venv
/tmp/localsend-e2e-venv/bin/python -m pip install -r support/tests/requirements.txt
```

Start a KDE Plasma X11 session with a session D-Bus and run the tests there:

```bash
/tmp/localsend-e2e-venv/bin/python support/tests/run_linux_e2e.py \
  app/build/linux/x64/release/bundle --output linux-e2e-results \
  --filter autostart \
  --appimage 'linux-e2e-appimage with spaces/LocalSend-e2e-x86_64.AppImage'
```

Add `--packaging appimage` to run only the AppImage scenarios, or `--packaging native` for native controls. The runner writes `report.json`, `junit.xml`, and per-scenario application logs to the output directory; the workflow uploads those results along with build and session logs. A failed scenario or an unavailable required environment fails the run. The tests use pytest without AI, API keys, or paid services.
