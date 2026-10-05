import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:refena_flutter/refena_flutter.dart';

final tvProvider = Provider<bool>((_) => throw Exception('tvProvider not initialized'), debugLabel: 'tvProvider');

/// Returns true, if this device is a TV.
/// Currently, only supports Android TV.
Future<bool> checkIfTv() async {
  if (!kIsWeb && Platform.isAndroid) {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
    return androidInfo.systemFeatures.contains('android.software.leanback');
  } else {
    return false;
  }
}
