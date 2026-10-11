# Issue 3033: documented reproduction blocker

The investigation ended on 2026-10-11 after root review of 13 substantive conditions. The reported Wayland protocol failure was not reproduced. No production code was changed, no fix was demonstrated, and no pull request was opened.

The cloud VM matched Debian 13, GNOME 48.7, native Wayland and 200% scaling. Original LocalSend 1.17.0 binaries were exercised through Flatpak, native DEB and official Snap revision 32. All had identical app and Flutter engine hashes. Three Snap starts rendered without protocol errors, using physical buffers 904×1198 and transient 904×1120 at buffer scale 2. This does not establish that the reporter's host is fixed.

The VM uses QEMU virtio/virgl and Mesa. GPU and driver are absent from the LocalSend report; the author's linked Flutter report names NVIDIA RTX 5090 / 580.82.09. That supplemental context is an environment boundary, not a proven cause. The mixed-monitor Ubuntu/GNOME scenario in another user's comment remains a separate untested report.

## Evidence retained

- [13-condition matrix](original-scenario-matrix.md), including artifact links, repeats and limitations.
- [Experiment ledger](experiments.md) and [availability check](nvidia-availability.md).
- Snap PNGs: `round-36/snap32-trial-1.png`, `round-36/snap32-trial-2.png`, `round-36/snap32-trial-3.png`.
- Concentrated raw results: `round-36/result.txt` and `round-37/result.txt`.
- Guest logs, process maps, assertions and monitor states: `raw-full/evidence/`.
- Complete archive: `raw-traces-3033-snap.tar.gz`, SHA-256 `da9162dc2b81506c6b4cc5e8b97c5daedcf5b36e30ff995ba40db88c1facdeef`.
- [Snap starts artifact](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11705252456) and [traces/archive artifact](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11705392445) verified retained and unexpired before VM shutdown.

## Required to resume

Obtain a failing artifact, profile or trace from the original host: exact package revision and app/engine identity; GPU and driver; physical monitor modes, logical scale and compositor state; launch backend and environment; complete Wayland trace showing buffer creation, scale and failure; and repeatable actions including relevant profile state. Preserve a failing baseline before testing a candidate. A fix requires a causal experiment and the same failing scenario passing afterward, followed by cloud validation and required independent review.

No additional workload is authorized until new reproduction evidence arrives. Only the issue 3033 VM/job is being finished; sibling infrastructure is outside this shutdown.

Shutdown completed: the owned Actions job `114459162170` reports `completed/success` after the round 38 finish command, published in diagnostic commit `969b2041`. The [final evidence artifact](https://github.com/ShlomoCode/localsend/actions/runs/38135756388/artifacts/11706186302) is retained and unexpired (228,343,189 bytes). No sibling VM/job was changed.
