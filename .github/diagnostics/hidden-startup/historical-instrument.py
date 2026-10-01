#!/usr/bin/env python3
"""Add disposable startup traces to the LocalSend source before the SDK bump.

Run from the checkout of 50451b233aef14160810df88363b277baa468032.
The same instrumented source is built with both Flutter SDKs.
"""

from pathlib import Path

changes = {}


def edit(name, old, new):
    path = Path(name)
    source = changes.get(path, path.read_text())
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{name}: expected one match, found {count}: {old!r}")
    changes[path] = source.replace(old, new, 1)


def marker(label):
    return f"print('[HIDDEN-TRACE] ${{DateTime.now().toIso8601String()}} {label}');"


init = "app/lib/config/init.dart"
edit(init, "  WidgetsFlutterBinding.ensureInitialized();",
     "  " + marker("preInit.enter") + "\n  WidgetsFlutterBinding.ensureInitialized();\n  " + marker("preInit.binding.ready"))
edit(init, "  await RustLib.init();",
     "  " + marker("preInit.rust.before") + "\n  await RustLib.init();\n  " + marker("preInit.rust.after"))
edit(init, "  await Rhttp.init();\n\n  final dynamicColors",
     "  " + marker("preInit.rhttp.before") + "\n  await Rhttp.init();\n  " + marker("preInit.rhttp.after") + "\n\n  final dynamicColors")
edit(init, "  final dynamicColors = await getDynamicColors();",
     "  " + marker("preInit.dynamicColors.before") + "\n  final dynamicColors = await getDynamicColors();\n  " + marker("preInit.dynamicColors.after"))
edit(init, "  await initI18n();",
     "  " + marker("preInit.i18n.before") + "\n  await initI18n();\n  " + marker("preInit.i18n.after"))
edit(init, "      await initTray();",
     "      " + marker("preInit.tray.before") + "\n      await initTray();\n      " + marker("preInit.tray.after"))
edit(init, "    await WindowManager.instance.ensureInitialized();",
     "    " + marker("preInit.windowManager.before") + "\n    await WindowManager.instance.ensureInitialized();\n    " + marker("preInit.windowManager.after"))
edit(init, "    await WindowDimensionsController(persistenceService).initDimensionsConfiguration();",
     "    " + marker("preInit.dimensions.before") + "\n    await WindowDimensionsController(persistenceService).initDimensionsConfiguration();\n    " + marker("preInit.dimensions.after"))
edit(init, "  final container = RefenaContainer(",
     "  " + marker("preInit.container.before") + "\n  final container = RefenaContainer(")
edit(init, "  await container\n      .redux(parentIsolateProvider)",
     "  " + marker("preInit.isolates.before") + "\n  await container\n      .redux(parentIsolateProvider)")
edit(init, "  return container;",
     "  " + marker("preInit.isolates.after") + "\n  " + marker("preInit.return") + "\n  return container;")
edit(init, "Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {",
     "Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {\n  " + marker("postInit.enter"))
edit(init, "    await ref.notifier(serverProvider).startServerFromSettings();",
     "    " + marker("postInit.server.before") + "\n    await ref.notifier(serverProvider).startServerFromSettings();\n    " + marker("postInit.server.after"))
edit(init, "  } catch (e) {\n    if (context.mounted) {",
     "  } catch (e) {\n    print('[HIDDEN-TRACE] postInit.server.error $e');\n    if (context.mounted) {")

main = "app/lib/main.dart"
edit(main, "    container = await preInit(args);",
     "    " + marker("main.preInit.before") + "\n    container = await preInit(args);\n    " + marker("main.preInit.after"))
edit(main, "  runApp(\n", "  WidgetsBinding.instance.addPostFrameCallback((_) { " + marker("main.firstFrame") + " });\n  " + marker("main.runApp.before") + "\n  runApp(\n")
edit(main, "  );\n}\n\nclass LocalSendApp", "  );\n  " + marker("main.runApp.after") + "\n}\n\nclass LocalSendApp")
edit(main, "    final ref = context.ref;", "    " + marker("LocalSendApp.build") + "\n    final ref = context.ref;")

home = "app/lib/pages/home_page.dart"
edit(home, "    super.initState();", "    super.initState();\n    " + marker("HomePage.initState"))
edit(home, "    ensureRef((ref) async {", "    ensureRef((ref) async {\n      " + marker("HomePage.ensureRef"))
edit(home, "      await postInit(context, ref, widget.appStart);",
     "      " + marker("HomePage.postInit.before") + "\n      await postInit(context, ref, widget.appStart);\n      " + marker("HomePage.postInit.after"))

native = "app/linux/my_application.cc"
edit(native, "// Implements GApplication::activate.", '''static void trace_window_map(GtkWidget* widget, gpointer) {
  g_printerr("[HIDDEN-TRACE] native.map visible=%d realized=%d mapped=%d\\n",
             gtk_widget_get_visible(widget), gtk_widget_get_realized(widget), gtk_widget_get_mapped(widget));
}
static void trace_window_unmap(GtkWidget* widget, gpointer) {
  g_printerr("[HIDDEN-TRACE] native.unmap visible=%d realized=%d mapped=%d\\n",
             gtk_widget_get_visible(widget), gtk_widget_get_realized(widget), gtk_widget_get_mapped(widget));
}

// Implements GApplication::activate.''')
edit(native, "  gtk_window_set_default_size(window, 400, 500);", '''  g_signal_connect(window, "map", G_CALLBACK(trace_window_map), nullptr);
  g_signal_connect(window, "unmap", G_CALLBACK(trace_window_unmap), nullptr);
  gtk_window_set_default_size(window, 400, 500);''')
edit(native, "  g_autoptr(FlDartProject) project = fl_dart_project_new();", '''  g_printerr("[HIDDEN-TRACE] native.afterInitialWindow hidden=%d visible=%d realized=%d mapped=%d\\n",
             start_hidden, gtk_widget_get_visible(GTK_WIDGET(window)),
             gtk_widget_get_realized(GTK_WIDGET(window)), gtk_widget_get_mapped(GTK_WIDGET(window)));
  g_autoptr(FlDartProject) project = fl_dart_project_new();''')
edit(native, "  FlView* view = fl_view_new(project);", '''  g_printerr("[HIDDEN-TRACE] native.view.before hidden=%d\\n", start_hidden);
  FlView* view = fl_view_new(project);
  g_printerr("[HIDDEN-TRACE] native.view.after hidden=%d\\n", start_hidden);''')

for path, source in changes.items():
    path.write_text(source)
    print(f"instrumented {path}")
