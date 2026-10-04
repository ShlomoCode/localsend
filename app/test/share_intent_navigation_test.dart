import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:share_handler/share_handler.dart';

class _FinishedSendNotifier extends SendNotifier {
  @override
  Map<String, SendSessionState> init() => {
    'previous': const SendSessionState(
      sessionId: 'previous',
      remoteSessionId: null,
      background: false,
      status: SessionStatus.finished,
      target: Device.empty,
      files: {},
      hashedFileCount: 0,
      startTime: null,
      endTime: null,
      sendingTasks: [],
      errorMessage: null,
    ),
  };
}

void main() {
  testWidgets('a new share replaces a finished send screen and its selection', (tester) async {
    final container = RefenaContainer(overrides: [sendProvider.overrideWithNotifier((ref) => _FinishedSendNotifier())]);
    container.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: 'first'));

    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          navigatorKey: container.read(navigationProvider).key,
          home: Scaffold(
            body: PageView(controller: container.read(homePageControllerProvider).controller, children: const [Text('Receive'), Text('Send')]),
          ),
        ),
      ),
    );
    unawaited(
      container.read(navigationProvider).key.currentState!.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Finished')))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Finished'), findsOneWidget);

    await container.global.dispatchAsync(HandleShareIntentAction(payload: SharedMedia(content: 'second')));
    await tester.pumpAndSettle();

    expect(find.text('Finished'), findsNothing);
    expect(find.text('Send'), findsOneWidget);
    expect(container.read(sendProvider), isEmpty);
    expect(container.read(selectedSendingFilesProvider), hasLength(1));
    expect(container.read(selectedSendingFilesProvider).single.bytes, 'second'.codeUnits);
  });
}
