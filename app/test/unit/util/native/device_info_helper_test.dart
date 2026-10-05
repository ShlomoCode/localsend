import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/device_info_helper.dart';
import 'package:localsend_isolates/model/device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('device info uses the host OS when Flutter targets another platform', () async {
    final expectedModel = switch (Platform.operatingSystem) {
      'linux' => 'Linux',
      'macos' => 'macOS',
      'windows' => 'Windows',
      _ => null,
    };
    if (expectedModel == null) return;

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final info = await getDeviceInfo();
      expect(info.deviceType, DeviceType.desktop);
      expect(info.deviceModel, expectedModel);
      expect(info.androidSdkInt, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
