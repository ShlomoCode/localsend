import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localsend_app/pages/home_page.dart';

import 'support/macos_startup_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS opens HomePage when Dart requests login-item state before native launch completes', (tester) async {
    final result = await runMacosStartupUnderGate(tester);

    if (result.errorText != null) {
      // This is the text from `showInitErrorApp`'s `TextFormField` controller.
      // ignore: avoid_print
      print(result.errorText);
      expect(
        result.errorText,
        allOf(contains('MissingPluginException'), contains('isLaunchedAsLoginItem'), contains('main-delegate-channel')),
        reason: 'Startup failed for a reason other than the native channel race.',
      );
    }

    expect(
      find.byType(HomePage),
      findsOneWidget,
      reason:
          'Production startup rendered its error screen instead of HomePage. Native request observed: ${result.requestObserved}. '
          'Native request error: ${result.requestError}. Error screen text: ${result.errorText}',
    );
    expect(result.requestObserved, isTrue, reason: 'The actual isLaunchedAsLoginItem handler was never reached before launch completion.');
    expect(result.errorText, isNull);
  });
}
