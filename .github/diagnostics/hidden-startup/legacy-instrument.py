#!/usr/bin/env python3
"""Instrument a disposable v1.17.0 checkout in cwd; optionally apply startup fix."""
import argparse
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--fix', action='store_true')
args = p.parse_args()
changes = {}

def edit(name, old, new):
    path = Path(name)
    source = changes.get(path, path.read_text())
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{name}: expected exactly one match, found {count}: {old!r}')
    changes[path] = source.replace(old, new, 1)

def marker(label):
    return f"print('[HIDDEN-TRACE] ${{DateTime.now().toIso8601String()}} {label}');"

init = 'app/lib/config/init.dart'
for old, label in [
    ('  WidgetsFlutterBinding.ensureInitialized();', 'preInit.binding'),
    ('\n  await Rhttp.init();', 'preInit.rhttp'),
    ('  final dynamicColors = await getDynamicColors();', 'preInit.dynamicColors'),
    ('  await initI18n();', 'preInit.i18n'),
    ('      await initTray();', 'preInit.tray'),
    ('    await WindowManager.instance.ensureInitialized();', 'preInit.windowManager'),
    ('    await WindowDimensionsController(persistenceService).initDimensionsConfiguration();', 'preInit.dimensions'),
]:
    edit(init, old, '  ' + marker(label + '.before') + '\n' + old + '\n  ' + marker(label + '.after'))
edit(init, '  final container = RefenaContainer(', '  ' + marker('preInit.container.before') + '\n  final container = RefenaContainer(')
edit(init, '      unawaited(hideToTray());', '      ' + marker('preInit.hideToTray') + '\n      unawaited(hideToTray());')
old = '''  await container.redux(parentIsolateProvider).dispatchAsync(IsolateSetupAction(
        uriContentStreamResolver: AndroidUriContentStreamResolver(),
      ));'''
edit(init, old, '  ' + marker('preInit.isolates.before') + '\n' + old + '\n  ' + marker('preInit.isolates.after'))
fix = '''  if (checkPlatformIsDesktop()) {
    // Hidden desktop windows may not build HomePage, so postInit may not run.
    try {
      await container.notifier(serverProvider).startServerFromSettings();
    } catch (e, st) {
      _logger.warning('Starting receive server during initialization failed', e, st);
    }
  }

'''
show_signal = '''  ProcessSignal.sigusr2.watch().listen((_) async {
    print('[HIDDEN-TRACE] ${DateTime.now().toIso8601String()} signal.sigusr2.showFromTray.before');
    try {
      await showFromTray();
      print('[HIDDEN-TRACE] ${DateTime.now().toIso8601String()} signal.sigusr2.showFromTray.after');
    } catch (e) {
      print('[HIDDEN-TRACE] signal.sigusr2.showFromTray.error $e');
    }
  });

'''
edit(init, '  return container;', (fix if args.fix else '') + show_signal + '  ' + marker('preInit.return') + '\n  return container;')
edit(init, '  await updateSystemOverlayStyle(context);', '  ' + marker('postInit.entry.overlay.before') + '\n  await updateSystemOverlayStyle(context);\n  ' + marker('postInit.overlay.after'))
edit(init, '    await ref.notifier(serverProvider).startServerFromSettings();', '    ' + marker('postInit.server.before') + '\n    await ref.notifier(serverProvider).startServerFromSettings();\n    ' + marker('postInit.server.after'))
edit(init, '      context.showSnackBar(e.toString());', "      print('[HIDDEN-TRACE] postInit.server.error $e');\n      context.showSnackBar(e.toString());")

home = 'app/lib/pages/home_page.dart'
edit(home, '    super.initState();', '    super.initState();\n    ' + marker('HomePage.initState'))
edit(home, '    ensureRef((ref) async {', '    ensureRef((ref) async {\n      ' + marker('HomePage.ensureRef'))
edit(home, '      await postInit(context, ref, widget.appStart);', '      ' + marker('HomePage.postInit.before') + '\n      await postInit(context, ref, widget.appStart);\n      ' + marker('HomePage.postInit.after'))

main = 'app/lib/main.dart'
edit(main, '    container = await preInit(args);', '    ' + marker('main.preInit.before') + '\n    container = await preInit(args);\n    ' + marker('main.preInit.after'))
edit(main, '  runApp(RefenaScope.withContainer(', '  WidgetsBinding.instance.addPostFrameCallback((_) { ' + marker('main.firstFrame') + ' });\n  ' + marker('main.runApp.before') + '\n  runApp(RefenaScope.withContainer(')
edit(main, '  ));\n}', '  ));\n  ' + marker('main.runApp.after') + '\n}')
edit(main, '    final ref = context.ref;', '    ' + marker('LocalSendApp.build') + '\n    final ref = context.ref;')

native = 'app/linux/my_application.cc'
edit(native, '// Implements GApplication::activate.', '''static void trace_window_map(GtkWidget*, gpointer) {
  g_printerr("[HIDDEN-TRACE] native.window.map %" G_GINT64_FORMAT "\\n", g_get_monotonic_time());
}
static void trace_window_unmap(GtkWidget*, gpointer) {
  g_printerr("[HIDDEN-TRACE] native.window.unmap %" G_GINT64_FORMAT "\\n", g_get_monotonic_time());
}

// Implements GApplication::activate.''')
edit(native, '  gtk_window_set_default_size(window, 400, 500);', '''  g_signal_connect(window, "map", G_CALLBACK(trace_window_map), nullptr);
  g_signal_connect(window, "unmap", G_CALLBACK(trace_window_unmap), nullptr);
  gtk_window_set_default_size(window, 400, 500);''')

# Validate every replacement before writing any file.
for path, source in changes.items():
    path.write_text(source)
    print(f'instrumented {path}')
