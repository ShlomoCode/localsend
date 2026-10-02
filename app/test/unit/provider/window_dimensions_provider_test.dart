import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../mocks.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const macosChannel = MethodChannel('main-delegate-channel');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late MockPersistenceService persistence;
  late Rect frame;
  late List<MethodCall> nativeCalls;

  const display = {
    'id': 'main',
    'size': {'width': 1512.0, 'height': 982.0},
    'visibleSize': {'width': 1512.0, 'height': 900.0},
    'visiblePosition': {'dx': 0.0, 'dy': 38.0},
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    persistence = MockPersistenceService();
    when(persistence.getSaveWindowPlacement()).thenReturn(true);
    when(persistence.isPortableMode()).thenReturn(false);
    when(persistence.getWindowLastDimensions()).thenReturn(
      WindowDimensions(position: const Offset(1200, 250), size: const Size(650, 520)),
    );
    frame = const Rect.fromLTWH(0, 0, 900, 600);
    nativeCalls = [];

    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'getBounds') {
        return {'x': frame.left, 'y': frame.top, 'width': frame.width, 'height': frame.height};
      }
      if (call.method == 'setBounds') {
        final args = call.arguments as Map;
        frame = Rect.fromLTWH(
          args['x'] as double? ?? frame.left,
          args['y'] as double? ?? frame.top,
          args['width'] as double? ?? frame.width,
          args['height'] as double? ?? frame.height,
        );
      }
      return null;
    });
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      if (call.method == 'getAllDisplays') {
        return {
          'displays': [display],
        };
      }
      if (call.method == 'getCursorScreenPoint') {
        return {'dx': 500.0, 'dy': 300.0};
      }
      return display;
    });
    messenger.setMockMethodCallHandler(macosChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'configureWindowFrameAutosave' && (call.arguments as Map)['enabled'] == true) {
        // The native boundary returns a restored frame; Dart must not replace it.
        frame = const Rect.fromLTWH(862, 250, 650, 520);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(screenChannel, null);
    messenger.setMockMethodCallHandler(macosChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('macOS delegates partially off-screen legacy placement to AppKit and keeps the native result', () async {
    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(frame, const Rect.fromLTWH(862, 250, 650, 520));
    expect(nativeCalls.single.method, 'configureWindowFrameAutosave');
    expect(nativeCalls.single.arguments, {'enabled': true, 'migrateLegacyFrame': true});
  });

  test('macOS disables native restoration when window placement saving is off', () async {
    when(persistence.getSaveWindowPlacement()).thenReturn(false);

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(frame.size, const Size(900, 600));
    expect(nativeCalls.single.arguments, {'enabled': false, 'migrateLegacyFrame': false});
  });

  test('portable macOS keeps file-based geometry persistence and does not enable native autosave', () async {
    when(persistence.isPortableMode()).thenReturn(true);
    when(persistence.getWindowLastDimensions()).thenReturn(
      WindowDimensions(position: const Offset(100, 100), size: const Size(650, 520)),
    );
    final controller = WindowDimensionsController(persistence);

    await controller.initDimensionsConfiguration();
    await controller.storeDimensions(windowOffset: const Offset(200, 150), windowSize: const Size(700, 550));

    expect(frame, const Rect.fromLTWH(100, 100, 650, 520));
    expect(nativeCalls, isEmpty);
    verify(persistence.setWindowOffsetX(200)).called(1);
    verify(persistence.setWindowOffsetY(150)).called(1);
    verify(persistence.setWindowWidth(700)).called(1);
    verify(persistence.setWindowHeight(550)).called(1);
  });

  test('changing the setting updates AppKit immediately without restarting the app', () async {
    final service = Notifier.test(notifier: SettingsService(persistence));

    await service.notifier.setSaveWindowPlacement(false);
    expect(service.state.saveWindowPlacement, false);
    await service.notifier.setSaveWindowPlacement(true);
    expect(service.state.saveWindowPlacement, true);

    expect(nativeCalls.map((call) => call.arguments), [
      {'enabled': false, 'migrateLegacyFrame': false},
      {'enabled': true, 'migrateLegacyFrame': false},
    ]);
    verify(persistence.setSaveWindowPlacement(false)).called(1);
    verify(persistence.setSaveWindowPlacement(true)).called(1);
  });
}
