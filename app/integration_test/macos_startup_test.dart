import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localsend_app/main.dart' as app;
import 'package:localsend_app/pages/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gate = MethodChannel('startup-timing-gate');
const _startupTimeout = Duration(seconds: 45);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS opens HomePage when Dart requests login-item state before native launch completes', (tester) async {
    // The temporary native gate is installed in this Runner's actual engine.
    await tester.runAsync(() async {
      expect(await _gate.invokeMethod<bool>('waitUntilHeld').timeout(const Duration(seconds: 15)), isTrue);
    });

    // Model an existing installation through the real macOS preferences plugin.
    // A first launch checks reduce-motion settings earlier than the login-item request.
    await tester.runAsync(() async {
      final preferences = await SharedPreferences.getInstance();
      expect(await preferences.setInt('ls_version', 3), isTrue);
    });

    var requestObserved = false;
    Object? requestError;
    late final Future<void> startup;
    String? errorText;
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

        // Run production startup against the real macOS Runner and plugin registry.
        startup = app.main(<String>[]);

        // `app.main` installs the widget tree only after initialization finishes.
        // Pumping before release can wait for a frame that needs this native reply.
        await Future.any<void>([request, startup]).timeout(_startupTimeout);
      });
    } finally {
      // Release even on timeout, so the native launch callback can finish.
      await tester.runAsync(() async {
        await _gate.invokeMethod<void>('release').timeout(const Duration(seconds: 15));
      });
    }

    await tester.runAsync(() async {
      await startup.timeout(_startupTimeout);
    });

    await _pumpUntil(tester, () {
      errorText = _renderedErrorText();
      return find.byType(HomePage).evaluate().isNotEmpty || errorText != null;
    });

    if (errorText != null) {
      // This is the exact text from `showInitErrorApp`'s `TextFormField.controller`.
      // ignore: avoid_print
      print(errorText);
      expect(
        errorText,
        allOf(contains('MissingPluginException'), contains('isLaunchedAsLoginItem'), contains('main-delegate-channel')),
        reason: 'Startup failed for a reason other than the native channel race.',
      );
    }

    expect(
      find.byType(HomePage),
      findsOneWidget,
      reason:
          'Production startup rendered its error screen instead of HomePage. Native request observed: $requestObserved. '
          'Native request error: $requestError. Error screen text: $errorText',
    );
    expect(requestObserved, isTrue, reason: 'The actual isLaunchedAsLoginItem handler was never reached before launch completion.');
    expect(_renderedErrorText(), isNull);
  });
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
    if (condition()) {
      return;
    }
    // Let native channel replies and real OS events run outside the test clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  }
  fail('Startup did not reach the native request, HomePage, or error screen within $_startupTimeout.');
}
