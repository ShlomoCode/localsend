# Exact APK manifest and API29 storage condition

Input APK: `/tmp/localsend-bug-3393/evidence/baseline-1.18.2-arm64.apk`, SHA256 `82ec3568fba2aa5295b9aae8b76f701d7a4703d86b9f8bad749472038fbaeab3`.

Extracted binary `AndroidManifest.axml`, SHA256 `12cc84245ecbd9d47c70ead8f5dc8d229ac3cda96cd6024d8ddb458139b97109`. `parse-axml.mjs` reads Android resource chunk headers, string pool, resource map and typed element attributes without Java. Full results including raw typed values, resource IDs and binary offsets are in `apk-manifest.json`.

Binary facts:

- package `org.localsend.localsend_app`
- versionName `1.18.2`, versionCode 643
- minSdkVersion 24, targetSdkVersion 37, compileSdkVersion 36
- application `requestLegacyExternalStorage=true`: resource ID `0x01010603`, type `0x12` (boolean), data `0xffffffff`
- no explicit `debuggable` attribute on application
- permissions include READ_EXTERNAL_STORAGE (maxSdkVersion 32), WRITE_EXTERNAL_STORAGE, READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_AUDIO, ACCESS_MEDIA_LOCATION; no MANAGE_EXTERNAL_STORAGE permission

These are properties of the actual tested file. Its version name alone does not prove identity with a separately downloaded official release. The target37/compile36 pair is unusual and should be retained exactly rather than silently normalized to expected release values.

## Does this enable the Media copy condition?

The exact APK photo_manager branch requires `SDK_INT == 29 && !Environment.isExternalStorageLegacy()` (saved `w2/C0783a.java:21`). A new uncached asset then invokes the full-stream cache copy (`:250–295`). A provider choice is not a term in this condition.

Android10's requestLegacyExternalStorage flag requests opting out of scoped storage. Thus this manifest supports ordinary API29 legacy access, not a deliberate scoped-storage setup. It is a request rather than a runtime measurement: installation history, platform/OEM policy or preexisting compatibility state have not been inspected. Do not claim the flag alone proves the observed process returned true. Android11 behavior is different (target30+ ignores the legacy request), but this exact photo_manager full-copy gate is false on SDK30+, so merely upgrading the phone is not a test of this exact copy branch.

## Observing the original process lawfully

`Environment.isExternalStorageLegacy()` is an ordinary API when called by the application whose state is being queried. There is no package-name argument for querying another application's runtime state. The overload taking a File path still queries the caller's access to that path, not another package. A helper's call therefore cannot establish LocalSend's value.

No exposed original-app method channel/UI/report field returning this value was found. Exact APK photo_manager supports methods such as systemVersion, forceOldApi and logging, but neither establishes an ordinary user-facing cross-package query for the legacy boolean. Its cache messages are gated by `B2.a.f485b`, which defaults false; missing PhotoManager cache logs do not prove no copy.

PackageManager's ordinary ApplicationInfo metadata can independently expose target SDK and the legacy-request manifest flag for an accessible package, but that is metadata, not the original process's runtime Environment result. Checking app ops or platform compatibility settings would be privileged/state-specific and is outside the requested ordinary UI condition. Do not alter these settings or use permission/manifest toggles, instrumentation, shell compatibility switches, hooks or fault injection.

## Legitimate condition proposal

For the unchanged tested APK on ordinary Android10 with its legacy request honored, no provider-only selection is established that legally turns on this explicit photo_manager copy branch. Keep this as an untested/unavailable condition rather than relabeling another path as the same condition.

A lawful scoped-storage Media test would require a separately identifiable, unmodified official application artifact whose binary manifest naturally omits/sets false the legacy request, on API29, with the same native copy gate verified in that artifact. Use a newly indexed, uncached real video and normal Media selection; preserve exact app hash, manifest, device/API, provider/source, UI timing and any available natural evidence. No such official artifact has been established here; this is a conditional proposal, not a verified candidate. An alternative ordinary official app on API29 may legitimately exercise scoped media access, but its findings must be reported as that app's behavior, not original LocalSend's branch.

File provider experiments remain useful for provider metadata/access latency, and native Share remains a distinct demonstrated cache-copy seam. Document any switch from MediaStore/Recent to another root or source. Do not imply a new provider proves the original app's legacy mode or a byte-copy operation.

The MainActivity APK decompilation gap remains: File SAF details are source-tag evidence, while manifest, photo_manager copy gate and ShareHandler stream-copy evidence are exact APK artifacts.

Documentation checked through Context7: Android Developers `https://developer.android.com/guide/topics/data` (scoped storage default) and API29 Environment diff `https://developer.android.com/sdk/api_diff/29-incr/changes/android.os.Environment` (File overload checks app legacy access). Full Android11 storage HTML could not be retrieved from shell due DNS restrictions; no runtime API calls were performed.
