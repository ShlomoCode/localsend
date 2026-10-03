import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Run against separate before/after copies of the actual pinned application.
// flutter test --dart-define=PATCHED=false|true <fixture>
void main() {
  const patched = bool.fromEnvironment('PATCHED');
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual Linux resize callback and Wayland size-only restart', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    cacheWaylandStatus(true);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      cacheWaylandStatus(false);
    });
    SharedPreferences.setMockInitialValues({
      'ls_version': 999,
      'ls_locale': 'en',
      'ls_show_token': 'fixture-token',
      'ls_alias': 'fixture-device',
      'ls_security_context': '{}',
      'ls_color': 'localsend',
    });
    final persistence = await PersistenceService.initialize(supportsDynamicColors: false);
    final calls = <MethodCall>[];
    var liveSize = const Size(710, 640);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
      calls.add(call);
      if (call.method == 'getBounds') return {'x': 0.0, 'y': 0.0, 'width': liveSize.width, 'height': liveSize.height};
      if (call.method == 'setBounds') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (args.containsKey('width')) liveSize = Size(args['width'] as double, args['height'] as double);
      }
      return null;
    });
    final display = {
      'id': 'fixture-display',
      'size': {'width': 1920.0, 'height': 1080.0},
      'visibleSize': {'width': 1920.0, 'height': 1080.0},
      'visiblePosition': {'dx': 0.0, 'dy': 0.0},
      'scaleFactor': 1.0,
    };
    messenger.setMockMethodCallHandler(const MethodChannel('dev.leanflutter.plugins/screen_retriever'), (call) async {
      if (call.method == 'getAllDisplays') return {'displays': [display]};
      if (call.method == 'getPrimaryDisplay') return display;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('dev.leanflutter.plugins/screen_retriever'), null);
    });
    await tester.pumpWidget(RefenaScope(
      overrides: [persistenceProvider.overrideWithValue(persistence)],
      child: const MaterialApp(home: WindowWatcher(child: SizedBox())),
    ));
    await tester.pump();
    // This is the actual event emitted by window_manager 0.5.2's Linux plugin.
    await messenger.handlePlatformMessage(
      'window_manager',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('onEvent', {'eventName': 'resize'})),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('ls_window_width'), patched ? 710.0 : isNull);
    expect(prefs.getDouble('ls_window_height'), patched ? 640.0 : isNull);
    // Independently exercise persisted size without compositor-owned position.
    await persistence.setWindowWidth(710);
    await persistence.setWindowHeight(640);
    expect(persistence.getWindowLastDimensions()?.size, patched ? const Size(710, 640) : isNull);
    // Seed old-style offsets as well: forced-false placement remains the cause
    // even when every saved geometry field was present before the restart.
    await persistence.setWindowOffsetX(0);
    await persistence.setWindowOffsetY(0);
    expect(persistence.getSaveWindowPlacement(), isFalse);
    calls.clear();
    await WindowDimensionsController(persistence).initDimensionsConfiguration();
    final bounds = calls.where((call) => call.method == 'setBounds').map((call) => Map<String, dynamic>.from(call.arguments as Map)).toList();
    final sizes = bounds.where((args) => args.containsKey('width')).toList();
    expect(sizes.single['width'], patched ? 710.0 : 900.0);
    expect(sizes.single['height'], patched ? 640.0 : 600.0);
    if (patched) expect(bounds.where((args) => args.containsKey('x') || args.containsKey('y')), isEmpty);
    print('PATCHED=$patched resize callback saved=${prefs.getDouble('ls_window_width')} restart size=$sizes');
    await tester.pumpWidget(const SizedBox());
  });
}
