# Package, app, engine and symbol provenance — run 38184349418

The retained full artifact supports the intended single AB cohort and exact reuse of the accepted B-engine application bundle from run 38164164206. The A bridge package built successfully and was the only package changed by its installation transaction. Symbol preparation failed to obtain all three requested debug files; its wrapper exit status of zero must not be treated as successful symbol preparation. The scenario exit status is 1, so provenance success does not establish a successful reproduction or functional result.

Evidence roots: `/tmp/2754-packaged-38184349418-full`, its corresponding compact artifact, and `/tmp/2754-accepted-app-evidence/issue2754-engine-app-retry-evidence-full/engine-app-B/bundle`. This audit performed only reads, archive streaming, digest comparisons, and inspection of retained logs. No builds, tests, apps, syntax checks, local reproductions, source edits or dispatches were executed.

## Cohort and accepted artifact reuse

`comparison/capture-scope.txt` explicitly records `selected_cohorts=AB-package` and `capture_root_name_evidence=1`. The comparison directory contains only the AB-package cohort. `guest/engine-selection.txt` identifies engine B and bundle run 38164164206; `guest/bridge-variant.txt` identifies A.

The retained source-bundle TAR is byte-identical to the accepted bundle. Independently computed SHA256 for both archives is `1fa3fb6808e47c6259031c52b6c49c05d241fd6475431aefb577556cd454922d`. All 58 retained files under the accepted bundle's `provenance/` have counterparts with identical SHA256 in this run's guest `source-artifact/provenance/`; no mismatch or missing counterpart was found. This includes app, engine, bootstrap, and additive shader-input provenance. The source manifest records LocalSend `c1ce322fb3acf08e44f329b8b7208b8b0d91e244`, Flutter framework `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`, engine source `42d3d75a56efe1a2e9902f52dc8006099c45d937`, original engine build run 38153341418, and application build run 38164164206.

Archive entries were streamed directly and independently hashed:

| Artifact | Actual SHA256 from archive entry | Runtime record |
| --- | --- | --- |
| `lib/libflutter_linux_gtk.so` | `1cb9ec7c0516575ef5cdcd452a5de53761680539e5f5d78db7c88a7bad254ab3` | Identical hash at `/home/mint/source-bundle/lib/libflutter_linux_gtk.so` |
| `lib/libapp.so` | `e34ebc05ed2bd6bea8ce59b4e088bb7f2904f86a8f04e0ad21269d5dc6f156d5` | Identical hash at `/home/mint/source-bundle/lib/libapp.so` |

`engine-loaded/process-maps.txt` shows those same source-bundle paths mapped into the app. The retained engine ELF note reports build ID `301dab74f9fa5a1d880dc6c3b744391b63a7844f`. The loaded-identity result states that engine path, SHA256 and AOT match the selected source-build manifest. These are retained guest observations, correlated here with the independently hashed archive bytes; the audit did not inspect a live process.

## A bridge package and build evidence

The candidate and the guest-installed DEB are byte-identical, with independently calculated SHA256 `56bb6918d757748b7e834ef2f8534664a28e92bec4f59453e8ac589ec8b29649`. Package identity is `libatk-bridge2.0-0t64`, version `2.52.0-1build1+localsend2754.1`, source version `2.52.0-1build1`, variant A.

The retained packaged bridge library at `package/build/debian-final/libatk-bridge2.0-0t64/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0` independently hashes to `a57454051a1c3ec2e43148cba6bb4ed550b18e9e106d7f83f81a466596e14297`. This equals the candidate manifest, `bridge-process-library.sha256`, and before/after app mapped-library records. The app process maps show the system-installed `/usr/lib/x86_64-linux-gnu/libatk-bridge-2.0.so.0.0.0`, with recorded build ID `c88dc5ceb3f29cb6dfbeee30473e90e846e2e4d2`; the package ELF note and process build-ID record agree.

The actual patch hashes to `d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d`, matching the candidate manifest. Its changed files are socket-adaptor.c, the test Meson definition, and socket-local-experiment.c. The three retained official source archives/control files independently match `official-source/source.sha256`; both retained patched-source files match `patched-source.sha256`. Package build result is exit status 0.

The original Meson JSON test log contains 10 suites, all `OK` with return code 0. The text summary records 10 OK, zero failures, expected failures, unexpected passes, skips or timeouts. Within `socket-local-experiment`, the retained TAP log has `1..11` and 11 named passing cases: valid methods, base contract, removed, disposed, reused path, reembed, owner removed in call, cross-method cycle, wrong thread, identity and remote process. This distinguishes 10 Meson suites from 11 checks inside the A-specific suite; these are recorded test results, not tests run during this audit.

The guest A installation plan and actual installation both report one upgraded package, zero newly installed and zero removed: only `libatk-bridge2.0-0t64`. Comparing `bridge-package/packages-before.tsv` and `packages-after.tsv` yields exactly that version change. `other-packages-before.tsv` and `other-packages-after.tsv` are byte-identical. This establishes the scope of the A package transaction; it does not claim that the VM had no earlier provisioning changes.

## Symbol preparation and runtime matching

`root-name-symbols/result.json` says `partial`. Each requested library has `download-failed-28` and an empty debug SHA256. The full artifact contains no downloaded `.debug` or `.partial` file under this preparation tree. All three download stdout files are empty. The retained stderr provides concrete failures: libatspi timed out after 45002 ms with zero bytes received; libdbus failed to connect after approximately 10002 ms; GTK timed out during SSL connection. `root-name-symbols-prepare-status.txt` reports `symbol_prepare_exit_status=0`; the script records missing debug information without treating it as a fatal wrapper error. Therefore no matching debug symbols were obtained or verified.

| Runtime library/package version | Recorded runtime build ID | Recorded runtime SHA256 | Debug status |
| --- | --- | --- | --- |
| libatspi.so.0.0.1 / 2.52.0-1build1 | `d53e3f4bf82655a42a0cb86c25416fd443ee76c6` | `4af877d2d235b7eaab015abe6d81b82c82fe506a5d71403b9bbdfcbce99e8141` | download-failed-28 |
| libdbus-1.so.3.32.4 / 1.14.10-4ubuntu4.1 | `47829078e4267099473c6cf5f5742f16ccb2644d` | `a6ae7b4ef48562b40d7b9ba8efd2e49f6528b7cc6364bea382dcee4b473b5413` | download-failed-28 |
| libgtk-3.so.0.2409.32 / 3.24.41-4ubuntu1.3 | `e3bf6367082e76a6e85218c0a84a5a0e29af05b1` | `0611fd19d1354a39a7cfafceffa3bdf4289d4c497c7f69ff337f86e99cf37d93` | download-failed-28 |

Preparation runtime SHA256/build-ID records match the corresponding `geometry-post-timing/root-name-evidence-{before,after}/{app,client}/mapped-library.sha256` and `mapped-build-ids.tsv` records. Both client captures contain matching libatspi and libdbus; both app captures contain those libraries plus matching GTK and the A bridge. This corroborates the requested symbol identities against the mapped runtime library records. The three stock runtime ELFs themselves were not retained as standalone binary files in this preparation artifact, so this audit does not claim an independent byte/build-ID extraction for them or a debug-to-runtime match that never succeeded.

## Limits

The evidence establishes exact accepted application/engine reuse, actual A package identity and recorded runtime loading, the narrow installation delta, recorded package test success, and an explicit symbol-download failure. It cannot turn the failed scenario into a pass or establish the Name query's causality, geometry, interaction, speech, focus or recording correctness. Those require their separate raw-evidence reviews. Any further debugger interpretation must account for the missing debug information rather than describing this preparation as symbolized successfully.
