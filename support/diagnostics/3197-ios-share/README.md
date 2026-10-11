# iOS share delivery observation

Diagnostic source patch for `share_handler_ios` **0.0.15**, resolved by baseline **c1ce322fb3acf08e44f329b8b7208b8b0d91e244**. It logs only stage, process/bundle/group identifiers, container availability, and ShareKey presence/length. It does not change routing, entitlement files, group choice, stored payloads or completion calls.

The extension logs inherited lifecycle boundaries and shared-default writes. The Runner plugin logs registration and URL/defaults reading. Querying defaults and containers adds diagnostic work and may affect timing. A passing diagnostic must be confirmed using an uninstrumented artifact.

After pub resolution and before Pods/build, run in the remote build environment:

```sh
node support/diagnostics/3197-ios-share/apply-observation.mjs /absolute/resolved/share_handler_ios-0.0.15
```

The installer checks both original files and patch hashes before mutation, then verifies output hashes. It deliberately fails on another version, already-instrumented source or an unexpected source edit. Preserve the patch and manifest with the resulting IPA SHA-256, exact dependency lock, entitlement/signing inputs and build run identity. Do not overwrite the original IPA.

Collect `LS3197_OBSERVE` lines from both processes. First verify extension log coverage. A missing extension line in an app-filtered log cannot establish that the extension did not launch. Suite construction and matching key lengths do not prove cross-process storage identity. `shareKeyLength=-1` means the value is absent or is neither Data nor String; interpret it together with `shareKeyPresent`.

No local application, build, test or emulator was run. The patch is an infrastructure observation and does not reproduce issue 3197's completed-transfer sequence.
