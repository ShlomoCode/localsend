# Experiment ledger

| Condition | Prediction | Actual result | Evidence |
|---|---|---|---|
| Debian 13 / GNOME 48.7, 1920×1080 physical / 960×540 logical, 200%, Flatpak 1.17, native Wayland | A general odd logical allocation defect would attach 452×599 at scale 2. | Three starts rendered LocalSend. Root surface 34 attached 904×1198 at scale 2. Zero protocol errors. The reported failure did not occur on Mesa/virgl. | round-9/result.txt and desktop.png. |
| Same 200% setup, normal GTK Calculator | A broken compositor scaling setup would also prevent the GTK control from rendering. | Calculator rendered with a 964×1476 buffer and preferred scale 2. | round-10/result.txt and calculator.png. |
| Same 200%, GDK_BACKEND=x11 under Flatpak fallback-x11 | A true XWayland launch should expose a LocalSend X11 window. | Three launches exited 1 before rendering. Invalid control; exact logs needed. | round-10/result.txt. |
| Same X11 control with supported Flatpak --socket=x11 permission | Exposing the X11 socket would resolve a socket permission failure. | Three launches still exited 1 before rendering. No X11 window. The permission-only explanation is unverified. | round-11/result.txt. |

The first two rows are actual application/control observations. X11 launch failures, VM provisioning, initial-login preparation, command-path repair, and screenshot repairs are infrastructure work. None reproduces the reported protocol error. Three repetitions of one setup count as one condition.

| Additional condition | Prediction | Actual result | Evidence |
|---|---|---|---|
| Native 200%, actual XWayland with `--socket=x11 --nosocket=wayland --env=GDK_BACKEND=x11` | A Wayland-only buffer problem should not occur on XWayland. | Three starts rendered; Xwininfo identified the LocalSend window at 904×1120. Zero protocol errors. Earlier controls exported an empty DISPLAY while Wayland remained available, so they were invalid. | round-12/probe-0.txt; round-13/result.txt and xwayland.png. |
| Native 200%, GTK_CSD=0 | If the GtkHeaderBar causes invalid odd extents, removing it should change the failing behavior. | Three starts rendered with valid 904×1178 physical root buffers at scale 2. No protocol errors; decoration removal changed geometry but did not expose the failure. | round-14/result.txt and csd0.png. |
| Native 200%, LIBGL_ALWAYS_SOFTWARE=1 | A driver-dependent EGL path may differ from the default GL path. | Three starts rendered; trace uses SHM physical buffers 904×1198 at scale 2. No protocol errors. The flag and SHM path are proven; exact GL renderer identity is not. | round-14/result.txt and llvmpipe.png; round-15/probe-2.txt. |

Each row counts as one substantive LocalSend condition, regardless of repeat count. Calculator remains a control. The NVIDIA hardware gap remains untested; none of these results attributes a cause to NVIDIA.

| Live transition condition | Prediction | Actual result | Evidence |
|---|---|---|---|
| Same app PID, 100%→150%→200% via documented Mutter temporary monitor config, three fresh processes | A scale-transition mismatch could attach an old odd buffer after changing surface scale. | All three sequences rendered with zero protocol errors. PIDs 7612, 7843, 8077 remained unchanged within their sequence. Root surface34 remained. Output/logical geometry: scale1 /1920×1080 at100%; scale2 /1280×720 at150%; scale2 /960×540 at200%. Physical buffers: startup452×599 then saved952×699 at100%; 1904×1398 at150%; 1904×1120 at200%. | round-21 through round-23/result.txt and native stage screenshots. Complete traces remain guest live-scale/. |

The live transition is one substantive condition. Its restored window geometry differs from the initial default-window200% baseline. The next fresh-profile startup condition separates saved window state from fractional startup. Temporary monitor configuration uses GNOME Mutter48.7 ApplyMonitorsConfig method1, with documented mode scales and logical layout1.

| Fractional startup condition | Prediction | Actual result | Evidence |
|---|---|---|---|
| Native150% startup, unchanged Flatpak1.17, existing profile | If fractional scale startup alone causes the mismatch, startup should fail independently of live transitions. | Three starts rendered at output scale2 and1280×720 logical geometry. Initial904×1198 and later1904×1398 physical buffers; zero errors. | round-24/result.txt. |
| Native150% startup, fresh XDG config/data profile per start, exported inside sandbox | If saved application state drives invalid geometry, a fresh profile should change the outcome. | Three starts rendered without protocol errors. Process environment confirms unique XDG paths. Initial904×1198 and later1904×1398 physical buffers. | round-25/result.txt and fresh-start-1.5.png. |

The attempted profile override in round24 was ineffective: Flatpak reset XDG paths. It establishes existing-profile150% startup only. Round25 verifies the intended fresh profile via /proc/PID/environ. Both conditions passed; no cause is proven.

| Native runtime and transition stress | Prediction | Actual result | Evidence |
|---|---|---|---|
| Official DEB1.17.0+58, native Debian13 GTK3.24.49-3/Mesa25.0.7,200% | If the Flatpak runtime masks the reported failure, native Debian GTK/EGL should expose it. | Three starts rendered, valid904×1198 buffers atscale2 on surface34, no protocol errors. App and Flutter engine SHA-256 exactly match Flatpak. Legitimate apt-installed package and dependencies; ldd has no missing libraries. | round-27/result.txt and native-deb200.png. |
| Ten rapid100%↔200% cycles in one unchanged Flatpak process | If scale-update timing creates a mismatched buffer on the tested path, repeated live changes may expose it. | PID9399/start time stayed unchanged. All20 transitions completed.21 output-scale events, zero protocol errors; final screenshot renders app. | round-28/result.txt and rapid-scale.png; full guest trace rapid-scale/trial-1.log. |

DEB SHA-256:b0244b2c3eacb2a81d61b2662534d6036ab37ace10d6782da36b630c222fa04c. App:e4d336ec735105cbf8bdd9ee11eb57afc1aa8d9341b56a53f83f7ededbd1f0f8. Flutter engine:854bf421539fa8572d7d61469eeb78c017c10754a8748cf00788deb6db8887b8. The rapid transition test is one condition, not20 experiments.

| Physical output / fractional rendering | Prediction | Actual result | Evidence |
|---|---|---|---|
| Native DEB1.17,3840×2160 physical/1920×1080 logical,200% | Different physical output geometry may alter the startup buffer path. | Three starts rendered; output/buffer scale2, initial904×1198 and restored1904×1398 physical buffers. No protocol errors. | round-29/result.txt and native-deb4k200.png. |
| Native DEB1.17,3840×2160 physical/2560×1440 logical,150% | Native fractional startup on4K may expose mismatch absent from1920×1080. | Three starts rendered; output/buffer scale2, initial904×1198 and restored1904×1398 physical buffers. No protocol errors. | round-30/result.txt and native-deb4k150.png. |

The4K150% condition covers the single4K monitor aspect of the separate Ubuntu/Snap comment. It does not cover that comments mixed two-monitor layout, GNOME50.1, NVIDIA RTX3060/595.71.05, or Snap revision32.

| Window geometry transition | Prediction | Actual result | Evidence |
|---|---|---|---|
| Three native maximize/restore cycles at 4K 150% | Recreating large buffers during window geometry changes could expose an allocation/scale mismatch. | PID 10036 and surface 34 remained stable. Maximized buffers 5120×2816; restored 1904×1398; buffer scale 2. All stages rendered. Complete trace has zero protocol errors. | round-31/result.txt and six native screenshots; round-32/result.txt; native-deb4k150/trial-3.log. |

An independent native Wayland EGL control reports virgl (LLVMPIPE (LLVM 21.1.8, 256 bits)). App maps prove Mesa EGL, not an in-process GL_RENDERER value. Flatpak's exact GL_RENDERER remains unmeasured. See original-scenario-matrix.md for the twelve distinct conditions and precise report provenance.
