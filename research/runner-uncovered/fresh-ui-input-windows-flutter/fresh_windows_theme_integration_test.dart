import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:win32/win32.dart';
import 'windows_theme_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Process host;
  late Directory temp;
  late int hwnd;
  var getIdCalls = 0;
  const channel = MethodChannel('window_manager');
  setUpAll(() async {
    if (!Platform.isWindows) throw StateError('This integration fixture requires native Windows');
    final exe = Platform.environment['LOCALSEND_THEME_HOST'];
    if (exe == null) throw StateError('LOCALSEND_THEME_HOST must name compiled native_host.exe');
    temp = await Directory.systemTemp.createTemp('localsend-theme-ffi-');
    final file = File('${temp.path}/hwnd.txt');
    host = await Process.start(exe, [file.path]);
    host.stdout.drain<void>();
    host.stderr.drain<void>();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await file.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!await file.exists()) throw StateError('Native host did not publish HWND');
    hwnd = int.parse((await file.readAsString()).trim());
    expect(IsWindow(hwnd), isNot(0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getId') throw StateError('Unexpected native channel method ${call.method}');
      getIdCalls++;
      return hwnd;
    });
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    try {
      await host.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      host.kill();
    }
    await temp.delete(recursive: true);
  });

  int nativeDark() => using((arena) {
    final value = arena<Int32>();
    final result = DwmGetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, value.cast(), sizeOf<Int32>());
    expect(result, 0, reason: 'DwmGetWindowAttribute must succeed on real fixture HWND');
    return value.value;
  });

  test(
    'actual app helper makes native frame dark',
    () => withWindows(() async {
      await updateSystemOverlayStyleWithBrightness(Brightness.dark);
      expect(nativeDark(), 1);
      expect(getIdCalls, greaterThan(0));
    }),
  );
  test(
    'actual app helper reverses native frame to light',
    () => withWindows(() async {
      await updateSystemOverlayStyleWithBrightness(Brightness.dark);
      await updateSystemOverlayStyleWithBrightness(Brightness.light);
      expect(nativeDark(), 0);
    }),
  );
  testWidgets(
    'exact app builder applies explicitly selected light theme',
    (tester) => withWindows(() async {
      await updateSystemOverlayStyleWithBrightness(Brightness.dark);
      await tester.pumpWidget(fixtureApp(ThemeMode.light));
      await tester.pumpAndSettle();
      expect(nativeDark(), 0);
      expect(tester.takeException(), isNull);
    }),
  );
  testWidgets(
    'exact app builder applies explicitly selected dark theme',
    (tester) => withWindows(() async {
      await updateSystemOverlayStyleWithBrightness(Brightness.light);
      await tester.pumpWidget(fixtureApp(ThemeMode.dark));
      await tester.pumpAndSettle();
      expect(nativeDark(), 1);
      expect(tester.takeException(), isNull);
    }),
  );
  testWidgets(
    'app builder follows inherited system brightness changes',
    (tester) => withWindows(() async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(fixtureApp(ThemeMode.system));
      await tester.pumpAndSettle();
      expect(nativeDark(), 0);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(nativeDark(), 1);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(nativeDark(), 0);
      expect(tester.takeException(), isNull);
    }),
  );
}

Future<T> withWindows<T>(Future<T> Function() run) async {
  final previous = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    return await run();
  } finally {
    debugDefaultTargetPlatformOverride = previous;
  }
}
