import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/util/foreground_service.dart';

void main() {
  testWidgets('Flutter Android override does not start a native foreground service on a non-Android host', (tester) async {
    // Flutter widget tests report Android even on a desktop host. Simulate the
    // same override explicitly so this test remains meaningful if that default changes.
    if (!kIsWeb && Platform.isAndroid) {
      markTestSkipped('Requires a non-Android host');
      return;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    const channel = MethodChannel('flutter_foreground_task/methods');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    try {
      ForegroundService.start(channelName: 'Transfers', title: 'Transfer', text: 'In progress');
      ForegroundService.updateNotification(title: 'Transfer', text: 'Done');
      ForegroundService.stop();
      await tester.pump();

      expect(calls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
