# Mutter geometry and AT-SPI diagnostics

This directory prepares guest-only diagnostics for Debian 13 / GNOME Shell 48.7. No app, build, test, or reproduction was run locally. The extension uses public Mutter APIs through the GNOME Shell extension surface and adds a read-only DBus snapshot method. It does not intercept toolkit calls or change geometry. Its runtime compatibility and coordinate agreement still require verification in the guest before it can support a reproduction claim.

## Install and capture in the GNOME guest

Install `extension.js` and `metadata.json` in `~/.local/share/gnome-shell/extensions/localsend-geometry-oracle@diagnostics.invalid/` before starting the GNOME session. Enable the extension with `gnome-extensions enable localsend-geometry-oracle@diagnostics.invalid` in that same user's session. A running Wayland Shell may require a new session to discover a newly installed extension. Keep Shell logs and `gnome-extensions info` output if enablement fails.

Alternatively, run `sh install-guest.sh` as the guest desktop user before the caller restarts GDM. It uses `Gio.Settings` to append the UUID while preserving existing enabled extensions and prints the previous settings. It enables user extensions for this diagnostic session. After the restart, obtain the new GNOME session environment and run `sh wait-ready-guest.sh`. This makes at most six bounded DBus attempts. Any final nonzero exit must block geometry-dependent claims. After launching the actual app, run `/usr/bin/python3 snapshot-guest.py --pid HOST_APP_PID --backend wayland` as an additional strict identity/API gate. Use `--backend x11` for the verified Xwayland control. Multiple target-PID windows require explicit selection and a revised gate; never select one silently.

Call the exported interface on GNOME Shell's existing session-bus name:

```sh
gdbus call --session --dest org.gnome.Shell \
  --object-path /org/localsend/Diagnostics/Geometry \
  --method org.localsend.Diagnostics.Geometry.Snapshot
```

The DBus output is a tuple containing a JSON string. Decode the tuple/string using a DBus client; preserve the raw output too. A missing interface is a diagnostic setup failure. Each optional observation has `value` and `error`; never replace errors with default rectangles or coordinates.

Take repeated snapshots while the window is settled, before and after each real interaction. Match `stableSequence` and verified process identity across snapshots. Retain desktop/session versions, display configuration and scale, Shell logs, app stdout, app host PID, `/proc/PID/status` including `NSpid`, `/proc/PID/cmdline`, `/proc/PID/exe`, process start time, and the Flatpak instance identity. Use session-bus credentials from this GNOME session, not an unrelated shell's private bus.

## Coordinates and limits

| Field | Exact meaning from Mutter 48.7 |
| --- | --- |
| `frameStage` | Visible window frame, excluding client shadows and extra reactive areas. Coordinates are Mutter stage coordinates. |
| `bufferStage` | Rectangle occupied by the attached Wayland buffer, or server-side X11 toplevel geometry. It can include GTK client decorations and shadows. It is not a Flutter content rectangle. |
| `atspiWindowOriginStage` | The public `get_client_content_rect()` API explicitly defines this as the client rectangle that AT-SPI window coordinates are relative to. For native Wayland 48.7 its implementation returns the frame rectangle. |
| `*Protocol` | Corresponding public `stage_to_protocol_rect()` result. For native Wayland 48.7 this transform is identity. Preserve both forms rather than assuming screenshot or buffer pixel units. |

Mutter's private `get_client_area_rect()` is not exported in `src/meta/window.h`; the extension does not call it. That private API also covers the buffer for native Wayland, so it would not locate the GTK/Flutter child anyway. GTK decoration height, Flutter view origin, and Flutter logical/device pixel ratio cannot be inferred by subtracting a guessed title bar or multiplying by a guessed scale. Those values need real accessible child geometry or separate supported toolkit observations.

The extension's attached-buffer and frame rectangles are compositor observations independent of AT-SPI. Their correctness on the tested session must be checked against a working control and the real rendered window. An AT-SPI Screen rectangle is a toolkit-reported observation, not an independent compositor truth. Preserve Screen and Window observations separately. GNOME Shell's actual magnifier uses Window coordinates with the compositor origin and its own observed theme scale, as traced below. A missing or unsupported native Wayland Screen position does not by itself invalidate that path. Do not use screenshot dimensions as an unverified conversion factor. A mismatch is evidence of disagreement, not permission to invent an offset.

Window actors enumerate compositor-managed actors, including actors that may be invisible or minimized. Missing windows, unavailable APIs, and nonpositive PIDs must remain errors or unresolved identity; they cannot be repaired with title-only matching. Geometry may change while a snapshot is read. The JSON includes the snapshot's monotonic interval; require stable repeated observations for settled-state assertions.

## GNOME Shell 48.7 magnifier's actual coordinate path

[Magnifier source at the immutable Shell commit](https://github.com/GNOME/gnome-shell/blob/e3017af71ac39f618bcf9f0e04f794c90bde3c83/js/ui/magnifier.js#L866) establishes the consumer behavior:

1. `_updateFocus()` obtains Component extents using `Atspi.CoordType.WINDOW` at line 929. It does not request `SCREEN`. `_updateCaret()` obtains the caret character extents using `WINDOW` at lines 955–956.
2. `_convertExtentsToScreenSpace()` walks ancestry to an application and frame/dialog/window (lines 867–888). GNOME Shell's own accessible events bypass conversion because Clutter already scaled them (lines 890–894).
3. Other applications must have an `ACTIVE` parent window and a `FOCUSED` source accessible (lines 896–902). Without either state, conversion returns null. It then requires a compositor focus window (`global.display.focusWindow`, lines 907–909).
4. The compositor focus window supplies `get_client_content_rect()` (line 911). Shell's `St.ThemeContext.get_for_stage(global.stage).scale_factor` supplies the scale (line 912). It computes stage-space geometry at lines 913–918 as:

   ```text
   stageX = contentRect.x + shellThemeScaleFactor * windowX
   stageY = contentRect.y + shellThemeScaleFactor * windowY
   stageWidth = shellThemeScaleFactor * windowWidth
   stageHeight = shellThemeScaleFactor * windowHeight
   ```

5. Focus tracking uses the resulting rectangle's center (lines 938–945). Caret tracking uses its upper-left point (lines 965–975) and ignores a 0×0 caret rectangle. Errors are logged and skipped (lines 933–935 and 960–962).

The oracle now reports `shellThemeScaleFactor` through the same API and `compositorFocused` for each window. These are observed Shell values, not a guessed GTK device-pixel ratio. Require successful scale observation and a PID-verified focused window before applying the formula. `snapshot-guest.py --pid HOST_APP_PID --backend wayland --require-focused` enforces these compositor prerequisites; the semantic ACTIVE/FOCUSED ancestry checks remain separate. The `stage_to_protocol_rect()` transform is a separate API; it does not replace this magnifier scaling step.

For native Wayland, Mutter 48.7's `get_client_content_rect()` returns its frame rectangle (`window.c`, lines 8333–8339). This defines the compositor window origin independently of GTK's ability to report global coordinates. WINDOW extents plus the observed origin/scale reproduce Shell's target calculation; they do not independently prove the child extents are correct. Compare that calculated target with the actual focused rendered control and repeat after changing focus or editing text. Preserve positive control behavior, focus state, ancestry, event timing, compositor snapshots and video. No inferred title-bar subtraction is needed or justified.

Keep native Wayland Screen-coordinate limitations separate from a defect in Window coordinates. Invalid/sentinel rectangles, all-identical child extents, nonpositive sizes for visible controls, unsupported-interface errors and missing focused ancestry must remain explicit. Never treat suppressed warnings or numeric output alone as proof of correct geometry. A flat 1×1 rectangle set requires investigation against the real control and the exposed semantic data. Zero-sized carets can be legitimately skipped by this consumer; establish whether the edited, focused field emits meaningful caret geometry before claiming tracking works.

[Focus/caret tracker source](https://github.com/GNOME/gnome-shell/blob/e3017af71ac39f618bcf9f0e04f794c90bde3c83/js/ui/focusCaretTracker.js#L50) initializes AT-SPI, sets timeouts to 250/250 and subscribes to focused/selected state changes and text-caret movement. Its timeout and event handling are consumer behavior, not proof that the app responds.

`atspi-events.py` is a proposed guest-only recorder for independent review before runtime acceptance. It subscribes to those real event types and uses `Atspi.set_timeout(250, 250)` for source requests. The repaired collector flushes an `observation-start` receipt before any accessible query. Each query flushes `call-start`, followed by `call-end` with start/end monotonic timestamps, duration and errors. A stalled query therefore leaves a preceding progress record.

Each `call-end` also retains the returned value when it is already a JSON-compatible primitive or container, including actual rectangle dictionaries. This happens before budget rejection, so a successful WINDOW query whose duration exceeds the cumulative budget remains raw evidence in its call record. Nonserializable returned public interfaces/StateSets receive an explicit representation marker and Python type name; serialization inspects no private proxy fields and performs no extra remote queries. A StateSet returned after the budget expires therefore remains an interface marker, not inferred state flags. Source/application/ancestor records are allocated before their metadata queries and filled incrementally, preserving earlier states/names if a later call fails or reaches a cap. Partial records and successful raw values never override the inconclusive interpretation.

The query order follows the consumer first: Component WINDOW geometry for state events, or Text current caret offset and its WINDOW character rectangle for caret events. Event-offset WINDOW geometry follows the consumer query. Source identity, application identity and capped ancestry follow. SCREEN geometry is optional, disabled by default, and queried last with `--include-screen`. Each node's StateSet is fetched once and reused to record ACTIVE/FOCUSED/VISIBLE/SHOWING flags. The last FRAME/DIALOG/WINDOW ancestor encountered before APPLICATION supplies the recorded Shell state prerequisite; truncated ancestry cannot establish that ancestor.

`consumerEventEligibility` separately records the consumer's event gate. Shell `_updateFocus()` requires `detail1 == 1` at magnifier line 925 for both subscribed focused and selected events. Removal events remain raw observations but receive an explicit ineligible reason and cannot yield `queryStatus: completed`. Caret events pass the event-type gate only; valid Text geometry, state ancestry, identity and correlation remain separate prerequisites. A later ACTIVE/FOCUSED state observation never overrides an ineligible focus-removal event.

Default limits are 1000 ms cumulative callback time, 32 query calls and four ancestry nodes. The options permit at most 2000 ms, 48 calls and eight nodes. Before each call, the collector checks the cumulative budget/call cap. It also checks after each call; crossing the budget aborts subsequent queries and rejects that event's geometry interpretation. This is a cooperative work budget, not an interruptible hard deadline: a single running request can exceed the remaining budget, and the 250 ms AT-SPI timeout or ultimate external process timeout must bound that request. No promise of exact maximum callback latency is made. The output marks slow, failed, incomplete or unresolved observations inconclusive.

The collector records source/application names, roles, reported PIDs and ancestry as diagnostic observations. No supported public API for durable accessible bus/object identity has been verified here; `accessibleBusObjectIdentity` explicitly reports unavailable. It does not infer identity from private proxy fields, memory addresses, names, shared namespace PIDs or ancestry indices. `queryStatus: completed` means the bounded observations completed, not that identity or geometry is proven. `interpretationStatus` remains inconclusive until independent identity, event-time compositor and rendered-control evidence resolve the limits. `--name` marks matching application names rather than dropping events, so the other-window rejection control retains B's raw events.

The collector reports API errors without replacing values or suppressing warnings. A query at an end-of-text offset can fail or produce zero-sized extents; retain that outcome rather than substituting another character. Component/Text API documentation makes extents meaningful only for VISIBLE and SHOWING objects; retain those states alongside the rectangle.

Run it in the guest with an external bound while separately performing and recording the actual gestures:

```sh
timeout --signal=TERM --kill-after=3s 30s /usr/bin/python3 atspi-events.py \
  --name EXACT_ACCESSIBLE_APP_NAME > events.jsonl 2> events.stderr
```

Retain the timeout exit status, streams, `start`/`configured`/`end` records and any partial observation records. Missing `configured` or `end`, callback errors, absent matching events and source timeouts are collector/semantic evidence limits. They do not establish a stock app freeze. Python callback receipt time is an observation timestamp, not event emission or original gesture time; no emission timestamp is supplied by this collector. Current caret lookup occurs after receipt and can describe changed state. Slow events must not be paired with later settled compositor observations as if they described one instant. Correlate with retained input timing, actual field rendering, audio/video and bracketing compositor snapshots. Compare actual Zoom/input responsiveness with the collector stopped and running before attributing latency or a stall. The observer sends no input, invokes no semantic actions and modifies no text.

The source repair addresses the independent review's ordering, progress, repeated-state and unbounded-work objections. It does not close runtime compatibility, durable object identity, event-time correlation, actual Zoom response or observer-perturbation gates. No local or cloud execution validated this revision, and the parent must obtain renewed independent review before runtime acceptance.

## Backend and PID identity

`get_client_type()` identifies each window as Wayland or X11. `Meta.is_wayland_compositor()` records the compositor session. An X11 window in a Wayland compositor is Xwayland. A Wayland session alone does not establish that LocalSend uses native Wayland.

Mutter 48.7's native implementation obtains `get_pid()` through `wl_client_get_credentials()`. Its X11 implementation requests XRes `LOCAL_CLIENT_PID` for the actual window's XID. Neither implementation selects `_NET_WM_PID` as its identity source. Retained source references are below. Verify the returned PID against the guest host's app process, including start time, executable, cmdline, and Flatpak instance. If the Flatpak connection is brokered, do not assume the credential PID identifies Flutter; record and resolve the broker relation first.

Flatpak's `_NET_WM_PID` and AT-SPI PID can be namespace-relative, such as PID 2. Record these separately and map using the exact host process's `NSpid` chain and instance identity. Namespace PID 2, a shared app ID, or a title alone is insufficient to distinguish instances. Xlib geometry is admissible only after an X11 window is tied to the intended app via XRes/credential identity and the namespace mapping. For native Wayland windows, Xlib observations of unrelated Xwayland windows are not app geometry.

## Semantic AT-SPI capture in the guest

Install the guest's `python3-pyatspi` package. Run the snapshot with an external timeout and preserve exit status and both streams:

```sh
timeout 25s /usr/bin/python3 atspi-snapshot.py --name EXACT_ACCESSIBLE_APP_NAME
```

It prints application names/PIDs, ancestry index paths, roles, interfaces, states, Component extents/positions in Screen and Window coordinates, Component size, actions, and bounded text. The `--pid` option matches the AT-SPI-reported PID exactly; map its namespace before using it. Per-node progress and error records remain in the output if a later call stalls. Node/depth limits are reported as truncation. Missing interfaces, zero matches, incomplete traversals, and timeout exit 124 do not establish an app freeze. Check the real application's independent input response, compositor observations, logs, and a working accessible control to distinguish a toolkit failure from an AT-SPI or harness stall.

To invoke an exposed semantic action, use `--action-path '[DESKTOP_APP_INDEX,...]' --action-index N`. To invoke an exposed edit, use `--edit-path '[DESKTOP_APP_INDEX,...]' --text VALUE`. Use fresh paths from the same live application; ancestry indices can change after UI transitions. The consumer preserves action/edit return values and a later application snapshot. Confirm the actual text/state/rendered effect; a boolean success or calling an action is not proof that the expected workflow occurred. These optional semantic calls differ from pointer/keyboard interaction and must be labeled if the reported scenario requires those physical inputs.

## Retained source references

Mutter tag `48.7` resolves to commit `f4abb824fe7c5026a109f3c5432ae2434a994f19`. GNOME Shell tag `48.7` resolves to `e3017af71ac39f618bcf9f0e04f794c90bde3c83`.

- [Public window API declarations](https://github.com/GNOME/mutter/blob/f4abb824fe7c5026a109f3c5432ae2434a994f19/src/meta/window.h): exported frame, buffer, content and coordinate-transform APIs.
- [Geometry API documentation and implementations](https://github.com/GNOME/mutter/blob/f4abb824fe7c5026a109f3c5432ae2434a994f19/src/core/window.c#L4480): buffer/frame conventions at lines 4480–4637; AT-SPI content convention at lines 8321–8339; stage/protocol transform at lines 8221–8242.
- [Native Wayland implementation](https://github.com/GNOME/mutter/blob/f4abb824fe7c5026a109f3c5432ae2434a994f19/src/wayland/meta-window-wayland.c#L681): PID credentials at lines 681–696, identity transform at 847–857, buffer/frame offset handling around 1234–1246. The geometry-scale comments describe stage representation; do not treat them as a GTK widget-coordinate conversion.
- [X11 identity implementation](https://github.com/GNOME/mutter/blob/f4abb824fe7c5026a109f3c5432ae2434a994f19/src/x11/window-x11.c#L1859): XRes `LOCAL_CLIENT_PID` query.
- [GNOME Shell extension base](https://github.com/GNOME/gnome-shell/blob/e3017af71ac39f618bcf9f0e04f794c90bde3c83/js/extensions/extension.js) and [Shell's DBus export usage](https://github.com/GNOME/gnome-shell/blob/e3017af71ac39f618bcf9f0e04f794c90bde3c83/js/ui/shellDBus.js#L22).
- [pyatspi source](https://github.com/GNOME/pyatspi2/tree/a0df428cfe6713be5769e1a3d3ca9942b6b4645d/pyatspi): retained Component, Accessible interface adapters, Action and EditableText sources. This source API reference is not a claim about the guest's exact installed package version; retain package versions and inspect runtime errors.

Exact upstream source bytes are retained outside the diagnostic branch at `/Users/shlomo/.codex/worktrees/1f58/localsend/.a5c/localsend-sprint/issue3161-recovery/geometry-source-reference/sources/`. The adjacent `SHA256SUMS` records SHA-256 digests with paths relative to `geometry-source-reference/`. The preparation directory's `/sources/` copy is ignored by Git; the reference URLs above remain accessible from the uploaded diagnostic branch. These sources support the implementation and coordinate conventions, not a completed runtime validation. Verify the installed Debian Mutter package version and distribution patches before claiming that it matches these upstream sources.
