import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  const channel = MethodChannel('tray_manager');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('supplied application identity survives repeated icon updates', () async {
    await trayManager.setIcon('first.png', id: 'org.localsend.localsend_app');
    await trayManager.setIcon('second.png', id: 'org.localsend.localsend_app');

    expect(calls.map((call) => call.method), ['setIcon', 'setIcon']);
    expect(calls.map((call) => (call.arguments as Map)['id']), ['org.localsend.localsend_app', 'org.localsend.localsend_app']);
    expect((calls.last.arguments as Map)['iconPath'], endsWith('second.png'));
  });

  test('callers omitting identity retain generated IDs', () async {
    await trayManager.setIcon('first.png');
    await trayManager.setIcon('second.png');

    final ids = calls.map((call) => (call.arguments as Map)['id']).toList();
    expect(ids, everyElement(isA<String>().having((id) => id.isNotEmpty, 'nonempty', true)));
    expect(ids[0], isNot(ids[1]));
  });
}
