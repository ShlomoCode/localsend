import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:mockito/mockito.dart';

import '../../mocks.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const nativeChannel = MethodChannel('main-delegate-channel');
  const windowsChannel = MethodChannel('org.localsend.localsend_app/window-placement');
  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  final legacyFrame = WindowDimensions(position: const Offset(120, 80), size: const Size(700, 550));
  final windowsPlacement = {'left': -1200, 'top': 80, 'right': -500, 'bottom': 630};

  late MockPersistenceService persistence;
  late List<MethodCall> nativeCalls;
  late List<MethodCall> windowsCalls;
  late List<MethodCall> windowCalls;
  late List<MethodCall> screenCalls;
  late List<Map<String, int>> windowsGetResults;
  late List<bool> windowsRestoreResults;
  var nativeRestoreResult = false;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    persistence = MockPersistenceService();
    nativeCalls = [];
    windowsCalls = [];
    windowCalls = [];
    screenCalls = [];
    windowsGetResults = [windowsPlacement];
    windowsRestoreResults = [true];
    nativeRestoreResult = false;
    when(persistence.getSaveWindowPlacement()).thenReturn(true);
    when(persistence.isPortableMode()).thenReturn(false);
    when(persistence.getWindowLastDimensions()).thenReturn(legacyFrame);
    when(persistence.getWindowsWindowPlacement()).thenReturn(null);

    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'restoreWindowFrame') return nativeRestoreResult;
      return null;
    });
    messenger.setMockMethodCallHandler(windowsChannel, (call) async {
      windowsCalls.add(call);
      if (call.method == 'getWindowPlacement') {
        return windowsGetResults.length > 1 ? windowsGetResults.removeAt(0) : windowsGetResults.single;
      }
      if (call.method == 'restoreWindowPlacement') {
        return windowsRestoreResults.length > 1 ? windowsRestoreResults.removeAt(0) : windowsRestoreResults.single;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method == 'getBounds') return {'x': 0.0, 'y': 0.0, 'width': 900.0, 'height': 600.0};
      return null;
    });
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      screenCalls.add(call);
      final display = {
        'id': 'primary',
        'name': 'Primary',
        'size': {'width': 1440.0, 'height': 900.0},
        'visibleSize': {'width': 1440.0, 'height': 900.0},
        'visiblePosition': {'dx': 0.0, 'dy': 0.0},
        'scaleFactor': 1.0,
      };
      if (call.method == 'getAllDisplays') {
        return {
          'displays': [display],
        };
      }
      if (call.method == 'getPrimaryDisplay') return display;
      if (call.method == 'getCursorScreenPoint') return {'dx': 500.0, 'dy': 400.0};
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(windowsChannel, null);
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(screenChannel, null);
  });

  test('macOS native frame wins over a legacy saved frame', () async {
    nativeRestoreResult = true;

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(nativeCalls.map((call) => call.method), ['restoreWindowFrame', 'configureWindowFrameAutosave']);
    expect(nativeCalls.last.arguments, {'enabled': true});
    expect(windowCalls.map((call) => call.method), ['setMinimumSize']);
    verifyNever(persistence.getWindowLastDimensions());
    expect(screenCalls, isEmpty);
  });

  test('macOS ignores a legacy frame on a disconnected display', () async {
    when(persistence.getWindowLastDimensions()).thenReturn(
      WindowDimensions(position: const Offset(1200, 80), size: const Size(700, 550)),
    );

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(screenCalls.map((call) => call.method), [
      'getAllDisplays',
      'getPrimaryDisplay',
      'getPrimaryDisplay',
      'getAllDisplays',
      'getCursorScreenPoint',
    ]);
    expect(windowCalls.map((call) => call.method), ['setMinimumSize', 'setBounds', 'getBounds', 'setBounds']);
    expect((windowCalls[1].arguments as Map)['width'], 900.0);
    expect((windowCalls[1].arguments as Map)['height'], 600.0);
    expect((windowCalls[3].arguments as Map)['x'], 270.0);
    expect((windowCalls[3].arguments as Map)['y'], 150.0);
    expect(nativeCalls.map((call) => call.method), ['restoreWindowFrame', 'configureWindowFrameAutosave']);
  });

  test('macOS migrates the legacy frame when no native frame exists', () async {
    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(nativeCalls.map((call) => call.method), ['restoreWindowFrame', 'configureWindowFrameAutosave']);
    expect(windowCalls.map((call) => call.method), ['setMinimumSize', 'setBounds', 'setBounds']);
    expect((windowCalls[1].arguments as Map)['width'], legacyFrame.size.width);
    expect((windowCalls[1].arguments as Map)['height'], legacyFrame.size.height);
    expect((windowCalls[2].arguments as Map)['x'], legacyFrame.position.dx);
    expect((windowCalls[2].arguments as Map)['y'], legacyFrame.position.dy);
    expect(screenCalls.map((call) => call.method), ['getAllDisplays']);
  });

  test('changing frame autosave preference does not restore a frame', () async {
    final controller = WindowDimensionsController(persistence);

    await controller.configureWindowFrameAutosave(enabled: false);
    await controller.configureWindowFrameAutosave(enabled: true);

    expect(nativeCalls.map((call) => call.method), ['configureWindowFrameAutosave', 'configureWindowFrameAutosave']);
    expect(nativeCalls.map((call) => call.arguments), [
      {'enabled': false},
      {'enabled': true},
    ]);
    expect(windowCalls, isEmpty);
  });

  test('macOS native autosave suppresses legacy placement writes', () async {
    final controller = WindowDimensionsController(persistence);

    await controller.storeDimensions(windowOffset: legacyFrame.position, windowSize: legacyFrame.size);
    await controller.storePosition(windowOffset: legacyFrame.position);
    await controller.storeSize(windowSize: legacyFrame.size);

    verifyNever(persistence.setWindowOffsetX(any));
    verifyNever(persistence.setWindowOffsetY(any));
    verifyNever(persistence.setWindowWidth(any));
    verifyNever(persistence.setWindowHeight(any));
    expect(screenCalls, isEmpty);
  });

  test('portable macOS keeps the legacy placement path', () async {
    when(persistence.isPortableMode()).thenReturn(true);

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(nativeCalls, isEmpty);
    expect(screenCalls.map((call) => call.method), ['getAllDisplays']);
    expect(windowCalls.map((call) => call.method), ['setMinimumSize', 'setBounds', 'setBounds']);
    expect((windowCalls[2].arguments as Map)['x'], legacyFrame.position.dx);
    expect((windowCalls[2].arguments as Map)['y'], legacyFrame.position.dy);
  });

  test('Windows restores native placement without checking legacy screen bounds', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    when(persistence.getWindowsWindowPlacement()).thenReturn(windowsPlacement);

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(windowsCalls.map((call) => call.method), ['restoreWindowPlacement']);
    expect(windowsCalls.single.arguments, windowsPlacement);
    expect(windowCalls.map((call) => call.method), ['setMinimumSize']);
    expect(screenCalls, isEmpty);
    verifyNever(persistence.getWindowLastDimensions());
  });

  test('Windows migrates legacy placement through the native window frame', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final oldDisplayFrame = WindowDimensions(position: const Offset(4000, 80), size: const Size(700, 550));
    final preRestorePlacement = {'left': 4000, 'top': 80, 'right': 4700, 'bottom': 630};
    final correctedPlacement = {'left': 250, 'top': 80, 'right': 950, 'bottom': 630};
    windowsGetResults = [preRestorePlacement, correctedPlacement];
    when(persistence.getWindowLastDimensions()).thenReturn(oldDisplayFrame);

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(windowCalls.map((call) => call.method), ['setMinimumSize', 'setBounds', 'setBounds']);
    expect((windowCalls[2].arguments as Map)['x'], oldDisplayFrame.position.dx);
    expect(windowsCalls.map((call) => call.method), ['getWindowPlacement', 'restoreWindowPlacement', 'getWindowPlacement']);
    expect(windowsCalls[1].arguments, preRestorePlacement);
    verify(persistence.setWindowsWindowPlacement(correctedPlacement)).called(1);
    expect(screenCalls, isEmpty);
  });

  test('Windows replaces rejected stored native placement with migrated legacy placement', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final rejectedPlacement = {'left': 5000, 'top': 80, 'right': 5700, 'bottom': 630};
    when(persistence.getWindowsWindowPlacement()).thenReturn(rejectedPlacement);
    windowsRestoreResults = [false, true];

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(windowsCalls.map((call) => call.method), ['restoreWindowPlacement', 'getWindowPlacement', 'restoreWindowPlacement', 'getWindowPlacement']);
    expect(windowsCalls.first.arguments, rejectedPlacement);
    expect(windowCalls.map((call) => call.method), ['setMinimumSize', 'setBounds', 'setBounds']);
    verify(persistence.setWindowsWindowPlacement(windowsPlacement)).called(1);
  });

  test('Windows with placement saving disabled uses default dimensions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    when(persistence.getSaveWindowPlacement()).thenReturn(false);
    when(persistence.getWindowsWindowPlacement()).thenReturn(windowsPlacement);

    await WindowDimensionsController(persistence).initDimensionsConfiguration();

    expect(windowsCalls, isEmpty);
    expect((windowCalls[1].arguments as Map)['width'], 900.0);
    expect((windowCalls[1].arguments as Map)['height'], 600.0);
    verifyNever(persistence.getWindowLastDimensions());
  });

  test('Windows saves native normal frame for move, resize, and close', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final controller = WindowDimensionsController(persistence);

    await controller.storePosition(windowOffset: legacyFrame.position);
    await controller.storeSize(windowSize: legacyFrame.size);
    await controller.storeDimensions(windowOffset: legacyFrame.position, windowSize: legacyFrame.size);

    expect(windowsCalls.map((call) => call.method), ['getWindowPlacement', 'getWindowPlacement', 'getWindowPlacement']);
    verify(persistence.setWindowsWindowPlacement(windowsPlacement)).called(3);
    verifyNever(persistence.setWindowOffsetX(any));
    verifyNever(persistence.setWindowOffsetY(any));
    verifyNever(persistence.setWindowWidth(any));
    verifyNever(persistence.setWindowHeight(any));
    expect(screenCalls, isEmpty);
  });

  test('portable Windows saves native placement in its portable persistence service', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    when(persistence.isPortableMode()).thenReturn(true);
    when(persistence.getWindowsWindowPlacement()).thenReturn(windowsPlacement);
    final controller = WindowDimensionsController(persistence);

    await controller.initDimensionsConfiguration();
    await controller.storePosition(windowOffset: legacyFrame.position);

    expect(windowsCalls.map((call) => call.method), ['restoreWindowPlacement', 'getWindowPlacement']);
    verify(persistence.setWindowsWindowPlacement(windowsPlacement)).called(1);
    expect(screenCalls, isEmpty);
  });
}
