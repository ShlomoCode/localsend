# Issue 402 evidence review

Read-only independent review on 2026-10-11. NBJ writing guidance applied. No app, build, test, job, device session, or reproduction was started; no product file was edited. The parent owns the stop decision.

The ten-condition packet supports non-reproduction of the original Ubuntu20 file-picker case in the tested configurations. It does not establish a cause or a historical fix. I read the raw issue metadata and all six comments, the triage issue summary, STOP-GATE, STATUS, EXPERIMENTS, both existing independent reviews, and the original retained screenshot. The screenshot shows Files:1 and Size:0 B. The reporter explicitly confirmed file-picker selection. The release, installation format, desktop, backend, target location/filesystem and receiver were not specified.

## Independent raw checks

I recomputed SHA-256 and byte counts of all 30 saved receiver files across E1–E10. Every file is 1,280 bytes and matches 0db53a1320c10f437c2bdca9b4d4049b74f2729f7a07cb3d656b62226311f014. Each condition has saved/1/whatever.txt plus saved/2/another.txt and saved/3/another.txt. This independently confirms the names/contents in the receipts, rather than relying on the ledger claim.

I sampled E6, E9 and E10 more deeply:

- E6/run15: sender environment records Ubuntu20.04.6, GNOME3.36.9, GTK3.24.20, zenity3.32, X11, DISPLAY=:0, real GDM Xauthority/session bus and ubuntu:GNOME. Session data directories include host desktop paths. release-sha256.txt records the official v1.8 hash 49eb71c34bab7c90a21c8f8cb3e220ae88b508b0a00741f906c57a464c7204c1; mountinfo-appimage.txt records a read-only fuse.LocalSend.AppImage mount. The retained 1-another.txt-transfer.png visibly shows GNOME, another.txt (1.3 KB), Done and Finished. events.json records a valid relative fixture, three selection/verified-transfer pairs, and real GUI manual-address/IP/Confirm actions. Receipts and actual archived hashes agree. This supports native desktop/AppImage fidelity and successful selection/transfer, not discovery parity or physical-machine equivalence.
- E9/run19: retained 1-another.txt-picker-row.png shows real KDialog, another.txt with symlink icon and target-size1.25 KiB, plus ordinary whatever.txt. That image is before the row action; events.json subsequently records the actual another.txt pointer click at x489,y239 and bottom Open at x894,y526, then successful receiver verification. Raw picker stdout preserves /home/probe/fixture/another.txt for both repeats. Receipts and independently hashed saved bytes agree.
- E10/run20: events.json records selection_mode=row and actual accessible-row-pointer events for another.txt, followed by two verified transfers. Raw picker stdout preserves the symlink path. Retained 2-another.txt-transfer.png visibly shows another.txt (1.3 KB), Done and Finished. Receipts and independently hashed saved bytes agree.

## Challenge to the ten-condition count

The ten entries are legitimate distinct configurations, but they are not ten independent environments or ten independent root-cause tests. E2 changes selection path; E3 changes release; E4 changes backend; E5 changes link target form; E6 changes native desktop and AppImage launch; E7/E8 change valid link topology. E9 fills backend×row and E10 fills release×row interactions. Their two repeats strengthen consistency within each condition and do not add conditions. The ledger correctly separates failed infrastructure attempts and excludes them.

The strongest uncertainty reduction for the original report is E6: it addresses GNOME/FUSE differences absent from the XFCE/Xvfb cases. Choosing manual IP changes discovery, but the reported symptom is already visible as zero metadata before peer selection; correct nonzero size and exact symlink output remain relevant. Restoring actual session environment without changing AppImage bytes is legitimate infrastructure repair, not proof that a packaging change fixed402.

## Remaining leads and bounds

1. The December2024 comment explicitly reports macOS reproduction. It supplies no macOS/app version, selection details or screenshot. The Linux matrix cannot dispose of that claim. It is a real full-thread lead if the parent scope includes all claims attached to402; it does not justify speculative code or imply the Ubuntu bug is reproduced.
2. The October2025 comment selects a directory containing links and ordinary files. That is a distinct directory-traversal scenario, correctly kept separate from the original individual-file-picker report. Successful individual-file tests do not resolve directory omission.
3. Original version/package/backend and target filesystem remain unknown. v1.8/v1.7 are documented historical assumptions. The supported qarma backend is not in the ten-condition matrix, and no report evidence identifies it as the original backend. These are coverage limits rather than observed failures or a demonstrated next discriminator.
4. E6 is a native GNOME guest with virtual display/VM kernel and a known manual-address route; most other conditions share one XFCE/container environment and payload. No claim of exhaustive Ubuntu20 coverage, current-release fix, physical desktop equivalence, macOS coverage, or historical cause is supported.

I found no mismatch in the sampled evidence and no basis for a product patch. A parent decision should describe the original Ubuntu file-picker investigation separately from the unversioned macOS claim and later directory omission. I have not decided whether to stop.
