import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _platformChannel = MethodChannel('org.localsend.localsend_app/platform');
bool _isWayland = Platform.environment['XDG_SESSION_TYPE'] == 'wayland';

Future<bool> isWaylandDisplay() async {
  return (await _platformChannel.invokeMethod<bool>('isWayland'))!;
}

void cacheWaylandStatus(bool isWayland) {
  _isWayland = isWayland;
}

bool checkPlatform(List<TargetPlatform> platforms, {bool web = false}) {
  if (web && kIsWeb) {
    return true;
  }
  return platforms.contains(defaultTargetPlatform);
}

bool checkPlatformIsNot(List<TargetPlatform> platforms, {bool web = false}) {
  return !checkPlatform(platforms, web: web);
}

/// This platform runs on a "traditional" computer
bool checkPlatformIsDesktop({TargetPlatform? platform}) {
  return [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS].contains(platform ?? defaultTargetPlatform);
}

/// This platform supports tray
bool checkPlatformHasTray() {
  return !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
}

/// This platform can receive share intents
bool checkPlatformCanReceiveShareIntent() {
  return !kIsWeb && (Platform.isAndroid || Platform.isIOS);
}

/// This platform can select folders
bool checkPlatformWithFolderSelect() {
  return !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isLinux || Platform.isWindows || Platform.isMacOS);
}

/// This platform has a gallery
bool checkPlatformWithGallery() {
  return !kIsWeb && (Platform.isAndroid || Platform.isIOS);
}

/// This platform has access to file system
/// On android, do not allow to change
bool checkPlatformWithFileSystem() {
  return !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isAndroid || Platform.isMacOS);
}

/// Convenience function to check if the app is not running on a Linux device with the Wayland display manager
bool checkPlatformIsNotWaylandDesktop() {
  return kIsWeb || !Platform.isLinux || !_isWayland;
}

/// This platform supports payment (in-app purchase)
bool checkPlatformSupportPayment() {
  return !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
}
