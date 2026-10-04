import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/settings_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:share_handler/share_handler.dart';

import 'package:localsend_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:typed_isolates/typed_isolates.dart';

import 'package:localsend_app/gen/strings.g.dart';

void main() {
  for (final otherReceive in [false, true]) {
    progressTest(
      'outgoing progress uses its own title and files; unrelated receive=$otherReceive',
      (tester) async {
        final f = await mount(tester, outgoing: true, receive: otherReceive);
        expect(find.text(t.progressPage.titleSending), findsOneWidget);
        expect(find.text('outgoing.txt'), findsOneWidget);
        expect(find.text('incoming.txt'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        f.disposeContainer();
      },
    );
  }

  progressTest('own receiving progress retains incoming title and files', (
    tester,
  ) async {
    final f = await mount(tester, outgoing: false, receive: true);
    expect(find.text(t.progressPage.titleReceiving), findsOneWidget);
    expect(find.text('incoming.txt'), findsOneWidget);
    expect(find.text('outgoing.txt'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  progressTest(
    'opening incoming progress retains a mounted outgoing progress route safely',
    (tester) async {
      final f = await mount(tester, outgoing: true, receive: false);
      (f.notifier(serverProvider) as FixtureServer).setReceive(true);
      Routerino.context.pushImmediately(
        () => const ProgressPage(
          showAppBar: false,
          closeSessionOnClose: true,
          sessionId: 'R',
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProgressPage, skipOffstage: false), findsNWidgets(2));
      expect(find.text(t.progressPage.titleReceiving), findsOneWidget);
      expect(
        find.text(t.progressPage.titleSending, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('incoming.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      f.disposeContainer();
    },
  );

  progressTest(
    'a replaced receive route cannot dismiss the new receive progress route',
    (tester) async {
      final f = await mount(tester, outgoing: false, receive: true);
      (f.notifier(serverProvider) as FixtureServer).setReceive(
        true,
        sessionId: 'B',
      );
      f
          .notifier(fileTransferProvider)
          .setStatus(
            sessionId: 'B',
            fileId: 'incoming',
            status: FileStatus.sending,
          );
      Routerino.context.pushImmediately(
        () => const ProgressPage(
          showAppBar: false,
          closeSessionOnClose: true,
          sessionId: 'B',
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.read(serverProvider)!.session!.sessionId, 'B');
      expect(find.byType(ProgressPage), findsOneWidget);
      expect(
        (tester.widget(find.byType(ProgressPage)) as ProgressPage).sessionId,
        'B',
      );
      expect(find.text(t.progressPage.titleReceiving), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      f.disposeContainer();
    },
  );

  progressTest('a removed own current receive route still returns home', (
    tester,
  ) async {
    final f = await mount(tester, outgoing: false, receive: true);
    (f.notifier(serverProvider) as FixtureServer).setReceive(false);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProgressPage), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  progressTest(
    'an incoming transfer cannot relabel an already open outgoing page',
    (tester) async {
      final f = await mount(tester, outgoing: true, receive: false);
      expect(find.text(t.progressPage.titleSending), findsOneWidget);
      (f.notifier(serverProvider) as FixtureServer).setReceive(true);
      await tester.pump();
      expect(find.text(t.progressPage.titleSending), findsOneWidget);
      expect(find.text(t.progressPage.titleReceiving), findsNothing);
      expect(find.text('outgoing.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      f.disposeContainer();
    },
  );
}

void progressTest(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<RefenaContainer> mount(
  WidgetTester tester, {
  required bool outgoing,
  required bool receive,
}) async {
  Routerino.navigatorKey = GlobalKey<NavigatorState>();
  final f = RefenaContainer(
    overrides: [
      settingsProvider.overrideWithNotifier((_) => _Settings(false)),
      serverProvider.overrideWithNotifier((_) => FixtureServer(receive)),
      sendProvider.overrideWithNotifier((_) => FixtureSend(outgoing)),
    ],
  );
  f.read(navigationProvider).setKey(Routerino.navigatorKey);
  for (final entry in {'S': 'outgoing', 'R': 'incoming'}.entries) {
    f
        .notifier(fileTransferProvider)
        .setStatus(
          sessionId: entry.key,
          fileId: entry.value,
          status: FileStatus.sending,
        );
  }
  await tester.pumpWidget(
    RefenaScope.withContainer(
      container: f,
      ownsContainer: false,
      child: MaterialApp(
        theme: ThemeData(
          inputDecorationTheme: const InputDecorationTheme(
            fillColor: Colors.grey,
          ),
        ),
        navigatorKey: Routerino.navigatorKey,
        home: const Scaffold(body: Text('HOME')),
      ),
    ),
  );
  Routerino.context.pushImmediately(
    () => ProgressPage(
      showAppBar: false,
      closeSessionOnClose: true,
      sessionId: outgoing ? 'S' : 'R',
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return f;
}

const outgoingFile = FileDto(
  id: 'outgoing',
  fileName: 'outgoing.txt',
  size: 30,
  fileType: FileType.text,
  hash: null,
  preview: null,
  metadata: null,
);
const incomingFile = FileDto(
  id: 'incoming',
  fileName: 'incoming.txt',
  size: 3,
  fileType: FileType.text,
  hash: null,
  preview: null,
  metadata: null,
);

class FixtureSend extends SendNotifier {
  final bool outgoing;
  FixtureSend(this.outgoing);
  @override
  Map<String, SendSessionState> init() => outgoing
      ? {
          'S': SendSessionState(
            sessionId: 'S',
            remoteSessionId: 'remote-S',
            background: false,
            status: SessionStatus.sending,
            target: Device.empty,
            files: {
              'outgoing': const SendingFile(
                file: outgoingFile,
                token: 'token',
                thumbnail: null,
                asset: null,
                path: null,
                bytes: null,
                errorMessage: null,
              ),
            },
            hashedFileCount: 1,
            startTime: 1000,
            endTime: null,
            sendingTasks: [],
            errorMessage: null,
          ),
        }
      : {};
}

class FixtureServer extends ServerService {
  final bool receive;
  FixtureServer(this.receive);
  @override
  ServerState init() => ServerState(
    alias: 'receiver',
    port: 53317,
    https: false,
    web: null,
    session: receive ? incoming : null,
  );
  void setReceive(bool enabled, {String sessionId = 'R'}) {
    state = state!.copyWith(
      session: enabled ? incoming.copyWith(sessionId: sessionId) : null,
    );
  }

  ReceiveSessionState get incoming => ReceiveSessionState(
    sessionId: 'R',
    status: SessionStatus.sending,
    sender: Device.empty,
    senderAlias: 'sender',
    files: {
      'incoming': const ReceivingFile(
        file: incomingFile,
        token: 'token',
        desiredName: 'incoming.txt',
        path: null,
        savedToGallery: false,
        errorMessage: null,
      ),
    },
    startTime: 1000,
    endTime: null,
    destinationDirectory: '/tmp',
    cacheDirectory: '/tmp',
    saveToGallery: false,
    createdDirectories: {},
  );
}

class _UnusedPersistence implements PersistenceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected persistence: ${invocation.memberName}',
  );
}

class _Settings extends SettingsService {
  final bool autoFinish;
  _Settings(this.autoFinish) : super(_UnusedPersistence());
  @override
  SettingsState init() => SettingsState(
    showToken: '',
    alias: 'sender',
    theme: ThemeMode.system,
    colorMode: ColorMode.localsend,
    customColor: Colors.blue,
    locale: null,
    port: 53317,
    networkWhitelist: null,
    networkBlacklist: null,
    multicastGroup: '224.0.0.167',
    destination: null,
    saveToGallery: false,
    saveToHistory: false,
    quickSave: false,
    quickSaveFromFavorites: false,
    receivePin: null,
    autoFinish: autoFinish,
    minimizeToTray: false,
    https: false,
    sendMode: SendMode.single,
    saveWindowPlacement: false,
    alwaysOnTop: false,
    enableAnimations: false,
    deviceType: null,
    deviceModel: null,
    shareViaLinkAutoAccept: false,
    receiveViaLinkAutoAccept: false,
    createChecksums: false,
    verifyChecksums: false,
    discoveryTimeout: 100,
    advancedSettings: false,
  );
}
