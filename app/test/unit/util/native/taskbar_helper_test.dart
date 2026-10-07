import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('main-delegate-channel');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('coalesces chunk updates without losing percentage changes or new transfers', () async {
    await TaskbarHelper.clearProgressBar();
    calls.clear();

    for (var progress = 1000; progress < 2000; progress++) {
      await TaskbarHelper.setProgressBar(progress, 100000);
    }
    expect(calls.where((call) => call.method == 'updateDockProgress'), hasLength(1));
    expect(calls.last.arguments, 0.01);

    await TaskbarHelper.setProgressBar(2000, 100000);
    expect(calls.last.arguments, 0.02);
    expect(calls.where((call) => call.method == 'updateDockProgress'), hasLength(2));

    await TaskbarHelper.clearProgressBar();
    await TaskbarHelper.setProgressBar(1000, 100000);
    expect(calls.last.arguments, 0.01);
    expect(calls.where((call) => call.method == 'updateDockProgress'), hasLength(4));
  });

  test('unknown total does not divide by zero', () async {
    await TaskbarHelper.setProgressBar(0, 0);
  });
}
