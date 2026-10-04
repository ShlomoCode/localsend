import 'package:flutter/material.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

enum TaskbarIcon { regular, error, success }

class TaskbarHelper {
  static final _isWindows = checkPlatform([TargetPlatform.windows]);
  static final _isMacos = checkPlatform([TargetPlatform.macOS]);
  static int? _lastProgressPercent;
  static int? _pendingProgressPercent;
  static Future<void>? _progressUpdate;

  static Future<void> clearProgressBar() async {
    _pendingProgressPercent = null;
    try {
      await _progressUpdate;
    } catch (_) {
      // Clearing the taskbar still needs to run after a failed update.
    }
    _lastProgressPercent = null;
    if (_isWindows) {
      await WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress);
    } else if (_isMacos) {
      await updateDockProgress(1.0);
    }
  }

  static Future<void> setProgressBar(int progress, int total) async {
    if (total <= 0 || total == double.maxFinite.toInt()) {
      _pendingProgressPercent = null;
      _lastProgressPercent = null;
      if (_isWindows) {
        await setProgressBarMode(TaskbarProgressMode.indeterminate);
      }
      return;
    }

    if (!_isWindows && !_isMacos) {
      return;
    }

    // Both taskbar APIs display a percentage. Skip chunk updates until it changes.
    // Scaling also keeps Windows values within its 32-bit progress range.
    final (percent, _) = _scaleRange(progress, total);
    if (_progressUpdate == null && _lastProgressPercent == percent) {
      return;
    }

    // ProgressPage does not await this call. Keep only the latest requested
    // percentage while a native update is in flight, and share its result.
    _pendingProgressPercent = percent;
    return _progressUpdate ??= _flushProgress();
  }

  static Future<void> _flushProgress() async {
    try {
      while (_pendingProgressPercent != null) {
        final percent = _pendingProgressPercent!;
        _pendingProgressPercent = null;
        if (_lastProgressPercent == percent) {
          continue;
        }
        if (_isWindows) {
          await WindowsTaskbar.setProgress(percent, 100);
        } else {
          await updateDockProgress(percent / 100);
        }
        _lastProgressPercent = percent;
      }
    } catch (_) {
      _pendingProgressPercent = null;
      rethrow;
    } finally {
      _progressUpdate = null;
    }
  }

  static Future<void> setProgressBarMode(int mode) async {
    _pendingProgressPercent = null;
    try {
      await _progressUpdate;
    } catch (_) {
      // A mode change supersedes a failed progress update.
    }
    _lastProgressPercent = null;
    if (_isWindows) {
      await WindowsTaskbar.setProgressMode(mode);
    }
  }

  static Future<void> setTaskbarIcon(TaskbarIcon icon) async {
    if (_isMacos) {
      await setDockIcon(icon);
    }
  }

  static Future<void> visualizeStatus(SessionStatus? status) async {
    // macOS handling
    switch (status) {
      case SessionStatus.finished:
        await TaskbarHelper.setTaskbarIcon(TaskbarIcon.success);
        break;
      case SessionStatus.declined:
      case SessionStatus.recipientBusy:
      case SessionStatus.finishedWithErrors:
      case SessionStatus.canceledBySender:
      case SessionStatus.canceledByReceiver:
        await TaskbarHelper.setTaskbarIcon(TaskbarIcon.error);
        break;
      default:
        await TaskbarHelper.setTaskbarIcon(TaskbarIcon.regular);
    }

    // Windows handling
    switch (status) {
      case SessionStatus.waiting:
        await TaskbarHelper.setProgressBarMode(TaskbarProgressMode.indeterminate);
        break;
      case SessionStatus.declined:
      case SessionStatus.recipientBusy:
      case SessionStatus.finishedWithErrors:
      case SessionStatus.canceledBySender:
      case SessionStatus.canceledByReceiver:
        await TaskbarHelper.setProgressBarMode(TaskbarProgressMode.error);
        break;
      default:
        await TaskbarHelper.setProgressBarMode(TaskbarProgressMode.normal);
    }
  }
}

(int, int) _scaleRange(int progress, int total) {
  final percentage = progress / total;
  return ((percentage * 100).toInt(), 100);
}
