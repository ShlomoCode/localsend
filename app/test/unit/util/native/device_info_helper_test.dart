import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/device_info_helper.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/device_info');
  late Map<String, Object?> deviceInfo;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    deviceInfo = {
      'version': {'codename': 'REL', 'incremental': '', 'release': '12', 'sdkInt': 31},
      for (final key in [
        'board',
        'bootloader',
        'brand',
        'device',
        'display',
        'fingerprint',
        'hardware',
        'host',
        'id',
        'manufacturer',
        'product',
        'tags',
        'type',
      ])
        key: '',
      'name': '  My phone  ',
      'model': 'Pixel 8 Pro',
      'isPhysicalDevice': true,
      'isLowRamDevice': false,
      'freeDiskSize': 0,
      'totalDiskSize': 0,
      'physicalRamSize': 0,
      'availableRamSize': 0,
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getDeviceInfo');
      return deviceInfo;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android system name uses the configured name instead of the model or hostname', () async {
    expect(await getSystemDeviceName(), 'My phone');
  });

  test('Android system name falls back to the model when the configured name is unusable', () async {
    deviceInfo['model'] = '  Pixel 8 Pro  ';
    for (final name in [null, '', '   ', 'LOCALHOST']) {
      deviceInfo['name'] = name;
      expect(await getSystemDeviceName(), 'Pixel 8 Pro', reason: 'name: $name');
    }
  });

  test('Android system name returns no replacement when both name and model are unusable', () async {
    deviceInfo['name'] = '';
    for (final model in ['', '   ', 'localhost']) {
      deviceInfo['model'] = model;
      expect(await getSystemDeviceName(), isNull, reason: 'model: $model');
    }
  });

  test('Android system name returns no replacement when the plugin fails', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await getSystemDeviceName(), isNull);
  });
}
