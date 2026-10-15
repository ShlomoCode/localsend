import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/pages/debug/discovery_debug_page.dart';
import 'package:localsend_app/pages/debug/http_logs_page.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/logging/http_logs_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  for (final discovery in [true, false]) {
    testWidgets('${discovery ? 'Discovery' : 'HTTP'} copies all current logs with timestamps', (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      final scope = RefenaScope(
        child: MaterialApp(home: discovery ? const DiscoveryDebugPage() : const HttpLogsPage()),
      );
      await tester.pumpWidget(scope);

      final copyButton = find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Copy all logs');
      expect(tester.widget<IconButton>(copyButton).onPressed, isNull);

      if (discovery) {
        scope.notifier(discoveryLoggerProvider).addLog('First entry');
        scope.notifier(discoveryLoggerProvider).addLog('Second entry\nwith details');
      } else {
        scope.notifier(httpLogsProvider).addLog('First entry');
        scope.notifier(httpLogsProvider).addLog('Second entry\nwith details');
      }
      await tester.pump();

      final logs = discovery ? scope.read(discoveryLoggerProvider) : scope.read(httpLogsProvider);
      await tester.tap(copyButton);
      await tester.pumpAndSettle();

      expect(
        clipboard,
        '[${DateFormat.Hms().format(logs[0].timestamp)}] First entry\n'
        '[${DateFormat.Hms().format(logs[1].timestamp)}] Second entry\nwith details',
      );
      expect(find.text(discovery ? 'Copied discovery logs to clipboard' : 'Copied HTTP logs to clipboard'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(tester.widget<IconButton>(copyButton).onPressed, isNull);
    });
  }
}
