# AT-SPI source audit of the unmatched root name query

Scope: read-only analysis of retained run `38177219980`, official AT-SPI `2.52.0-1build1` source plus patch A. No builds, tests, application launches, cloud dispatches, or deadline changes were performed. This audit does not inspect Flutter's root-name implementation.

## Observation and limits

Both `comparison/AB-package/guest/geometry-post-timing/before.jsonl` and `after.jsonl` end with unmatched public wrapper call 50, labelled `GetName`, for `:1.29` `/org/a11y/atspi/accessible/root`. The preceding snapshot has `cached_name:""`, `cached_role:0`, `cached_properties:0`. Calls 48 (`SetCacheMaskNone`) and 49 (`ClearCacheSingle`) return. Public call 50 enters at approximately 13 ms in each client invocation; neither has a corresponding return record before process exit status 124. No extent node is reached. These records identify the stalled public API call, not an observed wire method or a proved server-side name callback hang.

Call 47 (`GetProcessId`) returns 4618, but AT-SPI implements that public API with `org.freedesktop.DBus.GetConnectionUnixProcessID` on the broker (`atspi/atspi-accessible.c:1810–1843`). It does not invoke the application's root adaptor. Its success establishes bus-name ownership/PID availability, not a working application dispatch context. Likewise, a returned desktop-child reference can be constructed locally from the registry reply.

The parent reports that the normal package's mapped bridge, native tests, target-only package delta, and Text progression passed. This audit does not independently revalidate those separate results. They do not locate the later root-name wait.

## Public API to adaptor route

Source root: `/tmp/2754-packaged-38177219980-full/package/build/work/at-spi2-core-2.52.0/`.

1. `atspi/atspi-accessible.c:342` implements `atspi_accessible_get_name`. With name caching disabled, it calls `_atspi_dbus_get_property(obj, Accessible, "Name", ..., "s", ...)`. `GetName` is the harness label; the intended wire call is `org.freedesktop.DBus.Properties.Get` with two string arguments, `org.a11y.atspi.Accessible` and `Name`.
2. `atspi/atspi-misc.c:1368` constructs that message using `aobj->app->bus_name`, `aobj->path`, and the application's client-side connection `aobj->app->bus`. It sets the dbind timeout and calls `dbind_send_and_allow_reentry`, then runs `check_for_hang` and `process_deferred_messages` before it parses/returns the property's value.
3. On the adaptor side, `droute/droute.c:579` routes Properties calls to `handle_properties`; `impl_prop_GetSet` at line 313 looks up the property and resolves the path datum. The callback executes synchronously before `handle_properties` sends its reply (line 427).
4. `atk-adaptor/accessible-register.c:254` maps the literal `root` path to `spi_global_app_data->root`. `atk-adaptor/bridge.c:1084` obtains that root through `atk_get_root()`, and line 1105 retains it. The root is supplied by the runtime's `AtkUtilClass.get_root`; this source does not establish the actual root GType in run 38177219980.
5. `atk-adaptor/adaptors/accessible-adaptor.c:37` implements the `Name` getter as `droute_return_v_string(iter, atk_object_get_name(object))`. `atk/atkobject.c:694` invokes the object's dynamic `AtkObjectClass.get_name`. The base implementation (line 1417) simply returns `object->name`. An application/toolkit subclass can override it, so identifying the concrete class and callback is necessary before assigning a toolkit cause.

The name adaptor does not itself query a parent, plug, socket, or Component geometry. The base `AtkPlug` implementation overrides child/state methods, but does not override `get_name` (`atk/atkplug.c:94`). A GTK or Flutter subtype may have other behavior; it is not proved by this AT-SPI source.

## Bootstrap and dispatch can occur inside the public name call

`atspi/atspi-misc.c:402` creates each application record and asynchronously sends `Application.GetApplicationBusAddress` on its root, with a 2000 ms pending timeout. The callback (`handle_get_bus_address`, line 347) may open a private connection and replace `app->bus`, then sends `Cache.GetItems` at `/org/a11y/atspi/cache` with a 2000 ms pending timeout. Setting the cache mask to NONE later does not cancel these previously scheduled bootstrap calls. They are not proof that the Name callback was entered.

`dbind/dbind.c:63` has two routes. For a destination different from the connection's own unique name, it first calls `dbus_connection_send_with_reply_and_block`. It then drains `dbus_connection_dispatch` while data remains when `g_main_depth()==0`, before returning the reply to the property wrapper. Pending-call callbacks, including bootstrap callbacks, can execute during that drain. The other branch explicitly dispatches until the pending reply arrives. The caller's 1500 ms API timeout does not bound arbitrary code executed in a callback or deferred-message handler.

The public wrapper also drains deferred event/cache messages (`atspi-misc.c:958`, `1398`). Consequently, a wire Name reply can exist while the public Name call remains unmatched. Conversely, a bootstrap/cache query could occupy the application's dispatch thread before Name is served.

`Cache.GetItems` (`atk-adaptor/adaptors/cache-adaptor.c:313`) iterates cached accessibles. `append_cache_item` calls several dynamic ATK methods, including state, parent, index, children, interfaces, and name (line 203). A stack in this path would identify cache enumeration rather than necessarily the root Name property callback. `Application.GetApplicationBusAddress` also registers the client and may create a private application socket (`application-adaptor.c:88`). These are candidate paths requiring wire/stack evidence.

## Exact scope of A

Patch A changes `atk-adaptor/adaptors/socket-adaptor.c` and adds native test sources. It does not change Accessible Name, cache dispatch, application bootstrap, dbind, or ATK name virtual methods.

`impl_Embedded` records the sender/path as `dbus-plug-parent`, binds a local socket, and assigns only the plug Component `get_extents`, `get_position`, and `get_size` callbacks (socket-adaptor.c:412–435). These callbacks invoke A's `local_socket_call` before the original blocking socket D-Bus geometry path. A dispatches directly to the bound socket's ATK Component method; a base `AtkSocket`'s extents method delegates to its parent Component (`atk/atksocket.c:175`). This is geometry delegation, not name delegation.

A's local eligibility is stricter than sharing a PID: the parent ID bus must equal the adaptor's unique connection name, the parent must have a canonical numeric accessible path, a live AtkSocket binding must exist, and the call must run on the adaptor owner thread. A same-process target on a different unique D-Bus connection keeps the remote geometry route. `root` is not a valid numeric socket target. These conditions could leave a geometry wait outside A, but they do not make the observed public Name call a geometry query.

The adaptor connects its global bus to the default GLib context (`bridge.c:1135`), and separate private application connections have their own setup. A neither services an uniterated context nor changes connection selection for a root Name property. Unknown actual destination connection, root GType, dispatch thread, and client-side callback stack remain material gaps.

## Smallest next discriminating diagnostic

Root must approve and gate the next cloud run. Keep the same app/package, real workflow, strict geometry checks, cache settings, and existing 180-second phase deadline. Add evidence only:

1. Start a timestamped accessibility-bus wire monitor before the geometry client. Retain method serial, sender, destination, path, interface, member, arguments, and reply serial for `GetApplicationBusAddress`, `Cache.GetItems`, and `Properties.Get(Accessible,Name)`. Resolve `:1.29` ownership/PID at that time. Record the private application-bus address if bootstrap returns one; an accessibility-bus monitor alone does not observe a later private connection.
2. During the unmatched call, capture one simultaneous all-thread stack snapshot of the geometry client and LocalSend PID, with mapped library identities. Obtain the concrete root GType/get-name callback identity if it is visible in debugger state. Use a bounded snapshot command within the unchanged phase deadline; do not extend the wait or replace the public API check.

Interpretation: no Name send plus client stack in bootstrap/dispatch locates the wait before the property request; a Name reply followed by a client dispatch/deferred stack locates it after the reply; Name delivery without a reply plus app stack in `impl_get_Name`/dynamic get-name identifies the server callback; app stack in `Cache.GetItems` identifies bootstrap/cache enumeration; an app stack outside D-Bus dispatch with queued Name identifies context servicing or another blocking operation. A socket geometry frame would require inspecting its bus/parent ID and thread eligibility before deciding whether A covers it. Do not bypass root Name or weaken geometry checks to turn an infrastructure diagnosis into a passing result.

## Source identities

- Retained patch A SHA-256: `d4348bcd7197e837b03004f7e80ca6dc69b4bee8cd81ea35dba94dd37424f01d`.
- `accessible-adaptor.c`: `7062bc15a9bea6039986bf8b29543a0d09087d5bc037ac33259b99da8ec3eabe`.
- `atspi-misc.c`: `f3950265e70f62de3b3b072f52547312b2e4fd770ace3533e7cc88e6b8fdaac1`.
- `dbind.c`: `ae12995f42fc6c65dfa22b4345409c78745fdb8b9db6ff2b9a7f23371c046fbe`.
- Patched `socket-adaptor.c`: `8b763df2b23c3d4e0f65084b3d96d4156831689c85fec76e6554b4b4a716b48c`.
