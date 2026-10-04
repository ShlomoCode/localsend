import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/windows_taskbar');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var failNextProgress = false;
  Completer<void>? blockedProgress;
  var failBlockedProgress = false;

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (blockedProgress != null && call.method == 'SetProgress') {
        final blocker = blockedProgress!;
        blockedProgress = null;
        await blocker.future;
        if (failBlockedProgress) {
          failBlockedProgress = false;
          throw PlatformException(code: 'failed');
        }
      }
      if (failNextProgress && call.method == 'SetProgress') {
        failNextProgress = false;
        throw PlatformException(code: 'failed');
      }
      return null;
    });
  });

  setUp(() async {
    await TaskbarHelper.clearProgressBar();
    calls.clear();
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('sends one native update per displayed percentage', () async {
    for (var progress = 1000; progress < 2000; progress++) {
      await TaskbarHelper.setProgressBar(progress, 100000);
    }
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(1));
    expect(calls.last.arguments, {'completed': 1, 'total': 100});

    await TaskbarHelper.setProgressBar(2000, 100000);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(2));
    expect(calls.last.arguments, {'completed': 2, 'total': 100});

    await TaskbarHelper.setProgressBarMode(TaskbarProgressMode.error);
    await TaskbarHelper.setProgressBar(2000, 100000);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(3));
  });

  test('retries the same percentage after a native failure', () async {
    failNextProgress = true;
    await expectLater(TaskbarHelper.setProgressBar(1000, 100000), throwsA(isA<PlatformException>()));
    await TaskbarHelper.setProgressBar(1000, 100000);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(2));
  });

  test('overlapping callers await one failing native update', () async {
    final blocker = Completer<void>();
    blockedProgress = blocker;
    failBlockedProgress = true;
    final first = TaskbarHelper.setProgressBar(1000, 100000);
    final duplicate = TaskbarHelper.setProgressBar(1001, 100000);
    final firstCheck = expectLater(first, throwsA(isA<PlatformException>()));
    final duplicateCheck = expectLater(duplicate, throwsA(isA<PlatformException>()));

    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(1));
    blocker.complete();
    await Future.wait([firstCheck, duplicateCheck]);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(1));

    await TaskbarHelper.setProgressBar(1001, 100000);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(2));
  });

  test('keeps only the latest percentage during an in-flight update', () async {
    final blocker = Completer<void>();
    blockedProgress = blocker;
    final first = TaskbarHelper.setProgressBar(10000, 100000);
    final middle = TaskbarHelper.setProgressBar(11000, 100000);
    final latest = TaskbarHelper.setProgressBar(10000, 100000);

    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(1));
    blocker.complete();
    await Future.wait([first, middle, latest]);
    expect(calls.where((call) => call.method == 'SetProgress'), hasLength(1));
    expect(calls.last.arguments, {'completed': 10, 'total': 100});
  });

  test('zero total uses indeterminate mode', () async {
    await TaskbarHelper.setProgressBar(0, 0);
    expect(calls.last.method, 'SetProgressMode');
    expect(calls.last.arguments, {'mode': TaskbarProgressMode.indeterminate});
  });

  test('unknown total supersedes an in-flight percentage', () async {
    final blocker = Completer<void>();
    blockedProgress = blocker;
    final progress = TaskbarHelper.setProgressBar(1000, 100000);
    final unknown = TaskbarHelper.setProgressBar(0, 0);

    blocker.complete();
    await Future.wait([progress, unknown]);
    expect(calls.last.method, 'SetProgressMode');
    expect(calls.last.arguments, {'mode': TaskbarProgressMode.indeterminate});
  });
}
