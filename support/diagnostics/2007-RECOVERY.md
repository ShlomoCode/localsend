# Issue 2007 recovery, 2026-10-11

## Recovered evidence

Authoritative branch before new diagnostics: `c09837914e6b05a94c4dfacdccf26abd48969ea7`.
Actions run 38157946402 completed both arms on one Samsung Galaxy S21 Android 11 allocation, session `2fb9d4838032629d6707a37d67bbb6de1d738d6b`.
The untouched current applications use source `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`. Linux differs from the report's Windows 11 24H2, and Samsung differs from vivo IQOO Pro. The report does not identify the original LocalSend version.

Both unique filename baselines received 62 bytes with SHA-256 `05f0010c2385c7b712758a04e6816e0560cfb8aa7091d1e9d8b1aac392c796e9` through real desktop selection and Android acceptance. Samsung My Files Trash removed the visible path. Immediate resends failed after Accept. Same-name retries also failed after matched delays:

| Arm | Failure to retry submission | Trash to retry Accept | Receiver PID |
| --- | --- | --- | --- |
| Wait | 45,037 ms | 48,624 ms | 14646 throughout |
| Normal terminate/activate | 45,012 ms | 48,740 ms | 14646 before, 21773 after |

MediaProvider PID 9209 and My Files PID 16782 persisted across the restart. Logcat records four `Failed to create ... File exists (os error 17)` failures, including the restarted PID. Retained screenshots show Finished with error; clicking the file row did not expose the full exception, so the logcat provides the exception evidence. A fresh second filename succeeded after the first name's failure on this same unit.

Raw artifacts are in `/tmp/localsend-2007-recovered/run38157946402/issue-2007-original-app-control-38157946402/`. Full video is 338.593544 seconds, SHA-256 `08c0884c2a4899e6cc297d5d3457ababed443ecbfb9c75e3bf1d21383d8e846f`. No UTC-to-video-PTS mapping is assumed. Archive run 38158041740 contains the earlier incomplete run 38156611268, not this completed comparison.

## Competing explanations and predictions

1. A retained MediaStore row reserves the original path/name after Trash. Query inclusion of trashed rows should expose the row while the original path is absent. A real permanent purge should remove the row; same-name transfer recovery would support that row as the cause. Prior cross-allocation purge failure prevents assuming recovery.
2. MediaProvider/FUSE path state survives even when the row is removed. The same-name create can still return EEXIST after permanent deletion with no matching visible row and an absent original path. A fresh-name receive should continue to work. An empty row result is informative only after known-present fixture rows establish observer visibility.
3. A physical alias or hidden moved file, rather than the query-visible row itself, keeps the original name occupied. Record row `_data`, `relative_path`, `is_trashed`, ownership and actual original-path existence at every transition. A separate normal file-manager same-name creation would distinguish LocalSend-specific creation from a shared provider restriction.
4. LocalSend keeps an in-memory name reservation. Real PID replacement failing while a fresh filename works weakens this explanation; it does not exclude application persistence or common storage-layer behavior.

## Next discriminating experiment

Keep a single new allocation and untouched LocalSend binaries. A separate normal diagnostic helper requests its own all-files permission through Android Settings and performs only exact, unique runner-owned filename queries. Record permission screens and status, default/include/only trashed query modes, raw errors, path metadata and application/provider process identities before baseline, before Trash, after Trash, after first failure, after real owned-item permanent purge and after the same-name actual receive retry. Then receive identical bytes under a fresh name on the same unit. Never clear provider data or alter LocalSend's permissions/data. The helper changes are source diagnostics, not a proposed shipping fix.

Issue 1597's maintainer comment describes a few-megabyte hang without an exception and recovery after Trash purge. Issue 2007 is an immediate name-reuse EEXIST/500 failure. Shared suspicion is not proof of duplication. Issue 2007's broad cache-clearing/VPN comments do not establish the exact name-reuse cause.

Storage-observer attempt 38162572542 compiled and passed transport controls, then stopped before any application transfer. Samsung granted the helper's own all-files switch, but Settings remained above the helper in its task after activate_app. Raw permission screens show the enabled switch; later readiness XML still belongs to com.android.settings. This is a driver lifecycle failure, not a new product observation. The diagnostic now performs actual Back and verifies the helper button before proceeding.

Run 38163020641 completed a real same-allocation Trash failure, native owned-item permanent purge with empty-bin observation, and failing same-name retry after 45,023 ms. A fresh-name receive on the same allocation then saved identical 62-byte content (SHA-256 `ebb5d621f4219dc8ed2fe8cf83306c5386134d0b4b38f005a2ae6b4b8004b845`). The observer had all-files and read permissions and could stat the initial file, but its MediaStore queries were empty even before Trash. Query sensitivity was not established, so those empty results cannot prove row removal or absence.

The refined observer removes the Download-only filter, matches either the unique exact name or exact original path, includes pending rows, and pre-registers returned owned row IDs for later queries after name/path changes. A known-present baseline must have a visible row before any Trash action; otherwise the next experiment stops as an observer visibility failure rather than repeating a non-discriminating resend.

## Comparison with issue 2793 and fork PR 5

The full issue 2793 body and four comments describe Windows 10 x64 / Android 11, both LocalSend 1.17. The reporter's log names `/storage/emulated/0/Download/android-release-unsigned.apk`, `PathExistsException`, `_File.open`, and `_FileStreamConsumer.addStream`, with errno 17. Later comments narrow the failure to APK names starting with `android-release-`, while other names work. No deletion/Trash trigger is documented.

Fork PR 5 changes MIME arguments only inside the SAF content-URI and SD-card branches. The official 1.17 source sends plain internal Download paths to `File(destinationPath).openWrite()` without either MIME argument. Therefore that patch does not affect the demonstrated direct-path error. Its PackageManager-scanning explanation is not established by the report or this source comparison.

The missing-visible-file/name-specific errno-17 observation resembles issue 2007. APK/prefix sensitivity, the 99% display and Oplus/ColorOS log evidence differ from our observed Samsung Trash trigger. Keep the reports separate pending actual causal evidence. Raw files are retained at `/tmp/localsend-2007-recovered/issue2793.json`, `forkPR5.json`, `forkPR5.diff` and `file_saver-v1.17.dart`.

## Supported completion scanner comparison

Run38164023600 established observer sensitivity. Its completed first receive had original row58, LocalSend owner, pending1, null indexed size, actual62bytes. Samsung MyFiles Trash moved the inode to a new customTrash row68 but left original row58 at the absent Downloadpath. Real owned permanentTrash purge removed68 but left58; same-name resend still failed after45,016ms. A fresh-name receive worked. Full raw bundle is retained durably in the sprint workspace `issue-2007-raw-38164023600/`.

Parent requested public `MediaScannerConnection.scanFile` after a fresh actual receive completed, before nativeTrash, against matched waiting on one allocation. The separate helper allows only exact run-owned received fixtures; it records callbackURI/time, rows/stat, build/provider identity. It does not directly update/delete another app's row or change LocalSend permissions.

Run38165434041 failed oldaapt manifest packaging before allocation. Run38165673086 completed waiting failure and scanner publication (same row122 pending1→0,size62, unchanged path/owner/inode, nonnullURI), but cloudrouting reported404 during concurrent missingpathpull/source. Raw Appium remained responsive afterward; no scannerarm resend was submitted. These are infrastructure/partial results, not resolution evidence. Full raw plus Appium/cloudcommandlogs retained durably.

Run38166895716 head`cd45aacd541156a5345950b6bbd5c830edffa93a`, session`3025510ef6f1682bbc05a025d084892adeeecc40`, completed both actual arms with serial WebDriver requests. SamsungS21 Android11 buildG991BXXS3AUJ7, MediaProviderGoogle11-7248014/code30. PIDs LocalSend20204/MediaProvider9584/MyFiles20177 unchanged throughout. Both first receives and scanner resend saved62bytes SHA256`6206e710a3cb88383c11fdca6827227cd4513e4e77a1ba39052fbb8368b7f6cf`.

- Wait45,005ms retained pendingrow58; nativeTrash created68 while58 persisted at absent originalpath; real same-name Accept failed with errno17.
- Scan44,999ms returned URI70 after25ms and published same70 (pending1→0,size62, owner/path/inode8731 preserved; immediate postscan hash exact). NativeTrash removed original70 and created77 with inode8731; originalpath was absent. Real same-name Accept saved exactbytes at originalpath and showedFinished/fileDone; sender loggedsuccess19:17:22.955268. New pendingrow78/inode15055 appeared at originalpath.

Raw summary scanner`resendSucceeded=false` is a UIparser false negative: it expected literal`100%, Finished`, while actualXML is`100, Finished` plus exactfixtureDone. Raw summary remains unchanged. Separate `corrected-resend-derivation.json` cites XML/screenshot/senderlog/hash/rows/PIDs. Future parser accepts both observed formats and requires exactfilenameDone. The entire bundle, `CAUSAL-REVIEW.md` and two inspected7second continuousclips are durable in `issue-2007-raw-38166895716/`.

This demonstrates a supported preventive scanner effect on this SamsungAndroid11 implementation, including originalrow removal byTrash and actualsame-name save. Scanner changes metadata and may invalidate cache; do not isolate a singlecolumn or generalize originalvivo mechanism. No productionpatch or shippedapp validation has been accepted yet. Parent causal gate and fresh independentreview are next. Do not implement stale-row deletion as workaround.
