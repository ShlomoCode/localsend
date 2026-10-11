# GNOME cannot associate the integrated AppImage with its window

The official 1.17.0 AppImage reproduces the reported generic dash icon in all three launches after normal Gear Lever integration. A matching `StartupWMClass` in the generated desktop entry changes GNOME's actual window association and renders the original LocalSend icon in all three repeated launches. Removing that line restores the failure. The official 1.18.2 AppImage shows the same failure, but requires its newer window identity.

## Measured outcomes

| Application | Desktop metadata | Observed window class | GNOME association and visible icon | Repeats |
| --- | --- | --- | --- | --- |
| Official 1.17.0 | Original Gear Lever entry | `localsend_app` | Window-backed fallback; blue executable icon | 3/3 |
| Official 1.17.0 | Add `StartupWMClass=localsend_app` | `localsend_app` | `localsend.desktop`; LocalSend icon | 3/3 |
| Official 1.17.0 | Remove the added line | `localsend_app` | Window-backed fallback; blue executable icon | 1/1 |
| Official 1.18.2 | Original Gear Lever entry | `org.localsend.localsend_app` | Window-backed fallback; blue executable icon | 3/3 |
| Official 1.18.2 | Add the historical 1.17 class | `org.localsend.localsend_app` | Window-backed fallback; blue executable icon | 1/1, supplementary negative control |
| Official 1.18.2 | Use the measured matching class | `org.localsend.localsend_app` | `localsend.desktop`; LocalSend icon | 3/3 |

The executable, icon path, and icon content are unchanged by each metadata intervention. Calculator launches and displays its normal GNOME dash icon as the environment control. LocalSend displays its Receive UI in repeated baseline and corrected cases; the first 1.18.2 launch shows the release notes screen before later launches show Receive. GNOME's mapped dash actors and screenshots agree with the window-tracker measurements.

## Repeat the experiment

Dispatch `linux-e2e.yml` on `codex/diag-2433-gnome` in `ShlomoCode/localsend`, using diagnostic commit `0279ddf2130e31c0e25af6a928593a1c06ca4f69` for the release comparison. The workflow boots an official Fedora 42 cloud VM, installs GNOME and standard AppImage prerequisites, integrates each official release through Gear Lever's supported CLI, and launches its generated desktop entry through GNOME Shell. Each case saves the complete Shell state and screenshot, then asserts the specific class, application association, and icon.

[Controlled release experiment](https://github.com/ShlomoCode/localsend/actions/runs/38127410426) contains all 14 case outcomes, exact release checksums, generated desktop entries, preserved icon bytes, session identity, and scale. Local copies are in `run-38127410426/fedora-gnome-2433-evidence/`. `causal-summary.json` extracts the relevant window and mapped icon fields without replacing the raw trees.

## Scope and limits

The report specifies Fedora Silverblue 42, LocalSend 1.17.0, an integrated desktop entry, and a generic blue dash icon. It has zero comments and no images. The integration tool, architecture, and display protocol are unspecified. This experiment uses Fedora 42 Cloud Edition with GNOME 48.8 Wayland, x86_64, and Gear Lever. Its root filesystem is mutable, unlike Silverblue. The GNOME session, official application, and legitimate desktop integration reproduce the exact visible symptom; this does not claim a Silverblue test.

The proposed production change is scoped to both AppImage recipes. It uses the supported `after_runtime` hook to add the compiled application's window class to the generated AppImage desktop entry. DEB uses its own packaging configuration; Snap and Flatpak packaging have their own desktop entries outside these recipes. No shared desktop source or native application identity changes.

The exact production-base c1ce322fb3acf08e44f329b8b7208b8b0d91e244 was built once with pinned Flutter 3.41.9 and packaged twice with the pinned appimage-builder 1.1.0 action. [Run 38132440179](https://github.com/ShlomoCode/localsend/actions/runs/38132440179) passed all six source-package launch assertions: baseline generic 3/3, candidate LocalSend 3/3. The actual source window class is org.localsend.localsend_app. Source-baseline-2 and source-candidate-2 screenshots both show the same Receive screen and calculator control, with the dash icon changing from generic to LocalSend. source-summary.json preserves the six measured associations. Bundled autoreview on production commit 2e950198 completed clean with no accepted findings through P2; invocation metadata and complete helper stdout are retained in autoreview-invocation.txt.

## Alternatives considered

1. Rename the native program to match Gear Lever's launcher. Integrators can legitimately choose different filenames, and a native identity change would affect every Linux package. Declaring the existing window identity in AppImage metadata keeps that relationship explicit.
2. Supply a complete static desktop entry. This duplicates the name, executable, icon, and category metadata that appimage-builder already generates. Its supported post-generation hook adds the missing field without duplicating those values.
3. Set a window icon directly. This can mask missing desktop association without linking the running window to its installed launcher. The class metadata corrects the measured association and its existing icon together.

No permanent test is added: the observable regression depends on a real integrated AppImage and GNOME Shell. A test that reads the new literal would duplicate the implementation. The diagnostic cloud checks execute that desktop behavior instead.

## Extracted package validation

[Run38134249334](https://github.com/ShlomoCode/localsend/actions/runs/38134249334) confirms byte-identical packaged executables and all17 application libraries, and desktop content differing only by StartupWMClass plus an empty line. Complete packages differ in incidental systemd/APT capture; PACKAGE_BOUNDARIES.md and raw manifests classify every baseline-only file. No GTK/GNOME library is missing and no common shared-library content differs. This is not a claim of identical complete packages.
