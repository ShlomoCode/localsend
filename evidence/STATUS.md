# Issue 3556 investigation

The release failure is not reproduced yet. No production patch or corrective PR is justified.

Reported: LocalSend 1.18.2 on Samsung S20 sends a 16gb file to Win10 Pro over a 2.5g network. Selection requires repeated **Wait** responses for 3–4 minutes; the transfer eventually succeeds while Android still reports that LocalSend is not responding. The Android version, file type, picker button, installation source, and GB/GiB interpretation are unknown. The issue has no comments or attachments.

Owned clone: `/tmp/localsend-bug-3556`; diagnostic branch: `codex/diagnose-3556-large-file`. Baseline tag `af0416be50770a97760f7070684bc667b759a15c`. Official ARM64 APK SHA-256: `82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3`.

Samsung Galaxy S20 / Android 10 is available in the BrowserStack catalog. The live plan check returned zero running sessions and capacity five. No session has been allocated. The initial Actions limit is one job. Small-file real-app control, measured storage capacity, and a bounded timeout precede large transfers.

Source mapping: **File** uses ACTION_OPEN_DOCUMENT, SAF metadata and a content URI; it does not establish a cache copy. **Media** calls `AssetEntity.originFile`. External shares use share_handler. Upstream PR 3395 proposes independent media/share/thumbnail changes, but it is not evidence that this reporter chose one of those paths.

Transport: common cloud relay 6245733 verifies desktop sender to Android receiver only. Reverse Android sender to Windows receiver is not verified. Coordinating reverse support with cloud_recon; no use of the shared nearly full development server.

Next: stage a small valid media/data fixture with a separate session-owned helper using public Android APIs, record available storage, validate real app selection and transfer, then compare File/Media/share at 16,000,000,000 bytes (decimal interpretation, explicitly recorded). Preserve ANR dialog screenshots, timing, logs, and sent/received hash.

Meaningful reproduction experiments completed: 0. Infrastructure checks do not count.
