# Issue 3033 status

Investigation ended after root review of 13 substantive conditions. The reported failure was not reproduced; no production patch is justified. See FINAL.md for retained evidence and requirements to resume. No additional workload is authorized until new reproduction evidence arrives.

## Evidence

The original scenario uses Debian 13, GNOME 48.7, native Wayland, 200% scaling, and LocalSend 1.17.0. The linked Flutter report adds NVIDIA RTX 5090 with driver 580.82.09. Its error reports a physical 452×599 buffer at buffer scale 2. Flutter closed that thread for insufficient information; no correcting commit was identified.

The sole LocalSend comment uses Ubuntu 26.04, GNOME 50.1, snap revision 32, NVIDIA RTX 3060, and mixed 150%/100% monitors. It reports the same error string in a different environment. A shared cause remains unproven.

The isolated cloud VM uses Debian 13, GNOME 48.7, and legitimate Flatpak 1.17.0 commit df68d5e6649a894643f4bff68711e52ad86c2f26c93470139f2ff1e2b38e4418. Its GPU is QEMU virtio/virgl through host software OpenGL, which differs from NVIDIA. GNOME Settings applied 1920×1080 at 200%; Mutter and the application protocol confirm 960×540 logical geometry and buffer scale 2.

Three native Wayland starts rendered LocalSend and produced zero protocol errors. The top-level surface attached 904×1198 physical buffers, exactly twice the reported 452×599 logical extent. This rules out a general odd logical allocation defect in the tested installation and rendering path. It does not resolve the NVIDIA report.

Normal GTK Calculator rendered at 200%, with a 964×1476 physical buffer. A corrected actual XWayland control rendered in three starts. Earlier controls exported empty DISPLAY while Wayland remained enabled and were invalid. GTK_CSD=0 and LIBGL_ALWAYS_SOFTWARE=1 each rendered in three starts without protocol errors. Software mode used SHM buffers904×1198; exact renderer identity remains unverified.

## Identity

The Flatpak manifest copies the official 1.17.0 Linux TAR without rebuilding the app. TAR SHA-256: 6f05e851b72dbeaac764d3446b5a61c34db22f6278baa92607d5b080997f8c81.

App SHA-256: e4d336ec735105cbf8bdd9ee11eb57afc1aa8d9341b56a53f83f7ededbd1f0f8.

Engine SHA-256: 854bf421539fa8572d7d61469eeb78c017c10754a8748cf00788deb6db8887b8.

## Source review and next experiment

PR 3037 addresses Refena initialization during hidden startup, a different error. PR 2360 changes GTK decorations and remains a controlled variable. Flutter 3.24.5 sends integer GTK allocation multiplied by GTK scale. GTK 3.24.49 creates and resizes its EGL window with logical width and height multiplied by scale; it also has a separate 1×1 dummy EGL surface. Neither source observation proves the producer of the reporter's invalid buffer.

Three live100%→150%→200% sequences passed in unchanged app processes. PIDs7612/7843/8077 and root surface34 remained stable within each sequence. Protocol geometry confirms output scales1/2/2 and logical sizes1920×1080/1280×720/960×540. Buffers were452×599 initially and952×699 restored at100%,1904×1398 at150%,1904×1120 at200%. No protocol errors occurred. This is one substantive condition; evidence is in rounds21–23. Further conditions also passed: 150% startup with existing and verified fresh profiles; native DEB200% with identical app/engine SHA; ten rapid100↔200% cycles; native4K200% and4K150%; three maximize/restore cycles at4K150% in one PID. There are thirteen distinct passing conditions, including official Snap1.17.0 revision32 in three native Wayland200% startups. Complete raw logs and monitor states are in evidence/raw-full/evidence; original-scenario-matrix.md links every condition and identifies remaining leads. Snap also passed with normal connected interfaces and identical app/engine SHA. The live VM exposes one physical output only. Root review determines further work on mixed monitors or supplemental NVIDIA hardware; newer Flutter is deferred without a failing baseline.

Actions run: https://github.com/ShlomoCode/localsend/actions/runs/38135756388.

Diagnostic branch: codex/bug-3033-wayland-scale-diagnostics. Source and full threads were read on 2026-10-11. Raw logs and captures remain in the live guest and are uploaded at job completion; per-round evidence is available immediately.

## Hardware provenance and renderer

LocalSend3033 does not specify GPU/driver. NVIDIA RTX5090/580.82.09 appears only in linked Flutter185326. Both reports are by vegerot and quote the same error. This is supplemental context, not proof of an NVIDIA cause. Native EGL control reports virgl (LLVMPIPE (LLVM21.1.8,256bits)); app maps confirm MesaEGL. Exact in-process LocalSend GL_RENDERER and Flatpak GL_RENDERER were not measured.

## Snap evidence

Official Snap1.17.0 revision32 passed native Wayland200% in three startups. Package SHA-256:04f8fe0af5a7cfa361d7d617e50714f16a753e048b48f7a4bb21a89189c96b16. Actual process environment confirms revision32 and native backend. Output scale2, logical960×540, physical904×1198 at buffer scale2. Updated complete archive:raw-traces-3033-snap.tar.gz, SHA-256 da9162dc2b81506c6b4cc5e8b97c5daedcf5b36e30ff995ba40db88c1facdeef. Evidence:rounds36–37 and original-scenario-matrix.md.
