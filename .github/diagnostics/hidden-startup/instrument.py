from pathlib import Path


def replace(path, old, new):
    source = Path(path)
    text = source.read_text()
    assert text.count(old) == 1, (path, old, text.count(old))
    source.write_text(text.replace(old, new))


def marker(label):
    return "print('[LS-REPRO] ${DateTime.now().toIso8601String()} " + label + "');"


replace('app/lib/config/init.dart',
        '  WidgetsFlutterBinding.ensureInitialized();',
        '  WidgetsFlutterBinding.ensureInitialized();\n  ' + marker('PRE_INIT_ENTER'))
replace('app/lib/config/init.dart',
        '  await container.redux(parentIsolateProvider).dispatchAsync(IsolateSetupAction());',
        '  await container.redux(parentIsolateProvider).dispatchAsync(IsolateSetupAction());\n  ' + marker('ISOLATES_READY'))
replace('app/lib/config/init.dart',
        '  return container;',
        '  ' + marker('PRE_INIT_DONE') + '\n  return container;')
replace('app/lib/config/init.dart',
        'Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {',
        'Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {\n  ' + marker('POST_INIT_ENTER'))
replace('app/lib/config/init.dart',
        '    await ref.notifier(serverProvider).startServerFromSettings();',
        '    ' + marker('POST_INIT_SERVER_CALL') + '\n    await ref.notifier(serverProvider).startServerFromSettings();\n    ' + marker('POST_INIT_SERVER_DONE'))
replace('app/lib/pages/home_page.dart',
        '    super.initState();',
        '    super.initState();\n    ' + marker('HOME_INIT_ENTER'))
replace('app/lib/pages/home_page.dart',
        '    ensureRef((ref) async {',
        '    ensureRef((ref) async {\n      ' + marker('HOME_REF_READY'))
replace('app/lib/main.dart',
        '  runApp(',
        '  ' + marker('RUN_APP_CALL') + '\n  WidgetsBinding.instance.addPostFrameCallback((_) { ' + marker('FIRST_FRAME_DONE') + ' });\n  runApp(')
replace('app/linux/my_application.cc',
        '  g_autoptr(FlDartProject) project = fl_dart_project_new();',
        '''  g_printerr("[LS-REPRO] NATIVE_WINDOW hidden=%d realized=%d mapped=%d visible=%d\\n",
             start_hidden, gtk_widget_get_realized(GTK_WIDGET(window)),
             gtk_widget_get_mapped(GTK_WIDGET(window)), gtk_widget_get_visible(GTK_WIDGET(window)));
  g_signal_connect(window, "map-event", G_CALLBACK(+[](GtkWidget* widget, GdkEvent*, gpointer) -> gboolean {
    g_printerr("[LS-REPRO] NATIVE_MAP mapped=%d\\n", gtk_widget_get_mapped(widget));
    return FALSE;
  }), nullptr);
  g_signal_connect(window, "unmap-event", G_CALLBACK(+[](GtkWidget* widget, GdkEvent*, gpointer) -> gboolean {
    g_printerr("[LS-REPRO] NATIVE_UNMAP mapped=%d\\n", gtk_widget_get_mapped(widget));
    return FALSE;
  }), nullptr);
  g_autoptr(FlDartProject) project = fl_dart_project_new();''')
print('Added temporary startup instrumentation')
