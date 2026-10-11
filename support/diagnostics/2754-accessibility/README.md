# Real application geometry fixture

This external AT-SPI client captures the real LocalSend accessibility tree and compares component coordinates before and after moving its X11 window. Run it only inside the authorized cloud Mint session, after the plain UI timing case has finished. The fixture has no synthetic tree and makes no screen-reader speech, editing, or action-success claim.

## Run in Mint

Install the cloud packages `build-essential`, `pkg-config`, `libatspi2.0-dev`, `libglib2.0-dev`, `xdotool`, `jq`, and `coreutils`. The script requires libatspi 2.52.x and records the exact installed package versions and fixture hashes.

1. Stage this whole directory at `/home/mint/support/diagnostics/2754-accessibility`, next to the cloud UI driver. Retain the selected app/bridge identity and mapped-library evidence from the launcher.
2. Set `PROBE_CAPTURE_GEOMETRY=1` and `PROBE_BRIDGE_VARIANT` in the existing Mint UI invocation, preserving its `APP_EXECUTABLE`, `DISPLAY`, and D-Bus session environment. For example, inside the bootstrapped Mint guest:

   ```bash
   PROBE_CAPTURE_GEOMETRY=1 PROBE_BRIDGE_VARIANT=stock \
     python3 /home/mint/support/diagnostics/2754-ui.py
   ```

3. Let the original UI timing cases complete. The optional phase then opens a fresh **Text** dialog, waits at most 60 seconds plus one bounded screenshot/OCR attempt for rendered **Type message**, and invokes the fixture using the existing app PID and selected window ID. It preserves phase status/stdout/stderr under `/home/mint/evidence/geometry-post-timing`, then sends Escape. A failed optional capture is recorded separately from the completed causal cases.

The UI driver supplies `PROBE_CLOUD_GEOMETRY=1` only to its capture subprocess. The capture script checks that flag, Linux Mint, the `mint` user, the exact staged `/home/mint` path, and the cloud bootstrap marker before compiling or querying anything. Direct invocation from a local checkout is rejected. Its internal interface remains `capture-geometry.sh PID LABEL OUTPUT_DIR [WINDOW_ID]`. It rejects a window whose observed PID differs, compiles inside Mint, captures the tree, requests a move of 80 by 60 pixels, records the observed host position, captures again, and restores the original position through an EXIT trap.

The UI capture subprocess has a 450-second deadline and a five-second kill grace; the driver has a 465-second subprocess deadline. Give the complete cloud UI scenario at least 1500 seconds to allow both the original timing cases and this separate phase. Keep stock and A runs in separate retained cloud evidence directories. A capture process returning zero means it completed its queries; invalid A-only geometry must remain a failure in the recorded comparison rather than becoming a correction claim.

## Read the evidence

`before.jsonl` and `after.jsonl` preserve each query identity, elapsed time, result, and public `GError` details. Node records include role/name, supported component/editable-text interfaces, and focused/editable/defunct/visible/showing state. Each component gets SCREEN and WINDOW extents. Focused nodes and editable-text nodes also get inside/outside `Contains` and `GetAccessibleAtPoint` queries when their state is eligible and their extents are usable. Invalid geometry or an ineligible state records an explicit skipped-point-query reason. Public calls without a `GError` output, such as `GetStateSet` and interface discovery, cannot expose a remote error directly; retain stderr and missing-state/interface results when interpreting them. `GetStateSet` can return a nonnull DEFUNCT set after a query failure, so `state_available` alone does not indicate query success. Official Component API documentation makes meaningful extents conditional on VISIBLE and SHOWING. The comparison requires both states and excludes DEFUNCT nodes from geometry checks.

The client matches the application using public `GetProcessId`, visits at most 160 nodes to depth 14, and marks truncation. It sets the application's cache mask to NONE once on its root, then clears each visited node's public property cache before querying it. The documented setter accepts only a desktop or application root. Each public AT-SPI call emits and flushes a `query_enter` record before entering the library; returned-query records share its `call_id`. A final unmatched entry identifies the public call that did not return. The selected root also emits a snapshot of its public cached fields, explicitly labeled as cached rather than live property results.

The configured method timeout and startup grace are both 1500 ms. This bounds ordinary library D-Bus requests, rather than every part of every public call: `GetProcessId` uses libdbus's default timeout in 2.52, and method wrappers can dispatch deferred messages after receiving a reply. Each client process therefore has a 180-second outer deadline and a five-second kill grace. Timeout termination retains partial JSONL plus an explicit `process_exit` record. The move and restoration each have a 15-second deadline and two-second kill grace. Run the entire capture under the cloud session deadline as well.

Run 22 found the selected A application root in about 12 ms, then reached the outer deadline before emitting a node. The old output has no entry record for the next operation, so it cannot distinguish cache setup, GetName, internal state refresh, or deferred-message dispatch. In the exact 2.52 source, the cache setters only change fields; `GetName` tests the cache and otherwise reads `org.freedesktop.DBus.Properties.Get`. That cache test may refresh an existing state set. Property and method wrappers dispatch queued messages after their D-Bus reply. These are source-backed candidate locations, not a validated cause. `ATSPI_NO_CACHE` only prevents cached-property hits in this source; it does not suppress the asynchronous application-bus-address/GetItems exchanges. The fixture continues to use public live queries and does not substitute cached root data for role/name/state assertions. Both run-22 geometry probes remain unknown.

`host-before.json` and `host-after.json` come from `xdotool getwindowgeometry --shell`; the script parses the output without executing it. `geometry-comparison.json` retains these observed coordinates and reports, for each identical bus/path pair:

- whether usable SCREEN rectangles fit inside the observed host window;
- whether SCREEN coordinates change by the observed host move;
- whether WINDOW rectangles remain identical;
- per-coordinate query-presence flags, node eligibility, query errors, focused editable nodes, point-query identities, skipped probes, and process exit/deadline results.

All-minus-one socket/plug rectangles fail the usable-geometry checks. No observed move, missing editable field, truncated tree, timeout, error, or absent matching component must be treated as a geometry pass. Compare point-query result identities with the focused editable node identities in the same phase; null hits and unsupported methods remain unresolved. A successful tree listing alone does not establish keyboard editing, accessible actions, speech output, or a fix for issue 2754. Nested screen rectangles should be inspected alongside the captured host geometry because clipping, decorations, and popup windows can affect containment.

## API provenance

The implementation was checked against the official [at-spi2-core 2.52.0 source archive](https://download.gnome.org/sources/at-spi2-core/2.52/at-spi2-core-2.52.0.tar.xz). Archive SHA-256:

```text
0ac3fc8320c8d01fa147c272ba7fa03806389c6b03d3c406d0823e30e35ff5ab
```

`atspi-accessible.h`, `atspi-component.h`, and `atspi-misc.h` declare the public calls. The installed public `atspi-object.h` and `atspi-application.h` expose `AtspiObject.app`, `AtspiObject.path`, and `AtspiApplication.bus_name`; those declarations provide bus/path identities. The fixture calls no underscore-prefixed private function and guesses no library structure layout. Interface and accessible objects follow the transfer-full ownership documented in `atspi-accessible.c` and `atspi-component.c`. Timeout behavior follows the documented `atspi_set_timeout` in `atspi-misc.c`.

Source-file SHA-256 values from that archive:

```text
8727b5c3c94ff006b781d7874ca2d695625295b435b41ea68d0306bb2aa131a0  atspi/atspi-accessible.h
f05719eb141aba1bf65355aac63af3e2ca4777ca023fdd5d7656f557da0a2d48  atspi/atspi-object.h
7b67b2b027c0bb8dd3095d6a8c0759b1c843e6fdeba43c09ff88612dbccd3fb9  atspi/atspi-application.h
8b081abe5c9b31b732cc6166cc016ed28f727ec846df79a96a4d391238a99bd5  atspi/atspi-component.h
2a821f3fde44a7a8993a2b404628f6b2bd3fc24ffa306c6e4b720fbab898bb75  atspi/atspi-misc.h
a434a7b3b4e685983455a56f557fab91eeea344f99e670b700f280655e475bfc  atspi/atspi-accessible.c
7ead0f13fc4003d455ef36634c2ebd83ee7863f89d8fa54257339efee6c33cb2  atspi/atspi-component.c
f3950265e70f62de3b3b072f52547312b2e4fd770ace3533e7cc88e6b8fdaac1  atspi/atspi-misc.c
83544be413687b8f1f9f1b5d0b7bf0aec9fb84c79548265364937b40a704d58c  atspi/atspi-stateset.c
ae12995f42fc6c65dfa22b4345409c78745fdb8b9db6ff2b9a7f23371c046fbe  dbind/dbind.c
```

Cloud compilation and real-application execution remain required. No local build, app run, or reproduction was performed while preparing these files.
