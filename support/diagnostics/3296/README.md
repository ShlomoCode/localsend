# Diagnostic 3296: actual NVDA release episode

This chain consumes unchanged official LocalSend 1.18.2 Windows x64 portable bytes
and the normal official NVDA 2025.3.3 portable launcher. It builds no app and adds
no speech hook. It uses native foreground, mouse and keyboard input on the runner
input desktop. Windows Server 2022 differs from the reported Windows 10/11; the
report does not identify numeric app or NVDA versions. Android is outside this episode.

The job is capped at 20 minutes. A standalone supervisor limits all setup and
scenario work to 15 minutes from the first workflow clock, leaving five minutes
for owned cleanup, hashing and artifact upload. Scenario phase deadlines are at
minutes 4, 8, 11 and 15. Capture-tool acquisition consumes the same absolute budget.
Each native UIA COM connection/transaction timeout is two seconds; UIA is supplemental.

`supervise.ps1`, `retain.ps1`, `ui.ps1`, `controls.cs` and `native.cs` reuse the
3536 consuming chain; the original native helpers came from 3456. Retention always
runs and matches PID, executable path and start time before stopping owned processes.
Exit receipts distinguish a real integer exit code from a null/unknown observer.
Original screenshots, speech log segments, input timestamps, settings values,
artifact hashes/signatures and continuous native desktop capture are retained.
The package and executable bytes are hashed; signing status is recorded rather
than requiring a signature that the official app may not carry.

NVDA uses documented `--create-portable-silent`, `--portable-path`, `--config-path`,
`--log-file`, `--log-level 12` options. Actual `Speaking` records from the normal
NVDA speech source are parsed only following the matching I/O speech header.
Notepad first receives a native typed sentinel and Home. A subsequent actual
Insert+Up must speak the complete sentinel; ordinary File-menu name/role speech
must also work. Failed speech, input, desktop or ownership controls are ENV_BLOCK.
No target conclusion uses raw UIA alone. Speech Viewer is optional and not needed
when these authentic input/output logs qualify.

The fresh ordinary app profile seeds only English and the ordinary release
whats-new value. It does not guess a settings schema/version or force Quick Save.
The original extracted-profile presence/hash and source profile hash/settings are
recorded. Persisted bool/enum/missing keys are supplemental only; they never define
the behavioral oracle. The actual mapped checkbox's native Off/On state, original
pixels and real speech define baseline, genuine opposite operation and restoration.
Unsupported native state remains unknown and requires raw pixel/speech review. Settings receipts redact security context private
keys while preserving its source hash. No original user profile is accessed.

An exact visible Quick Save label and unique checkbox bounds qualify a mouse
operation, actual native checkbox state transition, normal Close notice and restoration.
The control is attributed only after this working operation. The scenario re-enters
Settings with bounded native keyboard navigation, then records up to 40 Tabs,
actual focus objects, screenshots and Insert+Tab speech. A repeated runtime focus
identity marks a bounded cycle. Ambiguous mapping/focus blocks the environment.
At the already mapped control, Insert+Tab, Space, real state/notice and restoration to the actual original state
are captured. The continuous decisive capture is intrinsically capped at ten seconds.

Outputs are candidates for raw review: missing label/role/state at the known
control is a named-control symptom candidate, and a complete traversal cycle
without the target is a reachability candidate. Neither is an accepted failure
before reviewing original speech and pixels. A missing speech record blocks the
comparison. A complete named control/real operation is only non-reproduction for
this selected artifact/OS/NVDA condition. No repetition is run on an unreviewed
candidate. Source preparation does not authorize dispatch, publication or a fix.

## Round 2 source preparation

Each download, hash, extraction, discovery, PE check, and signature observation runs in a separately supervised PowerShell child. Original stdout, stderr, invocation, phase, exit, and identity receipts are retained. Downloads and hashes remain mandatory. Signature metadata contains primitive fields only; a timed-out signature is supplementary UNKNOWN only after exact original-child exit and absence are confirmed. The first artifact sequence shares a 240-second ceiling; runtime metadata shares 40 seconds. The setup phase has six minutes within the unchanged absolute 15-minute scenario and 20-minute Actions job.

Settings navigation uses the complete exact three-item English release labels, supported control types, process ownership, and client bounds qualified in diagnostic 3317. The Notepad speech control, actual keyboard gestures, Quick Save state comparison, original speech logs, finite clip, and environment exclusions remain required.
