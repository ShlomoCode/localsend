import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/directory_access_channel.dart' as directory_channel;
import 'package:localsend_app/util/native/directory_access_pool.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.localsend.localsendApp/directory-access');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('directory selection preserves cancellation and a local directory without a scope', () async {
    Object? response;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDirectoryAccess');
      expect(call.arguments, isNull);
      return response;
    });
    expect(await directory_channel.getDirectoryAccess(), isNull);
    response = {'path': '/local/selected', 'accessToken': null};
    expect(await directory_channel.getDirectoryAccess(), (path: '/local/selected', accessToken: null));
  });

  test('a picked native lease is released through the app channel exactly once', () async {
    final released = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getDirectoryAccess') {
        return {'path': '/external/selected', 'accessToken': 'native-lease'};
      }
      expect(call.method, 'releaseDirectoryAccess');
      released.add(call.arguments);
      return null;
    });
    final access = (await directory_channel.getDirectoryAccess())!;
    final owner = directoryAccessPool.registerPicked(path: access.path, accessToken: access.accessToken!);
    owner.dispose();
    owner.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(released, [
      {'accessToken': 'native-lease'},
    ]);
  });
}
