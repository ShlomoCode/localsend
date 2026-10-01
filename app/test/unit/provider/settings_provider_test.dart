import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:mockito/mockito.dart';

import '../../mocks.mocks.dart';

class _TestSettingsService extends SettingsService {
  _TestSettingsService(super.persistence) {
    state = init();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Always on Top applies both states immediately and persists them', () async {
    final persistence = MockPersistenceService();
    when(persistence.getAlwaysOnTop()).thenReturn(true);
    final calls = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setAlwaysOnTop') {
        calls.add((call.arguments as Map)['isAlwaysOnTop'] as bool);
      }
      return null;
    });

    final service = _TestSettingsService(persistence);
    expect(service.state.alwaysOnTop, isTrue);

    await service.setAlwaysOnTop(false);
    await service.setAlwaysOnTop(true);

    expect(calls, [false, true]);
    verifyInOrder([persistence.setAlwaysOnTop(false), persistence.setAlwaysOnTop(true)]);
    expect(service.state.alwaysOnTop, isTrue);
  });

  test('Always on Top leaves the saved setting intact if the window rejects the change', () async {
    final persistence = MockPersistenceService();
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'failed');
    });

    final service = _TestSettingsService(persistence);
    await expectLater(service.setAlwaysOnTop(true), throwsA(isA<PlatformException>()));

    verifyNever(persistence.setAlwaysOnTop(any));
    expect(service.state.alwaysOnTop, isFalse);
  });

  test('Always on Top avoids the desktop window channel on mobile', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final persistence = MockPersistenceService();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    final service = _TestSettingsService(persistence);
    await service.setAlwaysOnTop(true);

    expect(calls, isEmpty);
    verify(persistence.setAlwaysOnTop(true)).called(1);
  });
}
