# Folder opener and native chooser alternatives

The original timing cohort should retain its existing UI input method and keep all libatspi enumeration after the original timing measurements. A scoped native-chooser query does not make libatspi discovery cache-neutral. X11 window properties can strengthen chooser ownership checks without requesting a Flutter accessibility hierarchy, but cannot identify the Flutter Folder button by its text.

## Exact retained source evidence

The retained AT-SPI source below is version 2.52.0:

- `/tmp/2754-packaged-full/package/build/work/at-spi2-core-2.52.0/atspi/atspi-misc.c:425`: `get_application` sends `Application.GetApplicationBusAddress` when creating an application proxy.
- The same file at line 392: its bus-address reply handler sends `Cache.GetItems` to `/org/a11y/atspi/cache`. This request has no cache-mask conditional in the inspected handler. Setting `ATSPI_CACHE_NONE` can prevent use of cached properties; it does not prevent this bootstrap request.
- The same file at lines 756 and 783: desktop discovery calls the registry's `Accessible.GetChildren` and passes each returned application reference to `add_app_to_desktop`. Application discovery therefore cannot be treated as merely selecting a PID before touching other application state.
- `/tmp/2754-packaged-full/package/build/work/at-spi2-core-2.52.0/atspi/atspi-accessible.c:1808`: `atspi_accessible_get_process_id` calls the bus daemon's `GetConnectionUnixProcessID`. That call itself does not traverse a tree, but obtaining its accessible through libatspi has the proxy-bootstrap behavior above.
- The same file at lines 884–895: `atspi_accessible_get_toolkit_name` reads the application-level `ToolkitName` property. `/tmp/2754-packaged-full/package/build/work/at-spi2-core-2.52.0/xml/Application.xml:12` declares that property. It is not a discriminator between the Flutter view and a native GTK chooser in the same GTK process.
- A static search of the retained source's `atspi/` and `xml/` directories found no public XID/window-ID mapping API. Do not assume a toolkit-specific accessible attribute maps a node to an X11 window without separate source evidence.
- `/tmp/2754-folder-source-audit/source/linux/file_selector_plugin.cc:60`: the pinned plugin creates a `GtkFileChooserNative` with the app window as parent. Its directory branch at lines 114–116 chooses `GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER`, title `Choose Directory`, and default accept label `_Open`; line 61 supplies `_Cancel`. `/tmp/2754-folder-source-audit/AUDIT.md` records the immutable app revision, lockfile, package version, and matching archive checksum. These are source expectations, not a runtime chooser pass.

## Bounded recommendation

Keep the original pre-timing Folder click driven by the rendered UI. Require its existing unique visible app PID/XID and screenshot/layout guards. X11 hierarchy describes windows, not Flutter's semantic widget hierarchy; it cannot replace OCR with a text-based Folder lookup.

After the click, strengthen the native chooser guard using a unique visible top-level window with the actual owner PID and exact observed `Choose Directory` title. Retain raw X11 properties, including `WM_TRANSIENT_FOR`, window type, modal state where exposed, class, geometry, and title. A transient relationship to the original LocalSend XID is stronger ownership evidence than a title alone. Fail rather than silently broaden the gate if the expected relationship or PID cannot be established. Retain screenshots and the cancellation/return transition as independent rendered evidence. A portal process requires separate identity evidence; the pinned source does not prove that runtime uses the in-process fallback.

If additional accessible chooser evidence is needed, query it only after all original timing observations, or use a separate diagnostic cohort whose observer effect is explicit. Bound traversal to the selected application's top-level children and the uniquely matched chooser subtree, and retain raw calls/results/errors. This reduces deliberate Flutter-subtree querying but does not eliminate libatspi's application-wide bootstrap cache request. No such query should be labeled causally neutral.

Raw GDBus can avoid libatspi's automatic proxy/cache mechanism. A registry `GetChildren` request and bus-daemon PID mapping do not themselves request the Flutter subtree. They also do not identify the Folder opener. Calling actual application `GetChildren`, `Properties.Get`, or other accessible methods executes bridge code and can alter its work and cache timing. Starting or subscribing to accessibility services may also change the observed environment. This is an explicit observer cohort, not a safe shortcut for the original timing control.

## Limits

This assessment used static source reads only. No files in the clone were changed. No app, test, compilation, reproduction, VM, or workflow was launched. It establishes why the proposed discovery cannot be assumed cache-neutral and identifies bounded follow-up evidence; it does not establish runtime chooser properties, cancellation success, or the cause of the reported bug.
