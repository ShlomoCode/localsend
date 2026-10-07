import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:tray_manager/tray_manager.dart' as tm;
import 'package:window_manager/window_manager.dart';

final _logger = Logger('TrayHelper');

enum TrayEntry { open, close }

/// Select a monochrome tray asset that contrasts with the system theme.
String resolveLinuxTrayIcon({required Brightness brightness}) {
  return brightness == Brightness.dark ? Assets.img.logo32White.path : Assets.img.logo32Black.path;
}

Future<void> _setLinuxTrayIcon() async {
  final asset = resolveLinuxTrayIcon(brightness: PlatformDispatcher.instance.platformBrightness);
  var icon = asset;
  if (await File('/.flatpak-info').exists()) {
    // Flatpak's private /app assets are invisible to the host tray. Its own
    // application cache has the same absolute path inside and outside the sandbox.
    icon = 'org.localsend.localsend_app-tray';
    try {
      final cache = await getApplicationCacheDirectory();
      final file = File(path.join(cache.path, 'tray-icons', path.basename(asset)));
      await file.parent.create(recursive: true);
      final bytes = await rootBundle.load(asset);
      await file.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      icon = file.path;
    } catch (e, stack) {
      _logger.warning('Failed to cache Flatpak tray icon; using the exported icon', e, stack);
    }
  }
  _logger.info('Using "$icon" as path of system tray icon');
  await tm.trayManager.setIcon(icon);
}

/// Re-apply the Linux tray icon after OS light/dark changes.
Future<void> updateLinuxTrayIcon() async {
  if (!checkPlatform([TargetPlatform.linux])) {
    return;
  }
  try {
    await _setLinuxTrayIcon();
  } catch (e) {
    _logger.warning('Failed to update tray icon', e);
  }
}

Future<void> initTray() async {
  if (!checkPlatformHasTray()) {
    return;
  }
  try {
    if (checkPlatform([TargetPlatform.windows])) {
      await tm.trayManager.setIcon(Assets.img.logo);
    } else if (checkPlatform([TargetPlatform.macOS])) {
      // The menu bar icon will created in AppDelegate.swift
      return;
    } else if (checkPlatform([TargetPlatform.linux])) {
      await _setLinuxTrayIcon();
    } else {
      await tm.trayManager.setIcon(Assets.img.logo32.path);
    }

    final items = [
      tm.MenuItem(key: TrayEntry.open.name, label: t.tray.open),
      tm.MenuItem(key: TrayEntry.close.name, label: defaultTargetPlatform == TargetPlatform.windows ? t.tray.closeWindows : t.tray.close),
    ];
    await tm.trayManager.setContextMenu(tm.Menu(items: items));
    // No Linux implementation for setToolTip available as of tray_manager 0.2.2
    // https://pub.dev/packages/tray_manager#api
    if (!checkPlatform([TargetPlatform.linux])) {
      await tm.trayManager.setToolTip(t.appName);
    }
  } catch (e) {
    _logger.warning('Failed to init tray', e);
  }
}

Future<void> hideToTray() async {
  await windowManager.hide();
  if (checkPlatform([TargetPlatform.macOS])) {
    // This will crash on Windows
    // https://github.com/localsend/localsend/issues/32
    await windowManager.setSkipTaskbar(true);
  }

  // Disable animations
  try {
    RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => true);
  } catch (e) {
    _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
  }
}

Future<void> showFromTray() async {
  await windowManager.show();
  await windowManager.focus();
  if (checkPlatform([TargetPlatform.macOS])) {
    // This will crash on Windows
    // https://github.com/localsend/localsend/issues/32
    await windowManager.setSkipTaskbar(false);
  }

  // Enable animations
  try {
    RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => false);
  } catch (e) {
    _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
  }
}

Future<void> destroyTray() async {
  if (!checkPlatform([TargetPlatform.linux])) {
    await tm.trayManager.destroy();
  }
}
