import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:tray_manager/tray_manager.dart' as tm;
import 'package:tray_manager/src/helpers/sandbox.dart';

const stableId = 'org.localsend.localsend_app';
final opens = ValueNotifier<int>(0);
final listener = HarnessListener();

class HarnessListener with tm.TrayListener {}

void record(Map<String, Object?> data) => stdout.writeln(jsonEncode(data));

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // tray_manager dispatches MenuItem.onClick inside its listener loop.
  tm.trayManager.addListener(listener);
  final mode = args.isEmpty ? 'before' : args.first;
  if (mode != 'before' && mode != 'after') {
    throw ArgumentError('Expected before or after');
  }
  runApp(const Harness());
  try {
    const icon = 'assets/tray.png';
    final sandbox = runningInSandbox();
    final nativeIconPath = sandbox ? icon : path.join(File(Platform.resolvedExecutable).parent.path, 'data/flutter_assets', icon);
    if (mode == 'before') {
      await tm.trayManager.setIcon(icon);
    } else {
      await const MethodChannel('tray_manager').invokeMethod('setIcon', {
        'id': stableId,
        'iconPath': nativeIconPath,
      });
    }
    final open = tm.MenuItem(
      key: 'open',
      label: 'Open',
      onClick: (_) {
        opens.value++;
        record({'event': 'menu_callback', 'key': 'open', 'opens': opens.value});
      },
    );
    final quit = tm.MenuItem(
      key: 'quit',
      label: 'Quit',
      onClick: (_) {
        record({'event': 'menu_callback', 'key': 'quit'});
        unawaited(() async {
          await tm.trayManager.destroy();
          await stdout.flush();
          exit(0);
        }());
      },
    );
    await tm.trayManager.setContextMenu(tm.Menu(items: [open, quit]));
    record({
      'event': 'ready',
      'mode': mode,
      'sandbox': sandbox,
      'nativeIconPath': nativeIconPath,
      'openMenuId': open.id,
      'quitMenuId': quit.id,
    });
  } catch (error, stack) {
    record({'event': 'error', 'error': error.toString(), 'stack': stack.toString()});
    await stdout.flush();
    exit(1);
  }
}

class Harness extends StatelessWidget {
  const Harness({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Tray identity research')),
      body: ValueListenableBuilder<int>(
        valueListenable: opens,
        builder: (_, count, __) => Center(child: Text('Open callbacks: $count')),
      ),
    ),
  );
}
