# Native x64 Flatpak cohort diagnostic

This workflow tests the exact signed Flathub LocalSend 1.18.2 app
commit against two exact Freedesktop 25.08 runtime cohorts on a native x86_64
GitHub-hosted Ubuntu 24.04 runner. It runs only on the dedicated branch
`codex/3483-native-flatpak-repro`, has `contents: read`, uses no secrets, and
has a 20-minute job limit. It does not build or modify the LocalSend app.

The older cohort must first launch the pinned app, create a visible window, and
pass an actual Gear-to-Settings click verified by OCR for General, Theme, Color,
and Language. The harness verifies the app window PID and 400×538 client size
before using the Gear click point, and waits up to 30 seconds for the home and
Settings text to render. Failure in the older baseline stops the experiment
before any runtime update; it is a baseline or harness failure, not a
reproduction of issue #3483. A valid baseline also requires nonempty Mesa
shader-cache files in the app profile. If baseline passes, the job clones the
runner-generated profile including its cache, updates the five runtime refs
normally with signature verification enabled, verifies all refs together, then
tests the same profile/cache on the current cohort. A fresh-cache control runs
only if that first current-cohort launch fails; it starts from the pre-update
profile copy and removes only that copy's cache directory. The current-cohort
GLX metadata probe runs after the measured launch(es) so it cannot warm the
cache before the first current-cohort launch.

Artifacts are retained for seven days and contain screenshots from a synthetic
ephemeral runner profile, ref/commit and renderer metadata, and coarse
pass/failure categories. Command output and app stderr are retained only in the
runner's temporary directory and are not uploaded. No host or reporter hardware
identifier is queried. The test uses Xvfb/Openbox, not GNOME or Zorin, and its
virtual GPU does not establish physical Intel/NVIDIA GPU fidelity. The GLX
probe reports the runtime's GLX renderer; it does not identify Flutter's
renderer choice.

The harness adds a test-specific system remote from Flathub's official HTTPS
`.flatpakrepo` configuration, including its public signing key, so an image's preconfigured Flathub alias cannot affect
remote selection. It installs each ref normally, then pins the requested
historical commit with `flatpak update --commit`; Flatpak 1.14.6 does not support
`--commit` on `flatpak install`.

## Components

- `.github/workflows/diagnose_3483_native_flatpak.yml` configures the bounded runner.
- `run.py` performs pinned installation, UI and settings checks, the same-cache
  transition, and conditional fresh-cache control.
- `glx-probe.c` records GLX vendor, renderer, and version inside the Flatpak
  runtime. It is runtime-level metadata, not Flutter's renderer selection.

The workflow runs only after its files are present on the dedicated branch and
that branch is pushed. A successful Xvfb/Openbox result is not proof that the
reporter's physical GPU or desktop compositor has been reproduced.
