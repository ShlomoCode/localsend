# Issue 508: Linux AppImage autostart reproduction

This diagnostic runs the published x86-64 AppImages on Ubuntu 22.04, in Xvfb,
Openbox, and a D-Bus session. It uses FUSE-mounted AppImages: an extracted
fallback would not test the reported temporary executable path.

For each release, the script opens the real Settings tab and uses `xdotool` to
click the autostart switch. It records the resulting desktop file, verifies its
`Exec` path while the app is alive, terminates the app and waits for the FUSE
mount to disappear, then tries that exact command. Relaunching the stable
AppImage path is the working control. An extracted `AppRun` control is also
tested when the release has a visible autostart switch.

The v1.10.0 case is historical context: Linux autostart was not available in
that release, so `unsupported_missing_option` is expected. v1.14.0 tests the
June 2024 report; v1.18.2 checks a later published release. A change in
behavior between versions does not identify the fixing commit.

Run the `Diagnose issue 508 autostart` workflow with **Run workflow** on the
diagnostic branch. Each matrix job uploads `result.json`, GUI screenshots,
application logs, release metadata, and mount/process logs even when a case
fails. A `harness_error` outcome means the UI action or FUSE mount was not
verified; it is not evidence that autostart works.
