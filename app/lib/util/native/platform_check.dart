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

/// Checks the host OS before calling native APIs, independently of Flutter's target platform.
bool checkNativePlatform(List<TargetPlatform> platforms) {
  if (kIsWeb) {
    return false;
  }
  return platforms.any(
    (platform) => switch (platform) {
      TargetPlatform.android => Platform.isAndroid,
      TargetPlatform.iOS => Platform.isIOS,
      TargetPlatform.linux => Platform.isLinux,
      TargetPlatform.macOS => Platform.isMacOS,
      TargetPlatform.windows => Platform.isWindows,
      TargetPlatform.fuchsia => Platform.isFuchsia,
    },
  );
}

/// This platform runs on a "traditional" computer
bool checkPlatformIsDesktop({TargetPlatform? platform}) {
  return [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS].contains(platform ?? defaultTargetPlatform);
}

/// The host OS supports desktop native APIs.
bool checkNativePlatformIsDesktop() {
  return checkNativePlatform([TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]);
}

/// This platform supports tray
bool checkPlatformHasTray() {
  return checkNativePlatform([TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]);
}

/// This platform can receive share intents
bool checkPlatformCanReceiveShareIntent() {
  return checkNativePlatform([TargetPlatform.android, TargetPlatform.iOS]);
}

/// This platform can select folders
bool checkPlatformWithFolderSelect() {
  return checkNativePlatform([TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]);
}

/// This platform has a gallery
bool checkPlatformWithGallery() {
  return checkNativePlatform([TargetPlatform.android, TargetPlatform.iOS]);
}

/// This platform has access to file system
/// On android, do not allow to change
bool checkPlatformWithFileSystem() {
  return checkNativePlatform([TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.android, TargetPlatform.macOS]);
}

/// Convenience function to check if the app is not running on a Linux device with the Wayland display manager
bool checkPlatformIsNotWaylandDesktop() {
  return !checkNativePlatform([TargetPlatform.linux]) || !_isWayland;
}

/// This platform supports payment (in-app purchase)
bool checkPlatformSupportPayment() {
  return checkNativePlatform([TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS]);
}
