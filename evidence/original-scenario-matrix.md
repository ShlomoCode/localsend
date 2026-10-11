# Issue 3033: original-scenario matrix

The reported failure has not occurred in the tested environments. No production patch or PR is justified. These twelve conditions exclude repeated starts and infrastructure repairs.

## Report provenance

[LocalSend 3033](https://github.com/localsend/localsend/issues/3033) reports Debian 13, GNOME 48.7, native Wayland, 200%, and LocalSend 1.17.0 attributed to Flutter 3.24.5. It reports failure across Snap and Flatpak. It specifies no display resolution, GPU, driver, or package revision. The excerpt rejects physical 452×599 at buffer scale 2 on surface 36.

[Flutter 185326](https://github.com/flutter/flutter/issues/185326), directly linked by the reporter, states NVIDIA RTX 5090 / 580.82.09. Both issues are authored by vegerot and quote the same error. GPU details come from the linked report, not a hardware field in LocalSend 3033. They do not establish an NVIDIA cause. Flutter closed the issue for insufficient information; no correcting commit or minimum fixed version was identified.

The sole LocalSend comment is a different Ubuntu 26.04 / GNOME 50.1 / Snap revision 32 scenario: NVIDIA RTX 3060 / 595.71.05, mixed 4K 150% and 1080p 100% outputs. A matching error string does not prove a shared cause.

Full source: `/tmp/localsend-sprint-triage/thread-3033-metadata.json`, `thread-3033-comment-pages.json`, `/tmp/localsend-3033-flutter-issue.json`, `/tmp/localsend-3033-flutter-comments.json`. Threads read 2026-10-11.

## Artifact and renderer identity

All rows run unchanged official LocalSend 1.17.0. Flatpak commit: `df68d5e6649a894643f4bff68711e52ad86c2f26c93470139f2ff1e2b38e4418`; runtime 25.08.17. Its manifest copies the official TAR. The native DEB 1.17.0+58 was installed with apt dependencies.

Flatpak and DEB app SHA-256 match: `e4d336ec735105cbf8bdd9ee11eb57afc1aa8d9341b56a53f83f7ededbd1f0f8`. Their Flutter engine SHA-256 match: `854bf421539fa8572d7d61469eeb78c017c10754a8748cf00788deb6db8887b8`. Flutter 3.24.5 is the report attribution for this release. A newer Flutter build is not tested here.

The guest uses Debian 13 / GNOME 48.7, QEMU virtio-vga-gl, native GTK 3.24.49-3 and Mesa 25.0.7-2+deb13u1. App maps prove Mesa EGL; protocol traces name its surface queue. An independent native Wayland EGL control reports `virgl (LLVMPIPE (LLVM 21.1.8, 256 bits))`. This identifies the native EGL environment, not an in-process LocalSend GL_RENDERER measurement. Flatpak's exact GL_RENDERER was not captured.

Renderer legend: **M** = default Mesa EGL DMA-BUF path; **S** = software flag with proven SHM buffers; **X** = actual XWayland window, exact GL renderer unmeasured. Profiles **F** = normal Flatpak profile, **N** = normal probe-user native profile. P/L means physical/logical output geometry; window buffers are physical pixels.

## Matrix

Every condition rendered the application and produced zero reported Wayland protocol errors.

| Condition | Backend / renderer / profile | P/L output; output scale | Window buffers or state | Evidence |
|---|---|---|---|---|
| 1. Native 200%, 3 starts | Wayland / M / F | 1920×1080 / 960×540; 2 | 904×1198 at buffer scale 2; transient 904×1120 | [round 9](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11701212320), native200/trial-1..3.log |
| 2. Actual XWayland 200%, 3 starts | X11 / X / F | 1920×1080 / 960×540 desktop | Xwininfo: LocalSend 904×1120; no app Wayland surface | [round 13](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11701823937) |
| 3. GTK_CSD=0, 200%, 3 starts | Wayland / M / F | 1920×1080 / 960×540; 2 | 904×1178 at scale 2; decoration removed | [round 14](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11701604919), variants200/csd0-1..3.log |
| 4. LIBGL_ALWAYS_SOFTWARE=1, 200%, 3 starts | Wayland / S / F | 1920×1080 / 960×540; 2 | SHM 904×1198, stride 3616, scale 2 | [round 15](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11701949578), variants200/llvmpipe-1..3.log; filename labels flag, not measured renderer |
| 5. Live 100→150→200%, 3 processes | Wayland / M / F unchanged within each process | P 1920×1080; L 1920×1080→1280×720→960×540; scale 1→2→2 | Initial 452×599, restored 952×699 at 100%; 1904×1398 at 150%; 1904×1120 at 200%. Surface 34 and PID stable within each sequence | [round 23](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11702319927), live-scale/trial-1..3.log |
| 6. 150% startup, 3 starts | Wayland / M / F | 1920×1080 / 1280×720; 2 | Initial 904×1198; restored 1904×1398 at scale 2 | [round 24](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11703097388), fresh-start-1.5/trial-1..3.log |
| 7. 150% startup, 3 fresh profiles | Wayland / M / unique XDG config/data, process-environment verified | 1920×1080 / 1280×720; 2 | Initial 904×1198; 1904×1398 after startup, scale 2 | [round 25](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11703139217), fresh-start-verified-1.5/trial-1..3.log |
| 8. Native DEB 200%, 3 starts | Wayland / M, native libraries / N | 1920×1080 / 960×540; 2 | 904×1198, transient 904×1120, scale 2 | [round 27](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11704055198), native-deb200/trial-1..3.log and maps |
| 9. Ten rapid 100↔200% cycles | Wayland / M / F | P 1920×1080; L 1920×1080↔960×540; scale 1↔2 | PID 9399 stable; 21 output-scale events; 952×699 / 1904×1120 buffers | [round 28](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11703393307), rapid-scale/trial-1.log |
| 10. Native DEB 4K 200%, 3 starts | Wayland / M, native libraries / N | 3840×2160 / 1920×1080; 2 | Initial 904×1198; 1904×1398 after startup, scale 2 | [round 29](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11703403654), native-deb4k200/trial-1..3.log |
| 11. Native DEB 4K 150%, 3 starts | Wayland / M, native libraries / N | 3840×2160 / 2560×1440; 2 | Initial 904×1198; 1904×1398 after startup, scale 2 | [round 30](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11703877011), native-deb4k150/trial-1..3.log |
| 12. Three maximize/restore cycles at 4K 150% | Wayland / M, native libraries / same N and PID 10036 | 3840×2160 / 2560×1440; 2 | 5120×2816 maximized ↔ 1904×1398 restored; surface 34 stable | [round 31](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11704027406), native-deb4k150/trial-3.log |

Calculator rendered at 200% with 964×1476 buffers; it is a harness control. Initial XWayland attempts failed before rendering because Flatpak exported empty DISPLAY while Wayland remained available; they are invalid controls. Round 24 ignored the attempted XDG overrides and proves existing-profile startup only. Round 25 verifies the corrected profile control.

## Raw evidence and remaining leads

Results and inspected native screenshots: `/tmp/localsend-bug-3033/evidence/round-N/`. Full guest logs, monitor states, installation records and EGL metadata: `/tmp/localsend-bug-3033/evidence/raw-full/evidence/`. [Round 33](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11704009418) preserves the closed-log archive as base64 in probe-0.txt. The decoded archive `/tmp/localsend-bug-3033/evidence/raw-traces-3033-final.tar.gz` has SHA-256 `c81754dbaab494be0a02600b88b69469e06252aef7a2fef92523b6b7aefa5da5`, matching the guest checksum. Surface IDs are process-local; surface 34 matching across separate processes is incidental.

The tested path correctly scales odd logical height 599 to physical 1198 at buffer scale 2. This does not explain the reporter's physical 452×599 at scale 2 or establish a fix.

Uncovered leads: supplemental NVIDIA EGL/driver environment from Flutter 185326; Snap packaging from the original report; a newer Flutter build for the original reproduction/check request; the separate comment's mixed-monitor layout. No evidence restricts the defect to NVIDIA or identifies a newer Flutter correction. Root review determines further experiments or an exact blocker; twelve rows do not automatically end the investigation.
