# Issue 3556 discriminating scenarios

The reporter does not identify the picker path, MIME type, Android version, or meaning of 16gb. These are planned legitimate variants, not claims about the reporter. Each scenario requires actual picker actions and observable ANR/dialog timing. Repeating the same scenario estimates repeatability but does not increase the distinct experiment count.

Before large transfer: verify the original 1.18.2 applications send/accept/save a small file and agree on its bytes and SHA-256. Verify the Android and Windows storage reserve and enforce a transfer deadline. Before interpreting a padded MP4, verify it decodes through Android's public media APIs and disclose that ISO-BMFF free-space padding produces its size.

| Scenario | Changed variable | Prediction to distinguish |
| --- | --- | --- |
| 1 | File / 16GB data in Downloads | SAF metadata and stream should avoid size-dependent selection delay. |
| 2 | File / 16GB valid MP4 | If video metadata triggers extra work, this differs from data. |
| 3 | Media / the same MP4 | originFile may create a cache copy before selection finishes. |
| 4 | Share / the same MP4 into running app | Main-thread shared-URI copy may produce a native ANR. |
| 5 | Share / same file into cold app | Plugin attachment may differ from onNewIntent. |
| 6 | File / matching 1GB MP4 | Size proportional delay distinguishes byte I/O from fixed setup. |
| 7 | Media / matching 1GB MP4 | Size proportional copy distinguishes media path from File. |
| 8 | Share / matching 1GB MP4 | Native copy scale distinguishes share from transfer delay. |
| 9 | Same MP4 / File / MediaStore vs Downloads provider | Provider behavior differs while app version and bytes stay fixed. |
| 10 | Data / File / folder selection | Directory metadata enumeration differs from single-file selection. |
| 11 | Same file / default encrypted vs legitimate encryption-off setting | Transfer CPU pressure may differ; selection ANR should not. |
| 12 | Same file / Samsung S20 Android 10 vs available S21 Android 11 | Device/OS boundary; record mismatch instead of calling it exact. |
| 13 | Same file / 16,000,000,000 vs 17,179,869,184 bytes | Explicit decimal GB/GiB boundary. |
| 14 | Same selection / no receiver contacted yet vs sending | Separates preparatory ANR from transfer-driven ANR. |
| 15 | Same baseline / original PR3395 independent change only | Only after a reproduced failure: controlled attribution to exact responsible path. |

Do not apply production corrections before observing a legitimate original failure. Choose the next scenario from the actual observations; infrastructure errors do not count.
