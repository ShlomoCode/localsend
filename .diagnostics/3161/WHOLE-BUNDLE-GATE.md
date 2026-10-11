# Issue 3161 source bundle gate

Root accepted the complete control/B app descriptors from app run38164164206. `whole-bundle-descriptor.accepted.json` records artifact11711782451/control and11711368558/B, the full archive/manifest/engine/AOT hashes and exact revisions. Root independently hashed both archives and all50 files each, and inspected bootstrap/build/source-lock/CMake evidence. Engine-only artifacts from run38153341418 are not substituted for these full bundles.

`prepare-whole-bundle.sh` runs only in fork Actions. It checks the immutable artifact ID, run, manifest, source/framework/engine revisions, full archive hash, every bundle file, and the exact archive structure. It transports the entire app bundle. An unexpected symlink or archive entry fails the gate and requires inspection of the source build output; do not silently repair it or replace an engine library.

In the Debian guest, launch the extracted executable directly with its ordinary loader paths and a fresh external profile. Keep the launch command, environment, executable hash, output, PID and `/proc/PID/stat` starttime. `verify-live-whole-bundle.sh` must pass on the process used for the actual actions, before and after the scenario. It checks mapped engine and AOT snapshot paths/hashes, rejects loader injection, and retains the mapped GTK/ATK/AT-SPI library identities. Those identities require separate environment acceptance; the app-build manifest does not establish a Flatpak runtime match.

## Installation and source boundaries

The accepted historical reproduction used unmodified LocalSend 1.17 Flatpak commit `df68d5e6649a894643f4bff68711e52ad86c2f26c93470139f2ff1e2b38e4418`, freedesktop runtime 25.08.17, Debian 13 and GNOME 48.7 Wayland. Retain this baseline and its original recording.

The recovered A discriminator used AT-SPI source `2b2085e3bb98c35cfeaf33a9b2852c610c3a9b7b` (2.54) built with freedesktop SDK 25.08 commit `0cc82216a407cc993941b5ddabd446becc3c9a6219d9bcf50125c60101dcad46`. Stock and A source/build/stage directories, source archive, build logs and the exact production diff survive in artifact 11706679936. They are the source authority for that comparison. Mint 2.52 builds are a different control.

Replacing the bridge through `LD_LIBRARY_PATH` isolated behavior but did not validate a supported package or a complete fix: A remained at 4.4–5.2 seconds for Zoom/Send/Receive, while its local socket had no parent and returned all −1 geometry. The warning disappeared only in the sampled interval. Preserve these limits.

A c1ce native bundle against control/B engines tests the engine intervention on the reported GNOME desktop. It does not recreate the historical Flatpak app/runtime. A Flatpak candidate needs a supported source-package/flatpak-builder build against the pinned SDK/runtime, with matching source-built AT-SPI 2.54 where that intervention is tested. Record the normal manifest/build inputs, app/runtime commits, ELF identities and actual mapped paths. No shipping claim follows from the native bundle or from a library overlay.

## Geometry and actions

Keep the GNOME session Wayland and record the app's actual GDK backend separately.

- For an Xwayland app, independently verify the X window's `_NET_WM_PID` against the scenario PID, retain `xwininfo` client origin/size and window identity, and measure logical scaling before comparing AT-SPI coordinates. Xlib geometry is valid only for that verified X window.
- For a native Wayland app, establish an independent compositor-supported client rectangle and coordinate-space convention first. Xlib, guessed screenshot locations, AT-SPI's own rectangle, and a passing Mint fixture cannot serve as that oracle. Until this is available, native global geometry remains unverified; use a clearly labeled Xwayland control if it answers a useful question.

Use an unmodified GTK working control before app assertions. Capture real continuous video with PTS and UTC input logs. Take a no-Zoom baseline, enable Zoom through GNOME Accessibility Settings, click Send and Receive, disable Zoom in the same PID, and repeat the reversal. Record deadlines and every measured delay. Inspect actual frames after each action, and sample warnings without converting their absence into a global claim.

Additional checks required for a complete candidate: semantic names and roles, geometry after move/resize, editing an actual text field, a real accessible action with its visible effect, Orca speech output with audible/retained speech evidence, close/reopen and shutdown lifecycle, and retained PID/window/source identities throughout. Classify unavailable provider, wrong foreground, unsupported geometry and startup errors as harness failures. Do not mark these cases passed merely because the process survives or a workflow is green.
