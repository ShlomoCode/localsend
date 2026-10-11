# Desktop drop 0.7.1 to 0.8.4 source impact

Reviewer: `sol_native_pair_audit`, `gpt-6.1-sol`, medium reasoning. This is an independent source audit. No applications, builds, tests, or runtime reproductions were executed for this report.

Recommendation: continue with the published, hosted `desktop_drop` 0.8.4 candidate. Its API remains compatible with LocalSend's usage, and its Android configuration supports LocalSend's existing AGP 8 setup. This report does not establish runtime success on platforms that have not been tested.

## Source identities and method

- LocalSend base: `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`.
- Plugin 0.7.1 source: `a3e2d018e85f957c08e9d0759fe979b2c9b028c2`.
- Plugin 0.8.4 Git source: `2ef30a7e96c185c926a7a2d210fc5f6b7d803248`.
- Portal correction: `af1fb55a82eab1912e6bb8a11d5bf284f7ed687d`.
- Published 0.8.4 package: the retained `desktop_drop-0.8.4.tar.gz`, extracted as `drop084-published` in the private recovery evidence.
- Reference: existing open PR3373 by loucass proposes the same hosted dependency update. Its linked Android validation claims were read but their run artifacts were not audited here.

The audit compared complete Git trees, relevant old and new source files, the published package, dependency constraints, and LocalSend's API and Android configuration. Missing historical blobs in the partial clone were retrieved through public Git source reads. No candidate source was edited during the audit.

Outside examples, tests, and the changelog, the old-to-new Git comparison changes only the plugin pubspec, Android Gradle configuration, four Dart files, and the Linux native implementation. The `lib` and `linux` diff is byte-identical to the isolated portal correction, with SHA-256 `dc34e608a43a43f6c9b80cd78de2e5ce22b7b104354f21f225db9c60fcc9022d`.

## Platform and API impact

| Area | Source change and LocalSend impact |
|---|---|
| Android | The Kotlin implementation, manifest, and settings are unchanged. Gradle raises the plugin's KGP declaration from 1.9.25 to 2.2.0, selects built-in Kotlin or KGP, and removes the explicit `kotlin-stdlib-jdk7` dependency. compileSdk 36, minSdk 16, and JVM target 1.8 stay unchanged. LocalSend's base uses AGP 8.12.1 and KGP 2.2.0, so published 0.8.4 selects KGP and `kotlinOptions`. Android build configuration is the main additional compatibility risk and needs validation using the hosted candidate. |
| macOS | The Swift implementation, Podspec, Swift package, and privacy manifest have identical Git blob hashes. Minimum OS requirements, file promises, and bookmark handling are unchanged. |
| Windows | The C++ implementation, header, and CMake configuration have identical Git blob hashes. |
| Web | `desktop_drop_web.dart` and `web_drop_item.dart` have identical Git blob hashes. The shared `channel.dart` adds a dbus import; this audit does not establish web compilation compatibility. |
| Dart public API | The package exports `events.dart` and adds optional nullable `rawText` fields to `DropDoneEvent` and `DropDoneDetails`. Existing callbacks and `files` remain available. LocalSend consumes `DropTarget`, `event.files`, and `file.path`, so no application API adjustment is indicated by the source comparison. `DropDoneEvent.toString()` also changes to report whether raw text is present. |
| Dependencies and toolchain | The only new runtime dependency constraint is `dbus: ^0.7.10`. Dart SDK `^3.5.0`, Flutter `>=3.0.0`, and all other dependency constraints are unchanged. LocalSend already locks dbus 0.7.13, which satisfies the added constraint. Flutter 3.41.9 and Dart 3.11.5 satisfy the declared requirements. |

LocalSend's `app/lib/pages/home_page.dart` distinguishes directories using `Directory(file.path).existsSync()`, dispatches directory and file additions, and changes to the send tab. It does not consume `rawText` or depend on constructors whose required arguments changed.

## Linux behavior and remaining risks

The native plugin registers `application/vnd.portal.filetransfer` before the existing STRING and URI targets, identifies that target, and sends its payload through `performOperation_portal` on the existing `desktop_drop` channel. It also copies selection data using the reported length rather than assuming NUL termination, rejects negative lengths, and uses automatic cleanup for the copied payload and argument value.

The Dart handler resolves the ticket using `RetrieveFiles` on the `org.freedesktop.portal.FileTransfer` interface at the Documents portal. It returns resolved paths as the existing `DropItemFile` type and propagates raw payload text through the new optional fields.

If resolution fails or returns an unexpected result, the resolver returns an empty list. It does not fall back to a URI target. LocalSend does not use `rawText`, so a failed resolution can still switch tabs without adding a file. This is a concrete behavior to examine during runtime validation, not a demonstrated regression in this audit.

The existing Linux URI path now rejects text without a URI scheme. File URIs are converted to local paths, and SMB/HTTP and other scheme-bearing values remain unchanged. Ordinary `file://` drag-and-drop should be included in candidate validation alongside portal drops.

## Published package differs from the Git snapshot

The published Android Gradle file contains:

```groovy
def builtInKotlin = agpMajor >= 9
if (builtInKotlin && project.hasProperty('android.builtInKotlin')) {
    builtInKotlin = project.property('android.builtInKotlin').toString().toBoolean()
}
```

The Git snapshot at `2ef30a7e96c185c926a7a2d210fc5f6b7d803248` omits the `builtInKotlin &&` guard. The published version therefore keeps AGP 8 on KGP even if the property is present and true. This difference does not affect the isolated Linux experiment, but it means Android validation must use the exact hosted package rather than assuming the Git snapshot is identical.

The complete Git package and published package also differ in changelog content and omitted repository/example metadata. Their `lib` and `linux` source content matches. The previous native-pair audit was bounded to those relevant sources and compiled native outputs.

## Alternatives

1. **Published 0.8.1:** This contains the minimal Linux portal correction but inherits the Android migration introduced in 0.8.0. Its Gradle source removes `apply plugin: 'kotlin-android'` and uses `kotlin.compilerOptions` without selecting an AGP 8 path. The changelog declares an AGP 9 host requirement. This conflicts with LocalSend's AGP 8.12.1 configuration and makes 0.8.1 an unsuitable whole-app dependency choice.
2. **Published 0.8.4:** This retains the same isolated portal source correction and includes the subsequent Android compatibility changes. PR3373 by loucass already proposes this dependency update in the application pubspec and lockfile. The reference PR cites AGP 8 and AGP 9 validation, but those external run artifacts are not evidence verified by this reviewer. The candidate still requires its own checks and scenario validation.
3. **Maintained backport or broader filesystem access:** A backport onto 0.7.1 could preserve the old Android Gradle configuration, at the cost of maintaining a fork and replacing a hosted release with a custom dependency. Broader filesystem permissions may make legacy URI paths readable, but they do not add recognition or resolution of a portal ticket. Neither alternative has a demonstrated advantage over the available released fix for this candidate.

## Evidence and limits

The principal source evidence is LocalSend's `app/lib/pages/home_page.dart`, `app/android/settings.gradle`, `app/android/app/build.gradle`, and base lockfile; the plugin's old and new Git trees; and the published package's `pubspec.yaml`, `android/build.gradle`, `lib/src/channel.dart`, Linux native implementation, and changelog.

The audit identifies source compatibility and concrete risks. It does not establish successful compilation, installation, drag-and-drop, or file reads on Android, macOS, Windows, or web. Unchanged platform source hashes reduce the scope of new native changes but do not establish runtime validation. This report also does not replace validation of the normal hosted 0.8.4 candidate or extend the earlier controlled Linux native-pair result to untested conditions.
