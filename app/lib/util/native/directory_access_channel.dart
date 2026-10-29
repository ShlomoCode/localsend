import 'package:flutter/services.dart';

const _channel = MethodChannel('org.localsend.localsendApp/directory-access');

Future<({String path, String? accessToken})?> getDirectoryAccess() async {
  final result = await _channel.invokeMapMethod<String, dynamic>('getDirectoryAccess');
  if (result == null) return null;
  return (path: result['path'] as String, accessToken: result['accessToken'] as String?);
}

Future<void> releaseDirectoryAccess(String accessToken) {
  return _channel.invokeMethod<void>('releaseDirectoryAccess', {'accessToken': accessToken});
}
