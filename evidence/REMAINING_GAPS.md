# Issue 2830: remaining reproduction gaps

Ten long-text conditions are parent accepted. Corrected selection screenshots and exact clipboard equality are parent accepted. No accepted condition reproduces the reported freeze, so there is no evidence-backed production patch or correcting-commit claim.

## Exact report gaps

| Report property | What was exercised | Remaining gap |
| --- | --- | --- |
| Xiaomi Redmi Note 10 Pro, MIUI 14, Android 13 | Galaxy S23 / Android 13 and Redmi Note 11 / Android 11 / MIUI Global 13.0.8 Stable | The original Xiaomi model/firmware combination is absent from the fresh BrowserStack catalog. About phone screenshot confirms the available Note 11 firmware; it cannot substitute for Note 10 Pro / MIUI 14 / Android 13 |
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

## Available-device firmware evidence

Run 38134203137 / 7e144bdd opened About phone using the standard Android DEVICE_INFO_SETTINGS intent without changing settings. The screenshot, inspected directly, shows Android 11 RKQ1.211001.001, MIUI Global 13.0.8 Stable / 13.0.8.0(RGCINXM), security update 2022-02-01, and model 2201117TI. The later XML already shows com.miui.home, so firmware-ui-result.json reports aboutPageObserved=false; that field checks XML labels, not the preceding screenshot. Firmware version is screenshot evidence. The reason Settings returns to Home remains unknown. Raw path: xiaomi-firmware-direct-38134203137/issue2830-physical-control/evidence/.

A fresh authenticated BrowserStack App Automate device catalog read at 2026-10-11 11:17:33 UTC returns 110 rows. Case-insensitive Xiaomi/Redmi/Poco filtering returns only Xiaomi Redmi Note 11 / Android 11.0 (device_limit 5). No Xiaomi Android 13 alternative is present; catalog rows contain no MIUI/firmware version field. The firmware screenshot confirms this available device uses MIUI 13.0.8. The final owned session status is done; the Actions run completed successfully. No owned job/session remains active. Sanitized evidence and screenshot hash: firmware-catalog-review.json.

Parent decision: investigation blocked after independent review of all ten conditions, firmware screenshot, and fresh catalog. No evidence-backed product freeze or cause is established. Resume only with new evidence: access to the original Redmi Note 10 Pro / MIUI 14 / Android 13 environment, or the reporter's exact clipboard source together with confirmed LocalSend build and settings. A legitimate native Windows 11 x64 sender can close the separate architecture gap. No additional arbitrary payloads, product change, PR, or upstream post is authorized by this checkpoint.
