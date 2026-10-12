# GTK clipboard observer for issue 3478

This standalone GTK 3 window observes the clipboard in the retained GNOME 48.7 Wayland environment. It supplements the unmodified LocalSend experiment. It does not establish what the LocalSend process received at its GTK/plugin boundary.

The source uses `gtk_clipboard_get_default(gdk_display_get_default())` and `gtk_clipboard_request_uris`, matching the file-reading calls in the pinned pasteboard plugin at `flutter-plugins-58748dae405df5e68a131e4905d48e75d0624be2/packages/pasteboard/linux/pasteboard_plugin.cc`. It also requests targets and text to distinguish URI retrieval from other readable formats. It never writes the clipboard, injects faults, patches the plugin, or preloads a library.

## Run in the authorized remote environment

This observer has no Num Lock CLI mode. A fresh no-window GDK client's local XKB state can start with locks OFF before it receives compositor modifier events. A raw getter returning false in that state cannot qualify actual Num Lock OFF. No GNOME setting substitutes for actual state. The selected Num Lock qualification belongs to the read-only compositor oracle's keyboard Num Lock field, using the shell's public Clutter keymap getter. Retain its qualified state and the app's own Wayland modifier/keymap evidence across the later copy attempts. Physically toggle Num Lock only if that qualified observation reports ON, then re-query to verify OFF.

1. Finish and retain all three unchanged LocalSend file-copy attempts before launching this observer. Preserve the genuine Nautilus owner and the same selected file.
2. Compile the observer remotely using the environment's normal GTK 3 libraries. Record compiler, `pkg-config --modversion gtk+-3.0`, source hash, runtime library identity, desktop/session identity, and the process log. Do not compile or run locally.
3. Launch the observer in that same graphical user's session. Preserve stdout as JSON Lines and stderr separately. Keep an independent controller deadline of 120 seconds for the observer process, and clean up only the owned process if it fails to exit.
4. Use the physical controller to return to Nautilus and copy the same selected file again. Retain the controller timestamps and screenshot/recording of this action. Do not substitute a scripted clipboard owner.
5. Use the physical controller to focus **LocalSend 3478 GTK clipboard observer**, verify its visible foreground, and press **Ctrl+V**. Retain the actual input sequence. A process launch, mapped window, or clipboard request without demonstrated foreground is insufficient.
6. Retain the observer's summary and exit status beside the LocalSend observations. Keep these supplementary results separate from the app results.

The remote compile and launch commands are:

```sh
gcc -std=c11 -Wall -Wextra -O2 gtk-clipboard-probe.c -o gtk-clipboard-probe $(pkg-config --cflags --libs gtk+-3.0)
./gtk-clipboard-probe > gtk-clipboard-probe.jsonl 2> gtk-clipboard-probe.stderr
```

Do not force an alternate GDK backend. Every JSON record identifies the actual display implementation (for example, `GdkWaylandDisplay`), process ID, monotonic timestamp in microseconds, mapped state, active state, and top-level focus state. Check the backend rather than inferring Wayland from session environment variables.

## Read the output

The observer accepts one Ctrl+V sequence while its window is mapped, active, and has top-level keyboard focus. It records key value, hardware keycode, modifiers, GDK event timestamp, and `send_event`; those fields do not independently prove physical input. Controller evidence supplies that requirement.

After accepted Ctrl+V, requests run in order: targets, text, then URIs. Each request has a 5,000 ms GLib deadline. A timeout advances to the next request without claiming an empty result. GTK exposes no cancellation for these requests, so late callbacks retain valid static contexts, are labeled `late: true`, and do not overwrite timeout status or start another request. The observer quits after the last request settles, or at its 120-second lifetime deadline. The external deadline covers a stalled event loop or GTK initialization.

Callbacks preserve target names, the returned UTF-8 text, and each URI in JSON. `null: true` and a JSON `null` distinguish NULL callbacks from non-NULL empty strings or arrays. Text `count` means UTF-8 byte length; target and URI `count` mean element count. `count: -1` in the summary means unavailable. A targets callback can report a NULL pointer and zero atoms; retain both fields.

| Observation | Meaning within this observer |
| --- | --- |
| `reason: no_ctrl_v` | No Ctrl+V event reached the window within its lifetime. No clipboard read occurred. |
| `reason: no_accepted_ctrl_v` | Ctrl+V arrived but did not meet the mapped/focused/active gate. No read began. |
| `*_status: timeout` | No timely callback for that request. This is distinct from NULL or empty data. |
| `targets_count > 0`, `uris_status: callback_null` | Targets were advertised, but the URI callback returned NULL. |
| `targets_count > 0`, `uris_status: callback_value`, `uris_count: 0` | Targets were advertised, but the non-NULL URI list was empty. |
| `uris_status: callback_value`, `uris_count > 0` | This standalone GTK process obtained the listed URIs. |

Exit status 0 means the request sequence completed through callbacks; it does not assert that URIs exist or that LocalSend works. Exit status 2 means at least one request timed out. Exit status 3 means the window closed or the lifetime expired. Exit status 4 means GTK initialization could not connect to a display. Preserve `summary.reason` to distinguish the status-3 cases.

The API signatures were checked against the official GTK 3 reference through Context7: `GtkClipboardTargetsReceivedFunc`, `GtkClipboardURIReceivedFunc`, and `GtkClipboard.request_targets/request_text/request_uris`. Callback data belongs to GTK; the observer prints it during the callback and does not free it. Names returned by `gdk_atom_name` are freed after printing. No build, syntax check, test, application launch, or workload was executed locally when preparing these files.

The rejected Num Lock CLI API was checked against the official GDK 3 references for [get_num_lock_state](https://docs.gtk.org/gdk3/method.Keymap.get_num_lock_state.html) and [get_for_display](https://docs.gtk.org/gdk3/type_func.Keymap.get_for_display.html). Context7 returned no matching Num Lock entry, so these references were read directly. GTK's `gtk-3-24` source in `gdk/wayland/gdkkeys-wayland.c` shows that the getter reads process-local XKB LED state and that new keymaps start with `xkb_state_new`. `gdk/wayland/gdkdevice-wayland.c`, `keyboard_handle_modifiers`, applies the compositor's depressed/latched/locked masks with `xkb_state_update_mask` and then emits `state-changed`. This source establishes why an invisible fresh-client getter is unsuitable. The compositor oracle qualification and its runtime evidence are owned by the environment and scenario workers.
