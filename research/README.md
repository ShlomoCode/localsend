# Research-only component experiments

This branch contains isolated diagnostics, not LocalSend fixes or a pull request.
Upstream source baseline: 9529e915f438d8edd8bdf23e9f7aab2261a8b3e6.
Flutter: 3.41.9. Native tray dependency: tray_manager 0.5.3.

The APK header fixture compares the pinned layout with Wrap/Flexible using
320/360/480/800 logical pixels, text scale 1/2/3 and both text directions.
Each width includes the original 30dp horizontal page inset. The test font is
Ahem; exact device-font failure thresholds are not asserted. The 800dp/scale1
control must work before the change; 320dp/scales2/3 must reproduce overflow.
Every patched case must keep the Switch inside the viewport and actually toggle.
APK enumeration, the list, app-name truncation and the native device are outside
this component fixture.

The error experiment invokes the actual generated FRB error variants and the
actual HumanErrorMessageExt from the pinned workspace. Its four-arm patch exists
only in the remote runner checkout. Both the debug-wrapper baseline and the
clean payload are asserted; HTTP status and ordinary fallback controls remain.
The experiment does not claim localization or a transport fix.

The native Linux tray experiment reads real D-Bus exported IDs and sends actual
menu events across four fresh processes. The minimal watcher is not KDE/GNOME;
saved popup preferences are outside this test. The proposed shortcut uses private
dependency APIs, whose maintenance risk remains even if this experiment passes.

Toolchains and prerequisites are installed only in GitHub-hosted runner VMs.
The user's local machine receives no installations. Issue bodies are research
inputs and are not executed by these experiments.
