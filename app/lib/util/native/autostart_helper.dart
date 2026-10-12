import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/linux_autostart.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win32_registry/win32_registry.dart';

export 'linux_autostart.dart' show AutoStartSnapshot;

const startHiddenFlag = '--hidden';
final _logger = Logger('AutoStartHelper');

Future<LinuxAutoStart> _linuxAutoStart() async {
  final info = await PackageInfo.fromPlatform();
  final runtime = File('/.flatpak-info');
  return LinuxAutoStart.resolve(
    environment: Platform.environment,
    executable: Platform.resolvedExecutable,
    packageName: info.packageName,
    appName: info.appName,
    flatpakInfo: runtime.existsSync() ? runtime.readAsStringSync() : null,
  );
}

Future<bool> enableAutoStart({required bool startHidden}) async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
        return (await _linuxAutoStart()).enable(hidden: startHidden);
      case TargetPlatform.macOS:
        await setLaunchAtLogin(true);
        await setLaunchAtLoginMinimized(startHidden);
        return true;
      case TargetPlatform.windows:
        _getWindowsRegistryKey().createValue(
          RegistryValue.string(
            _windowsRegistryKeyValue,
            '"${Platform.resolvedExecutable}"${startHidden ? ' $startHiddenFlag' : ''}',
          ),
        );
        return true;
      default:
        return false;
    }
  } catch (e) {
    _logger.warning('Could not enable auto start', e);
    return false;
  }
}

Future<bool> disableAutoStart() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
        return (await _linuxAutoStart()).disable();
      case TargetPlatform.macOS:
        await setLaunchAtLogin(false);
        break;
      case TargetPlatform.windows:
        _getWindowsRegistryKey().deleteValue(_windowsRegistryKeyValue);
        break;
      default:
        break;
    }
    return true;
  } catch (e) {
    _logger.warning('Could not disable auto start', e);
    return false;
  }
}

Future<AutoStartSnapshot> getAutoStartSnapshot() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
        return (await _linuxAutoStart()).snapshot();
      case TargetPlatform.macOS:
        return AutoStartSnapshot(enabled: await getLaunchAtLogin(), hidden: await getLaunchAtLoginMinimized(), canModify: true);
      case TargetPlatform.windows:
        final value = _getWindowsRegistryKey().getStringValue(_windowsRegistryKeyValue);
        return AutoStartSnapshot(
          enabled: value?.contains(Platform.resolvedExecutable) ?? false,
          hidden: value?.contains(startHiddenFlag) ?? false,
          canModify: true,
        );
      default:
        return const AutoStartSnapshot(enabled: false, hidden: false, canModify: false);
    }
  } catch (e) {
    _logger.warning('Could not read auto start', e);
    return const AutoStartSnapshot(enabled: null, hidden: false, canModify: false);
  }
}

Future<bool> isAutoStartEnabled() async => (await getAutoStartSnapshot()).enabled ?? false;
Future<bool> isAutoStartHidden() async => (await getAutoStartSnapshot()).hidden;

const _windowsRegistryKeyValue = 'LocalSend';

RegistryKey _getWindowsRegistryKey() {
  return Registry.openPath(
    RegistryHive.currentUser,
    path: r'Software\Microsoft\Windows\CurrentVersion\Run',
    desiredAccessRights: AccessRights.allAccess,
  );
}
