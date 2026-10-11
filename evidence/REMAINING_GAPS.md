# Issue 2830: remaining reproduction gaps

Nine long-text conditions are parent accepted. Corrected selection cloud run and raw evidence pass; screenshots and exact clipboard equality await parent review. No accepted condition reproduces the reported freeze, so there is no evidence-backed production patch or correcting-commit claim.

## Exact report gaps

| Report property | What was exercised | Remaining gap |
| --- | --- | --- |
| Xiaomi Redmi Note 10 Pro, MIUI 14, Android 13 | Galaxy S23 / Android 13 and Redmi Note 11 / Android 11 | The original Xiaomi model/firmware combination is absent from the fresh BrowserStack catalog. Settings/About phone read-only diagnostic is being collected for the available Note 11; it cannot substitute for Note 10 Pro / Android 13 |
| Dell Inspiron 3501, Windows 11 Pro | Windows 11 ARM cloud runner executing original x64 1.17.0 release under emulation | Dell and native x64 execution are uncovered |
| Latest LocalSend release at report time | Original Android and Windows 1.17.0 releases, with recorded artifact hashes | 1.17.0 is date-based inference. Reporter does not explicitly name a version/build |
| Approximately 105K of original clipboard text | 105000 and 107520 ASCII, LF, unbroken, CJK and supplementary-plane emoji sources with explicit scalar/unit/byte counts | Original source, encoding, line structure, and meaning of K are unspecified |
| Freeze after Windows Send → Clipboard → target | Actual Windows UI flow and Android Preview on every accepted long-text condition | Report does not specify whether Preview appeared or whether an unstated receiver action triggered the freeze |
| Receiver settings unspecified | Quick Save Off in inspected screenshots | Exact settings unknown. In release 1.17.0, quickSave and quickSaveFromFavorites are gated by session.message == null, so toggling them does not establish a distinct message path |

## Evidence limits

CJK and emoji have complete Preview XML equality and responsive Copy→Receive. Parent acceptance explicitly excludes clipboard readback because Appium's io.appium.settings ClipboardReceiver adb broadcast times out after 20000 ms. This diagnostic timeout is not treated as a LocalSend defect or used to justify a product change.

The first selection attempt creates a visible highlight, selection handle and toolbar. Its later Copy action is invalid because the toolbar overlays the main Copy button and the coordinates hit Read aloud. The corrected same-condition run changes only diagnostic toolbar dismissal; it does not modify the product or count as another condition.

## Further experiments with a basis in the report

1. Run the retained 105000/105-KiB sources on the actual Redmi Note 10 Pro / MIUI 14 / Android 13 environment, using the same original applications and observable receiver actions. This directly closes the stated device/firmware gap; no OS or ROM modification is authorized or proposed.
2. Replay the reporter's original clipboard source, once it is available, with its exact version and settings. This tests the reported content rather than inventing additional inputs. No upstream message has been sent to obtain it.
3. If a legitimate remotely accessible native Windows 11 x64 sender becomes available, repeat the same source/device/settings with only sender execution architecture changed. This tests the emulation gap; Windows Server or a newer application is not evidence that the original report is resolved.

No new content variant is proposed solely to reach an experiment quota. The parent owns stopping and publication decisions. A newer release passing, a different Xiaomi passing, or code reading alone cannot establish that the historical bug was fixed.
