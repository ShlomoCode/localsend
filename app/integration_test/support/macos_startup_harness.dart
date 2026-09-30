import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/main.dart' as app;
import 'package:localsend_app/pages/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gate = MethodChannel('startup-timing-gate');
const _startupTimeout = Duration(seconds: 45);
const _nativeTimeout = Duration(seconds: 15);

class MacosStartupResult {
  const MacosStartupResult({required this.requestObserved, required this.requestError, required this.errorText});

  final bool requestObserved;
  final Object? requestError;
  final String? errorText;
}

/// Runs production startup while native launch completion is held by the harness Runner.
Future<MacosStartupResult> runMacosStartupUnderGate(WidgetTester tester) async {
  await tester.runAsync(() async {
    expect(await _gate.invokeMethod<bool>('waitUntilHeld').timeout(_nativeTimeout), isTrue);

    // The real preferences plugin models an installed app and avoids its first-run query.
    final preferences = await SharedPreferences.getInstance();
    expect(await preferences.setInt('ls_version', 3), isTrue);

    // The test bundle has its own preferences, but an available port also avoids
    // forwarding to an already running production instance on this Mac.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    expect(await preferences.setInt('ls_port', port), isTrue);
  });

  var requestObserved = false;
  Object? requestError;
  late final Future<void> startup;
  try {
    await tester.runAsync(() async {
      final request = _gate
          .invokeMethod<bool>('waitForLoginItemRequest')
          .then((value) {
            requestObserved = value == true;
          })
          .catchError((Object error) {
            requestError = error;
          });

      startup = app.main(<String>[]);

      // Do not pump before release: a frame can wait for the held native reply.
      await Future.any<void>([request, startup]).timeout(_startupTimeout);
    });
  } finally {
    await tester.runAsync(() async {
      await _gate.invokeMethod<void>('release').timeout(_nativeTimeout);
    });
  }

  await tester.runAsync(() async {
    await startup.timeout(_startupTimeout);
  });

  String? errorText;
  await _pumpUntil(tester, () {
    errorText = _renderedErrorText();
    return find.byType(HomePage).evaluate().isNotEmpty || errorText != null;
  });
  return MacosStartupResult(requestObserved: requestObserved, requestError: requestError, errorText: errorText);
}

String? _renderedErrorText() {
  for (final element in find.byType(TextFormField).evaluate()) {
    final field = element.widget as TextFormField;
    final text = field.controller?.text;
    if (text != null && (text.startsWith('Error: ') || text.contains('\n\nError: '))) {
      return text;
    }
  }
  return null;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(_startupTimeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  }
  fail('Startup did not render HomePage or an error screen within $_startupTimeout.');
}
