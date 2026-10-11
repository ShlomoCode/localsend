# Gal issue 2311 component checks

This diagnostic module compiles an immutable `GalPlugin.java` blob from the supplied Gal commit. The cloud runner records the commit, verifies the supplied SHA-256 before and after testing, and retains the source, license, logs, and test results.

The tests call the plugin's public `onMethodCall` entry point. Flutter API classes in this module are compilation substitutes. The controlled content provider creates actual host files, and the scanner shadow supplies specified callbacks. The module does not test Flutter transport, Android MediaProvider, a physical device scanner, EXIF parsing, or a real Android scan race.

The checks cover these observable results:

- An epoch-zero source retains its actual modification time and bytes after an opted-in import.
- The default import does not opt into modification-time preservation.
- A missing source fails before an item is inserted.
- An output failure deletes only the item inserted by the failed operation.
- Duplicate callbacks preserve the first scanner result, including a first null result.
- A withheld callback reaches the production method's actual 30-second timeout. The method reports one error and deletes its owned item. A late supplied callback does not produce another method result or delete the unrelated control.

The timeout check establishes Java result and rollback behavior against the controlled provider. It cannot establish whether a late Android scan recreates a real MediaStore row or file. The production scanner cannot be cancelled; device evidence is required for that question.

Run only in an authorized `ShlomoCode/localsend` GitHub Actions job, after provisioning JDK 17, Android SDK 35, and the existing Gradle wrapper. Pass the owned Gal checkout, full Gal commit, expected source SHA-256, wrapper path, and evidence directory:

```bash
bash support/diagnostics/gal2311-component/run-cloud.sh \
  "$GAL_CHECKOUT" "$GAL_COMMIT" "$GAL_PLUGIN_SHA256" \
  "$GRADLE_WRAPPER" "$COMPONENT_EVIDENCE"
```

SDK 29 is the configured Robolectric API level. Android 29 and Android 15 application transfers are separate runtime checks. This module's diagnostic minimum SDK does not change Gal's production minimum SDK.
