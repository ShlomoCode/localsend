import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
// ignore: implementation_imports
import 'package:slang/src/builder/model/enums.dart';
// ignore: implementation_imports
import 'package:slang/src/builder/utils/string_extensions.dart';

Future<DeviceInfoResult> getDeviceInfo() async {
  final plugin = DeviceInfoPlugin();
  final DeviceType deviceType;
  final String? deviceModel;
  int? androidSdkInt;

  if (kIsWeb) {
    deviceType = DeviceType.web;
    final deviceInfo = await plugin.webBrowserInfo;
    deviceModel = deviceInfo.browserName.humanName;
  } else {
    deviceType = checkNativePlatform([TargetPlatform.android, TargetPlatform.iOS]) ? DeviceType.mobile : DeviceType.desktop;

    if (checkNativePlatform([TargetPlatform.android])) {
      final deviceInfo = await plugin.androidInfo;
      deviceModel = deviceInfo.brand.toCase(CaseStyle.pascal);
      androidSdkInt = deviceInfo.version.sdkInt;
    } else if (checkNativePlatform([TargetPlatform.iOS])) {
      final deviceInfo = await plugin.iosInfo;
      deviceModel = deviceInfo.localizedModel;
    } else if (checkNativePlatform([TargetPlatform.linux])) {
      deviceModel = 'Linux';
    } else if (checkNativePlatform([TargetPlatform.macOS])) {
      deviceModel = 'macOS';
    } else if (checkNativePlatform([TargetPlatform.windows])) {
      deviceModel = 'Windows';
    } else {
      deviceModel = 'Fuchsia';
    }
  }

  return DeviceInfoResult(
    deviceType: deviceType,
    deviceModel: deviceModel,
    androidSdkInt: androidSdkInt,
  );
}

extension on BrowserName {
  String? get humanName {
    switch (this) {
      case BrowserName.firefox:
        return 'Firefox';
      case BrowserName.samsungInternet:
        return 'Samsung Internet';
      case BrowserName.opera:
        return 'Opera';
      case BrowserName.msie:
        return 'Internet Explorer';
      case BrowserName.edge:
        return 'Microsoft Edge';
      case BrowserName.chrome:
        return 'Google Chrome';
      case BrowserName.safari:
        return 'Safari';
      case BrowserName.unknown:
        return null;
    }
  }
}
