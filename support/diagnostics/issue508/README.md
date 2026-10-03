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

## Observed results

[Run 37156625221](https://github.com/ShlomoCode/localsend/actions/runs/37156625221)
reproduced the AppImage failure on the published x86-64 releases 1.14.0 and
1.18.2. The real GUI toggle created a desktop entry whose `Exec` pointed to
`/tmp/.mount_LocalS.../localsend_app`. The executable existed while the app
ran. After termination, the FUSE mount disappeared and running the saved
command failed with `ENOENT`. Relaunching the original AppImage file opened
a new LocalSend window on both releases.

[Controlled comparison run 37156911230](https://github.com/ShlomoCode/localsend/actions/runs/37156911230)
repeated the failure on both releases, then changed only the generated
desktop entry's executable to the original AppImage file. With the same
arguments and HOME/XDG profile, both versions opened a new LocalSend process
in a new FUSE mount. The per-case outcome is
`same_profile_stable_exec_works`. The running apps also exposed `APPIMAGE`
with the stable file path and `APPDIR` with the temporary mount path.

This comparison identifies the saved temporary executable path as the cause
of the reproduced failure. The product correction selects the AppImage
runtime's stable `APPIMAGE` path for that packaging format and preserves the
regular executable path for other formats; the current-source validation is
recorded below.

The 1.10.0 GUI had no Linux autostart option. This matches the source at that
tag: it offered the setting only on Windows. Linux support was added in
[commit cb5090bc](https://github.com/localsend/localsend/commit/cb5090bca8b02290ae92801a480d44f6ab6e712d)
and first included in 1.11.0. The original June 2023 report and the June 2024
AppImage comment describe different stages of support. Neither reporter
specified an exact version; 1.10.0 and 1.14.0 are the releases available at
the respective report dates.

The extracted-AppImage experiment is a packaging diagnostic, not a passing
control for the tar or deb packages. Its `AppRun` opened the GUI, but the
generated raw executable failed with `ENOENT` even though its file still
existed. `readelf -l` recorded the relative interpreter
`lib64/ld-linux-x86-64.so.2`; the diagnostic launched the raw binary outside
the extracted directory. That packaging dependency makes this control
unsuitable for conclusions about ordinary directory installations. The
stable AppImage intervention above is the passing control.

## Current-source validation

[Build run 37159634890](https://github.com/ShlomoCode/localsend/actions/runs/37159634890)
built baseline `e768240d1ad95f0f162b852b5ff37bec71cde1ef` and fix
`c28b054f7c3867a810b4c082a2abd00d579666c9` with the same pinned Flutter
3.41.9 toolchain and the repository's AppImageBuilder recipe. Both outputs
were real FUSE-mounting AppImages. The baseline SHA-256 was
`2eb91095adc59f8e5f52ec4f7548ddd4da05170f5678dbdf128d0c10e376c5a1`;
the candidate SHA-256 was
`09ca3a540433a8133ebad82f094c8342e660c35a25c65d75a45be93bff0165ec`.
The run uploaded both binaries and the ordinary candidate build bundle before
its first GUI check. Several GUI checks failed prematurely from inspecting
`Gio.DesktopAppInfo.get_executable()` and trying to parse a seeded entry whose
old executable no longer existed. Those checks were corrected
without rebuilding either artifact.

[Runtime recheck 37160408002](https://github.com/ShlomoCode/localsend/actions/runs/37160408002)
verified those exact binary hashes and source commits, then exercised the
real Settings autostart switch and launched the generated desktop entries
through `Gio.DesktopAppInfo`. The baseline reproduced the stale FUSE-mount
`Exec`. The fix launched a fresh AppImage GUI from the saved entry after the
original mount disappeared. The `--hidden` entry started an unmapped process
and opened the LocalSend TCP port. Existing stale entries migrated at startup
while preserving their metadata and hidden preference; normal, hidden,
custom temporary mount root, and AppImage `extract-run` patterns passed.
The ordinary build bundle also relaunched through its saved entry. A candidate
AppImage path containing a quote, backtick, dollar sign, and backslash passed
the same GIO launch and runtime `APPIMAGE` identity checks. The runtime job
finished successfully with no required case failures.

The percent-only filename was recorded separately as a GIO limitation on
GLib 2.71.3. The generated desktop entry encoded `%` as `%%`, but GIO rejected
it before launch. A minimal desktop entry with `/usr/bin/true` copied to a
percent-containing path also failed to load with `%%`. A literal-percent
entry parsed and `launch()` returned true; the probe did not establish that
its executable ran. The percent case is an optional packaging diagnostic,
not part of the passing fix claim.

These experiments used X11/Openbox on Ubuntu 22.04 and GIO's desktop-file
launcher. They do not constitute a full KDE login test on Arch. The uploaded
artifacts include generated desktop entries, GUI screenshots, application
logs, source identities, and executable hashes.
