Research fixture only. No LocalSend source files are modified.

Pinned source: 9529e915f438d8edd8bdf23e9f7aab2261a8b3e6.
Actual FastDocumentFile.kt, FileInfo, and timestamp function copied verbatim.
BeforeEnumerator private listFiles is copied verbatim from pinned MainActivity.
AfterEnumerator applies only the native portion of fresh-names-paths-2096.patch.
ContextWrapper provides the real ContentResolver; Flutter UI/engine startup is not needed for this metadata method.
No document-ID-to-path algorithm is reimplemented here.

Remote GitHub VM only prerequisites:
JDK17; Gradle8.7; Android SDK command-line tools with platforms;android-34 and build-tools;34.0.0.
AGP8.5.2, Kotlin1.9.24, Robolectric4.13, JUnit4.13.2 locked in project files.
Set ANDROID_HOME to remote SDK location; accept SDK licenses only in remote VM.
Run: gradle --no-daemon :app:testDebugUnitTest --tests org.localsend.localsend_app.OpaqueFolderTest
Robolectric downloads its locked Android34 instrumented sandbox remotely.
Expected one passed test; results app/build/test-results/testDebugUnitTest/.
Evidence: app/build/fixture-evidence/native-folder-metadata.json.

Contracts:
- Real DocumentsProvider/ContentResolver returns opaque IDs and human display names.
- Native before sends only basenames; native after sends Download/name and Download/Comics/name.
- Root IDs tested: numeric16621, opaqueRoot, msf:16621, opaque/root:16621.
- Real Uri/DocumentsContract encoding and tree/document recursion exercised.
- Leaf URIs, sizes, null/valid timestamps preserved.

Qualification limit:
This is native Android-framework metadata integration under Robolectric, not a physical-device reproduction or whole Flutter app test.
Pair exported before/after FileInfo maps with exact existing Dart ContentUriHelper/AddAndroidDirectoryAction harness.
Before wrong transmitted opaque names occur in that real Dart stage; do not label native-before basename itself as the issue.

Batch5 fixture transport correction:
Robolectric4.13 ShadowContentResolver legacy five-argument query calls provider.query5 directly.
Android14 DocumentsProvider intentionally rejects that legacy provider entrypoint; actual Android
resolver Binder transport converts SQLarguments to Bundle then calls provider.query4.
ModernQueryResolverShadow restores this conversion and delegates actual framework provider routing.
No production FastDocumentFile/listFiles method or provider metadata/output is replaced.
Batch6 must rerun actual6tests; ShadowLog now emits caughtnativequeryexceptions fordiagnosis.
