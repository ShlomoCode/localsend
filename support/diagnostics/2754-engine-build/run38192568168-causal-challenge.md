# Run38192568168: causal challenge and one separating experiment

The retained evidence establishes a recursive dispatch stall in the geometry observer's libatspi client. It does not establish that this stall causes the reported keyboard-enabled Text freeze in LocalSend. The strongest rival is a cache-ingestion reentry path triggered by the diagnostic client's uncached policy and reply ordering, while the application continues to render and accept input.

This assessment reads retained source, raw records, and the two independent run audits. No network access, source changes, builds, scripts, tests, inferiors, applications, or workloads were executed. The LocalSend lifecycle, bug-reproduction and UI-evidence references, and NBJ writing guidance were read. Stack/packet qualification is accepted within the limits stated in the independent reports, then challenged here for causal reach.

## What the sequence proves

Read /tmp/2754-run38192568168-gdb-name-audit.md and /tmp/2754-run38192568168-wire-birth-audit.md. The before client sends root Properties.Get(Name) serial2 on FD26 and receives1312 bytes that contain GetItems reply1 followed by a complete matching Name reply2. It then sends Accessible.GetState serial3 for accessible/3 on that socket and waits in a futex. The after client repeats this sequence on FD16. Thus the root Name response has reached client userspace; a silent server Name handler cannot explain this observed wait.

The stopped before/client gdb.txt shows inner dbus_connection_dispatch acquiring connection0x5deb85f07cd0 while the outer dispatcher of that same connection is completing the GetItems callback. The corresponding after address is0x5fb3dbf36f20. The callback calls add_accessible_from_iter, atspi_state_set_contains, refresh_states and synchronous GetState. Outer Name pending2 and nested GetState pending3 remain incomplete. The separate dispatcher ownership is held until the callback returns, but the callback waits for the inner acquisition. The same-connection call chain establishes the client stall independently of the collector's missing connection-to-FD join.

The finite wire trace cannot prove that GetState3 had no reply at the server/kernel. Its public timeout check occurs after read_write_dispatch returns, while the nested dispatcher condition wait has no timeout argument. Therefore an intended per-call timeout does not break this particular wait. The external180s process deadline still bounds the diagnostic and still fails. No extra symbols or FD repair is needed to choose a separating intervention.

## Strongest rival and source trigger

geometry-client.c212-213 sets ATSPI_CACHE_NONE on the app root and clears the cache before Name. This is supported libatspi consumer behavior, but it is deliberate diagnostic policy, not established as the keyboard application's policy.

Retained AT-SPI2.52 source supplies this path:

- atspi-misc.c398 registers handle_get_items through dbus_pending_call_set_notify; GetItems startup is not suppressed by the diagnostic cache policy.
- add_accessible_from_iter at683 calls _atspi_dbus_set_state with states already present in the GetItems payload.
- _atspi_dbus_set_state at1655-1678 installs that payload bitmap and asks to mark ATSPI_CACHE_STATES. _atspi_accessible_add_cache at1882 onward intersects that flag with the effective cache mask. CACHE_NONE prevents the flag from becoming valid.
- add_accessible_from_iter at688 then calls atspi_state_set_contains for MANAGES_DESCENDANTS. That public method calls refresh_states even though cache ingestion has just supplied state bits. refresh_states at122-130 performs synchronous GetState when the state-cache flag is absent.
- libdbus dbus-connection.c2333-2345 invokes the pending callback after releasing the main connection lock, while its dispatch ownership remains held. That ownership is separate from the recursive mutex. Replacing mutex behavior alone would not discharge the demonstrated dispatcher dependency.

This gives the rival a concrete trigger: cache hydration under CACHE_NONE calls a network-refreshing getter inside a pending-reply callback. Scheduling determines whether GetItems completes inside the Name dispatcher. Birth strace can alter that ordering, but it is not a sufficient standalone explanation: run38184349418 enters public Name before any tracer attaches, remains unresolved for the initial three seconds, and later retains a nested client wait. Repeated untraced public deadline failures also show that birth tracing is unnecessary for the observed public failure. They do not recover the exact initial untraced message order or establish the reporter's consumer state.

The same source defect can affect normal assistive clients if they enter this callback with uncached states. That possibility does not identify which process froze in the report. The mechanism is in a shared client library; attaching its diagnosis to Flutter's server-side root/socket geometry would cross the process boundary without evidence.

## Application evidence has a different boundary

In run38192568168, events.json places keyboard-on-stack-65 at t571.74691594 and geometry-phase-start later at t575.120948022. I viewed keyboard-on-stack-0.png and keyboard-on-stack-65.png. Both show the rendered Text dialog and the marker typed into its field; the earlier keyboard-off-0.png also shows a typed marker. These observations establish rendering and prior text input in those phases. A static modal held open for65s does not establish a65s application freeze, and these images do not test continued input during the later geometry stall.

keyboard-on-stack-gdb.txt records the application's main thread in GLib poll rather than the client recursive-dispatch chain. The independent Name app snapshots likewise show poll and no held Name handler. Poll alone is not a universal responsiveness test, but it supplies no positive app-side causal chain matching the diagnostic client stall. The later geometry modal-rendered event shows that Text was reached before the observer started. These are the existing A+B diagnostic artifact's behavior, not proof that the original reported release is fixed.

## Supported shared-source intervention

Propose one change in libatspi's GetItems completion handling: steal/retain the completed reply through the official DBusPendingCall/DBusMessage ownership APIs, enqueue it for the library's existing deferred-message processing, and return from the pending callback before parsing cache items. Parse the retained reply after the outer dbus_connection_dispatch has returned and released dispatch ownership. The snapshot still hydrates the cache; later refresh calls retain their live-query behavior.

The responsible layer already has BusDataClosure, a GQueue, GSource scheduling, queue cleanup and a reentry guard at atspi-misc.c900-1003. It defers AddAccessible and other events through this path. Use that mechanism with an explicit GetItems completion item, preserving message/connection/application lifetimes and FIFO ordering relative to queued cache updates. Its synchronous wrappers already call process_deferred_messages after D-Bus operations return. Avoid a new Linux-specific callback service, socket workaround or alternate Name implementation. Review that queued work cannot run from a recursively entered GLib context while the same dispatch is held; an idle callback alone does not prove that condition.

The demonstrated safe drain point is explicit: _atspi_dbus_get_property at1394 calls dbind_send_and_allow_reentry and drains process_deferred_messages at1398 only after it returns. dbind's closure loop calls read_write_dispatch, returns from those dispatch calls, observes its reply and returns at dbind.c120-123. libdbus releases dispatcher ownership at dbus-connection.c4873 before its dispatch invocation returns. Therefore parsing a retained GetItems completion at this post-dbind point avoids the held outer dispatcher in the demonstrated Name path. The similar post-dbind drain in _atspi_dbus_call at1283 is also available. This source sequence supports a specific callback-to-post-dispatch move; it does not prove every recursive main-context path is safe.

Ownership must remain explicit: dbus_pending_call_steal_reply transfers the reply reference to the completion code. Move that owned reference into the queue (or take one queue reference and release the stolen reference); retain the actual app-specific DBusConnection with dbus_connection_ref and the AtspiApplication with its GObject reference. Release the pending reference once after enqueue, then release message/connection/application when consumed, cancelled or shut down. Existing destroy_deferred_message_item already unrefs its message and connection, but lacks the application field needed by this proposed completion item. Existing defer_message stores the file-global bus instead of its connection argument; do not blindly reuse that detail to bind an app-specific completion. Maintain the original error-reply, application-disposal and malformed-payload handling.

Before implementation acceptance, the exact source diff must make this completion eligible only for a drain proven outside same-connection dispatch; an unguarded g_idle_source_new callback does not meet that gate. Preserve existing queue ordering and establish how the default idle drain and nested wrappers avoid consuming it prematurely. This narrow eligibility/lifetime design remains a source-review gate, not a reason to run another environment. No public libdbus API inspected here permits simply declaring its current dispatch ownership released inside a pending callback.

The supported API alternatives were assessed from retained source:

| Alternative | Why it is not the separating intervention |
| --- | --- |
| Enable state caching through atspi_accessible_set_cache_mask | Supported and likely avoids this trigger, but changes the diagnostic's intended uncached policy. A pass would confound policy with dispatcher sequencing. |
| Construct an independent state snapshot with atspi_state_set_new / add, then contains | Public snapshot construction avoids refresh when no accessible is attached. It could make cache ingestion pure, but changes the nested request out of the experiment. Defer-first preserves that request and tests dispatcher ownership directly. |
| Make GetState asynchronous using dbus_connection_send_with_reply / set_notify | Official and maintained; suitable for a larger asynchronous redesign. It changes the synchronous API/continuation contract beyond the smallest tested callback boundary. |
| Replace the libatspi client with raw GDBus or another transport | GIO is present and maintained, but substitution removes the tested bootstrap/cache machinery. It can inspect the server, not demonstrate correction of the existing public client's dispatch path. No source/API qualification of a wholesale migration was performed. |
| Release libdbus dispatch ownership before every callback | Broad shared dispatcher change affects all pending callbacks and ordering. libatspi can avoid its own synchronous reentry through its existing queue without changing libdbus's global contract. |

No retained maintained-release source establishes an already-shipped correction. This assessment does not assume an upgrade fixes it. The proposed library-source change needs its own diff and review; no patch has been written here.

## One separating experiment

Perform one paired control/intervention experiment, if separately authorized. Keep the app, engine, bridge, keyboard service, desktop, profile, input actions, diagnostic executable, cache policy, tracing schedule and180s external deadline identical. Use the exact qualified libatspi source/build in both client arms, changing only the GetItems completion deferral above. Apply the source change to the library used by the geometry client through the normal source build/link/install path, not an injected runtime hook. Keep the app and keyboard processes on their unchanged libraries; verify mapped identities in each process. This client-only boundary isolates the observer mechanism.

Specifically preserve ATSPI_CACHE_NONE and ClearCacheSingle calls and their timing. Keep Name and later live GetState calls; the intended difference is their dispatch context, not their removal. The raw serial numbers can change if ordering changes, so match semantic identity and replies on the same connection rather than requiring literal1/2/3 in the intervention arm.

In each arm, first open Text with the real keyboard setting and verify a typed marker before launching the observer. While the observer is unresolved, send a fresh native input marker and a real dialog Cancel/close action at the same planned times, and retain images/events proving the resulting UI transition. Use an equivalent fresh process/profile for the other arm so earlier GetItems state or a stranded diagnostic client does not prime it. Retain the raw Name2/GetItems1/GetState3 sequence and the public wrapper outcome. The key intervention prediction is that the callback queues GetItems and releases the outer dispatcher, allowing the already-delivered Name reply to complete; any state refresh then occurs outside that dispatcher ownership. Do not bypass Name, remove GetState, alter cache masks, extend deadlines or treat a later geometry failure as a root-query pass.

| Paired observation | Causal conclusion |
| --- | --- |
| Client stall disappears only with deferral, while Text accepts new input/cancels in both arms | Shared libatspi callback sequencing caused the observer stall in this cohort. The reported app freeze remains unestablished. |
| Client stall disappears, but Text still fails the same independently verified input transition | The observer defect and application failure are separate under these conditions; this client fix does not resolve the UI failure. |
| Control Text is responsive before observer, fails only during stalled observer, intervention removes both failures | Evidence of observer-mediated disturbance in this cohort. Because only the diagnostic client changed, still not proof that the reporter's ordinary keyboard workflow invokes the same path. |
| Text fails before any observer and the changed client only fixes its own Name outcome | Strong separation from the reporter/UI failure; diagnose the unchanged failing UI process's own causal path. |
| Deferral does not release Name or an unqueued recursive wait remains | The intervention fails its prediction. Examine the retained new shared-library path; do not claim a dispatcher fix. |

To attribute the reporter's Text freeze, the qualifying UI failure must also occur in a legitimate reported workflow without the geometry observer, and the responsible keyboard/assistive client must show this cache-refresh dependency or respond to the same shared-source correction through its normal build/configuration. The proposed pair deliberately avoids changing that client, so it cannot by itself meet that product-fix gate. The existing record already supports a focused observer defect; it supports no automatic production workaround or PR for LocalSend's Text page.
