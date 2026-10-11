# Android11+ feasibility for original APK Media copy

Conclusion: Android11/12+ is a lawful scoped-storage environment for this unchanged target37 APK, but it does not activate the APK's API29-only Media cache-copy branch. Treat such a run as a separate OS/scoped-media comparison, not fulfillment of the API29 copy condition.

## Exact APK selection and gate

Saved JADX paths are relative to `evidence/run-38133514531/apk-analysis/decompiled/sources/`:

- `t2/C0694a.java:82`: manager selection is `(forceOldApi || SDK_INT < 29) ? C0785c : C0783a`.
- `w2/C0783a.java:21`: cache-copy flag is exactly `SDK_INT == 29 && !Environment.isExternalStorageLegacy()`.
- `w2/C0783a.java:250–295`: `b(context,id,origin)` makes `pm_<id>[_o]_<modified>` only when that flag is true; if the cache file is absent it opens the media URI and copies the entire stream. Otherwise it returns the asset path `f9624b`.
- `w2/C0785c.java:259–268`: old manager's same interface method returns the asset path directly.
- `t2/C0700g.java:183–186`: forceOldApi sets the old-manager switch; it does not create another API30 copy manager.
- `w2/InterfaceC0787e.java:131`: the file method is abstract, so there is no default-interface fallback that adds API30 file caching.

| Environment | Default selected manager | Copy flag | File-result branch |
| --- | --- | --- | --- |
| API<29 | C0785c | Not applicable | Asset path |
| API29 legacy | C0783a | false | Asset path |
| API29 nonlegacy | C0783a | true | pm cache, full copy if uncached |
| API30+ scoped or legacy | C0783a | false (SDK term fails) | Asset path |
| forceOldApi on any SDK | C0785c | Not applicable | Asset path |

No additional API30-specific manager selection is present in the recovered selection function. Other stream uses exist but are separate APIs: C0783a's original-byte method reads bytes; EXIF method `o` opens a required-original stream; interface `w` copies data when importing/saving a new asset. They are not an alternative `b` implementation for originFile selection. This does not claim every operation in photo_manager is copy-free.

Source tag v1.18.2 `cross_file_converters.dart:16–29` calls `asset.originFile`, length/metadata and retains the path. Android Media uses AssetPicker/photo_manager. The APK method-channel dispatch `C0700g.d` and cursor asset constructor `f0/AbstractC0304i.q0` have decompilation gaps, so the precise complete originFile-to-native dispatch is source/API correspondence rather than fully recovered instructions. MainActivity APK vs source caveat also remains. None of those gaps changes the explicit SDK predicate visible in the native file-result implementation.

## Official Android documentation

[Android11 storage updates](https://developer.android.com/about/versions/11/privacy/storage), read 2026-10-11, states that the legacy request is ignored for apps targeting Android11+, while keeping the request preserves Android10 compatibility. It also documents direct File/native path access to shared media on Android11. These are consistent with this APK using direct asset paths on API30+, even though storage is scoped. Scoped storage does not imply that every native media plugin must materialize a full private cache file.

The binary manifest is independently preserved in `apk-manifest.json`: target37, requestLegacyExternalStorage=true. This establishes manifest intent, not the API29 process's actual Environment value. No compatibility or permission switches were changed.

## Closest lawful provider environment

BrowserStack's [public App Automate catalog](https://www.browserstack.com/list-of-browsers-and-platforms/app_automate), read 2026-10-11, lists Galaxy S20 Android10, Galaxy S21 Android11 and12, and Galaxy S21 Ultra Android11. The previously saved authenticated provider catalogs `/tmp/localsend-bug-3393/evidence/android-oem-catalog.json` and `devices.json` were also read; the relevant Samsung records are preserved in `samsung-catalog-preserved.json`. A Galaxy S21 Android11 is the closest Samsung/OS change candidate to the observed S20 Android10. Catalog inclusion does not establish current allocation availability; no fresh API call, device reservation or workload was performed.

If chosen later, record the change of phone/API/provider/source explicitly. Use the unchanged APK, ordinary permission UI and a real newly indexed MP4. Observe Media selection and input responsiveness, preserving exact artifacts. A quick result would fit the direct-path branch; a slow result would need independent cause analysis and must not be called proof of API29 cache copying. No 16GB network run is proposed.

To lawfully exercise the exact API29 nonlegacy branch, an independently identifiable official artifact/device combination must naturally use nonlegacy API29 storage and retain this native predicate. Changing only to Android11 cannot satisfy `SDK_INT ==29`. No such official API29 combination is established in this review.
