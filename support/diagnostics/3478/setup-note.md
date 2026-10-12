# Issue 3478 environment contract

This harness prepares one Ubuntu 24.04 Actions job with an official Debian 13 generic cloud image under KVM. It builds unchanged LocalSend 1.18.2 source commit `af0416be50770a97760f7070684bc667b759a15c` with the source-pinned Flutter 3.41.9 and Rust toolchain. The source pasteboard override must resolve to `58748dae405df5e68a131e4905d48e75d0624be2`.

## Budget

The job stops after 90 minutes. Setup has 20 minutes including checkout; Flutter bootstrap and the normal build share 30 minutes; VM readiness has 15 minutes; the product episode has at most 15 minutes. Guest provisioning runs while the host builds. All work also stops at job start plus 79 minutes 40 seconds, leaving transition time and an explicit ten-minute reserve. Collection has five minutes and artifact upload has five minutes. Failed setup or a version mismatch prevents the product episode.

## Scenario interface

The host scenario sources `environment.sh`. It receives `ssh_guest`, `scp_guest`, `work_remaining`, `DISPLAY=:99`, `JOB_STARTED_UPTIME`, `EVIDENCE`, and `EVIDENCE_DIR`. Both evidence variables point to `$GITHUB_WORKSPACE/evidence/vm`. SSH connects to `probe@127.0.0.1:2222` with the ephemeral key in `/tmp/localsend-vm/id_ed25519`. The QEMU monitor is `/tmp/localsend-vm/monitor`; the full host-pixel capture command is `/tmp/localsend-vm/capture OUTPUT.png`.

The guest has `/home/probe/session-env`, `/home/probe/bundle/localsend_app`, `/home/probe/diagnostics`, and `/home/probe/evidence`. All scenario sources from `support/diagnostics/3478` are copied to the diagnostic directory before the scenario. Guest commands source `session-env` to use the real GNOME D-Bus and Wayland sockets. `GDK_BACKEND=wayland` requires native Wayland for the GTK application. The scenario must separately verify the actual window backend, loaded executable and libraries, NumLock state, working text control, and the three real Nautilus file-copy trials.

The read-only geometry oracle comes from the reviewed issue 3161 harness, with one additive keyboard observation described below. Its source hashes and installation are retained. Installation precedes a GDM restart and successful oracle readiness. The host SDL window ID is `/tmp/localsend-vm/sdl-window-id`; its observed geometry is `host-sdl-geometry.txt`. The scenario must compare actual guest monitor geometry and SDL drawable geometry before translating physical input coordinates. An accessibility element alone does not establish visual readiness or focus.

### Read-only keyboard observation

The original `extension.js` SHA-256 is `9fdf13eb559e20e2c4ffd722924d2ee50b329ec1876262e5bce02e08963abb50`. All other copied oracle files remain unchanged. The sole source addition is:

```diff
             shellThemeScaleFactor: observe(() => St.ThemeContext.get_for_stage(global.stage).scale_factor),
+            keyboardNumLock: observe(() => global.stage.context.get_backend()
+                .get_default_seat().get_keymap().get_num_lock_state()),
```

The bug owner qualified the backend/seat/keymap chain against GNOME Shell 48.7 `shellEntry.js` lines 180–182 and `pointerA11yTimeout.js` line 113, and the NumLock getter against Mutter 48.7 `clutter-keymap.h` line 49. The observation reads the compositor's existing keymap. It does not change focus, input routing, clipboard ownership, or keyboard state. An observation error blocks an OFF assertion. The independent reviewer must inspect the modified oracle as part of the complete setup chain.

## Provenance and boundaries

The harness retains the official image URL and original image hash, exact source archive, toolchain identities, both Rust toolchain files, original locks, resolved package configuration, dependency commit, unchanged-source diff check, normal release bundle, file hashes, guest bundle verification, package versions, compositor snapshot, continuous full-pixel video, timestamps, screenshots, journals, and decode result. The GTK probe compiles normally inside the guest using its GTK 3 development package; its source hash, build log, and binary hash are retained. The scenario owns runtime process and loaded-library identity evidence.

The scenario stops and joins its guest processes before writing `/home/probe/evidence/scenario-cleanup-complete`. Collection requires that marker when a scenario has started. Archive transport and archive structure, final capture, video finalization and decoding, QEMU shutdown, and owned Xvfb shutdown have explicit results. A failed operation produces `COLLECTION=incomplete` and cannot produce the completion marker. Artifact upload still runs after a failed collector.

The normal build uses `fvm flutter pub get --enforce-lockfile` and `fvm flutter build linux`, including the repository's Cargo/Cargokit path. No generated native source or bundled library is replaced, and no app instrumentation is injected. The host distribution differs from the historical release workflow's Ubuntu 22.04 builder; Debian compatibility is checked through dependency resolution and actual startup.

The Debian image URL is mutable. The hash records the actual image used; it does not authenticate a fixed historical image. Installed GNOME Shell and Mutter must both report upstream version 48.7. Any package delta, unavailable KVM, unresolved runtime library, incomplete login, or failed oracle is classified as environment evidence. Such a result cannot support an application non-reproduction claim.

No local syntax checks, builds, tests, application launches, or cloud dispatch occurred during preparation. A fresh independent review of the complete environment and scenario chain remains required before dispatch.
