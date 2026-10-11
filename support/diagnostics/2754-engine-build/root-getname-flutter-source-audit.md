# Unmatched root-name public call: pinned Flutter B source audit

Read-only audit. No builds, tests, runtime probes, or source edits were performed. Official AT-SPI adaptor and local-dispatch analysis is separately owned by the package source reviewer. This report contains no upstream links.

## Conclusion

The inspected pinned Flutter implementation does not expose a separate same-process root-name delegation through an AtkSocket or parent. B changes the socket parent relationship and teardown; it does not change names. The retained run establishes an unmatched public wrapper call named GetName for the application root, not the exact D-Bus method or the internal function that blocked. A longer deadline or weaker geometry gate would not resolve this distinction.

## Exact accepted base and B provenance (corrected after independent re-read)

Independently exported exact engine commit 42d3d75a56efe1a2e9902f52dc8006099c45d937 using git show into /tmp/2754-root-getname-exactbase. The retained accepted build38153341418 B manifest identifies this engine commit and experiment patch SHA256 b7581b816fb1ade88461d8120d7a97a86ee84575a4db311a9f0a29d310bd29ce. Both full and compact accepted-build B-with-tests.patch copies hash to that value; a copy is preserved in the exactbase audit directory. The actual AB guest original-engine-archive.sha256 records entire B archive SHA256 9052f1e71268d2e3d908584552c20a6b76a184c23da7dc7fa5bd90d4d8068333. These are separate archive and patch identities. Original HEAD33aadb exports remain only historical comparison material, not evidence of the accepted base.

Exact base source SHA256:

- fl_accessible_node.cc: e98d21971aa5f9793941b63b3aec32de551f9bc58d1f806d084d664e46390505
- fl_socket_accessible.cc: d178f01498278cd79f9f4f61d51de6620c9af08fe8e8b5aa75c6a465057cd75b
- fl_view.cc: 691d2ff27e7841f371777f9eac032ef8c9efd5b4c8c9735c31343513bf7ed12d
- fl_view_accessible.cc: 0ae818377fe4466bc1417fd4da78e2f3411d7c16c508e3775da61d939471e824

- Exact-base fl_view.cc:679-688 sets the FlView widget accessible type to FlSocketAccessible, creates FlViewAccessible, then embeds the AtkPlug ID into the host socket.
- fl_socket_accessible.cc:9-16 defines FlSocketAccessible as GtkContainerAccessible. Its child getter returns the stored AtkSocket. Class initialization at43-51 overrides initialize, child count, and ref_child, but not get_name. Initialize creates atk_socket_new at40; embed at55-56 calls atk_socket_embed.
- fl_view_accessible.cc:19-33 defines FlViewAccessible as AtkPlug. Semantics node0 is assigned this plug as parent at72-74. Child-count/ref-child methods expose that node; class initialization at134-144 overrides children, role, state, and dispose, not get_name.
- Exact-base fl_accessible_node.cc:193-196 returns priv->name directly. Its setter at372 onward frees/duplicates the supplied label. At498 its AtkObject get_name vfunc is installed. Parent retrieval at199-201 returns the separately stored parent pointer, managed as a weak pointer. Geometry at319-321 climbs that parent; the name getter does not.
- fl_view_accessible.cc:171 assigns the node label to fl_accessible_node_set_name during semantics updates.
- B-with-tests.patch first hunk adds atk_object_set_parent(accessible_socket, object), detach on widget_unset/dispose, and a test. It does not add a name getter or modify FlViewAccessible / node naming.

The earlier HEAD33aadb Linux source search found no atk_get_root or AtkUtil override. The exact-base four classes inspected likewise contain no such override. This narrower exact-base observation does not prove the runtime GType of the application root or claim a complete search of its original Linux directory.

Source skew is now bounded: FlSocketAccessible files are byte-identical between the original base and previously inspected HEAD33aadb. FlViewAccessible still has the same name-free class initialization and label assignment; its ownership changes do not supply a name getter. FlAccessibleNode original get_name and name setter have the same local-name behavior, but parent ownership changes from weak raw pointer to GWeakRef and HEAD33 adds AtkText support. The previous weak-reference implementation description therefore cannot be applied to exact base. fl_view has extensive unrelated renderer changes, so the exact-base embedding lines above replace the earlier line references. The accepted B patch changes only fl_socket_accessible.cc plus BUILD/test files, so exact-base node and view names are unchanged in accepted B. No tests or patch application were performed.

## Application-root boundary

The retained AT-SPI2.52 source maps /org/a11y/atspi/accessible/root to spi_global_app_data->root (accessible-register.c254-256). bridge.c1084 obtains atk_get_root and stores it at1105. Thus the root path is the bridge application root, not established by this log as Flutter semantics node0 or FlViewAccessible. The Accessible Name adaptor calls atk_object_get_name on its mapped object. The ATK base object getter at atkobject.c1417 returns object->name; AtkSocket class initialization adds no name override. Exact GTK application-root vfunc and bridge overrides remain with the AT-SPI reviewer.

## Actual retained-run limit

Both geometry streams enter public GetName call50 for bus :1.29, path /org/a11y/atspi/accessible/root, after GetProcessId returned4618 and cache-clear wrappers returned. Neither records its return. Each process reaches deadline180s and exits124; no node/extents/name result is recorded.

Public atspi_accessible_get_name may call Properties.Get(Name), and its property wrapper performs deferred-message processing before returning. Existing records contain no matched wire serial/reply or simultaneous client/app stacks. They cannot distinguish a missing Name reply, application bridge already occupied by cache/geometry work, or deferred client processing after a Name reply. Source topology is inference, not runtime proof.

## Next discriminating evidence

On a separately authorized diagnostic run, retain the client public call boundary plus D-Bus message/reply serials for Properties.Get(Name) and Cache.GetItems, and capture all-thread stacks of both geometry client and PID4618 at that same unresolved call. Include the bridge root runtime GType and getter vfunc if obtaining it safely is supported. A delivered Name reply followed by a client stack in deferred/cache handling separates client dispatch from a server-side Name wait. An undelivered Name request with app stack in a same-process component/cache forwarding path would identify the blocked server dependency. No extra geometry result should be treated as valid unless the strict consumer gate actually completes.

## Interaction boundary retained separately

See /tmp/2754-run38177219980-accessibility-audit.md. events.json1013 records geometry-phase-escape returncode0 at t939.88765064, before fresh interaction setup. The subsequent original interactions-fresh-text-before image still visibly contains the Type message modal and dimmed background. Returncode0 proves command success, not dialog dismissal. Restored client origin(200,391) differs from original(190,319). Interaction harness never starts; speech/audio remain untested.
