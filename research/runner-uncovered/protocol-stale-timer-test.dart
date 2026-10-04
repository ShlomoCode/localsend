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

final List<dynamic> cancelMessages = [];

void main() {
  setUp(cancelMessages.clear);
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('old finished receive timer leaves replacement B untouched', (tester) async {
    final f = await mount(tester, SessionStatus.finished);
    f.notifier(serverProvider).closeSession();
    (f.notifier(serverProvider) as FixtureServer).replace('B', SessionStatus.sending);
    f.notifier(fileTransferProvider).setStatus(sessionId: 'B', fileId: 'file', status: FileStatus.sending);
    Routerino.context.pushImmediately(() => const ProgressPage(showAppBar: false, closeSessionOnClose: true, sessionId: 'B'));
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(CancelSessionDialog), findsNothing);
    expect(f.read(serverProvider)!.session!.sessionId, 'B');
    expect(f.read(serverProvider)!.session!.status, SessionStatus.sending);
    expect(find.byType(ProgressPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  testWidgets('own finished receive still auto-finishes', (tester) async {
    final f = await mount(tester, SessionStatus.finished);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(f.read(serverProvider)!.session, isNull);
    expect(find.byType(ProgressPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  testWidgets('own active receive still asks for cancellation', (tester) async {
    final f = await mount(tester, SessionStatus.sending);
    protocolStaleExitHook(tester.state(find.byType(ProgressPage)));
    await tester.pumpAndSettle();
    expect(find.byType(CancelSessionDialog), findsOneWidget);
    Routerino.context.pop(false);
    await tester.pumpAndSettle();
    expect(f.read(serverProvider)!.session!.sessionId, 'A');
    expect(f.read(serverProvider)!.session!.status, SessionStatus.sending);
    expect(find.byType(ProgressPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  testWidgets('own active receive cancellation still reaches its actual controller', (tester) async {
    final f = await mount(tester, SessionStatus.sending);
    protocolStaleExitHook(tester.state(find.byType(ProgressPage)));
    await tester.pumpAndSettle();
    Routerino.context.pop(true);
    await tester.pump();
    expect(f.read(serverProvider)!.session, isNull);
    expect(cancelMessages, hasLength(1));
    expect(cancelMessages.single.data.data.sessionId, 'A');
    expect(find.byType(ProgressPage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });

  testWidgets('confirmation opened for A cannot close replacement B', (tester) async {
    final f = await mount(tester, SessionStatus.sending);
    protocolStaleExitHook(tester.state(find.byType(ProgressPage)));
    await tester.pumpAndSettle();
    expect(find.byType(CancelSessionDialog), findsOneWidget);
    (f.notifier(serverProvider) as FixtureServer).replace('B', SessionStatus.finished);
    Routerino.context.pop(true);
    await tester.pump();
    expect(f.read(serverProvider)!.session!.sessionId, 'B');
    expect(f.read(serverProvider)!.session!.status, SessionStatus.finished);
    expect(find.byType(ProgressPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    f.disposeContainer();
  });
}

Future<RefenaContainer> mount(WidgetTester tester, SessionStatus status) async {
  Routerino.navigatorKey = GlobalKey<NavigatorState>();
  final f = RefenaContainer(
    overrides: [settingsProvider.overrideWithNotifier((_) => _Settings(true)), serverProvider.overrideWithNotifier((_) => FixtureServer(status))],
  );
  f.read(navigationProvider).setKey(Routerino.navigatorKey);
  f
      .notifier(fileTransferProvider)
      .setStatus(sessionId: 'A', fileId: 'file', status: status == SessionStatus.finished ? FileStatus.finished : FileStatus.sending);
  await tester.pumpWidget(
    RefenaScope.withContainer(
      container: f,
      ownsContainer: false,
      child: MaterialApp(
        theme: ThemeData(inputDecorationTheme: const InputDecorationTheme(fillColor: Colors.grey)),
        navigatorKey: Routerino.navigatorKey,
        home: const Scaffold(body: Text('HOME')),
      ),
    ),
  );
  Routerino.context.pushImmediately(() => const ProgressPage(showAppBar: false, closeSessionOnClose: true, sessionId: 'A'));
  await tester.pump();
  await tester.pump();
  return f;
}

class FixtureServer extends ServerService {
  final SessionStatus initialStatus;
  FixtureServer(this.initialStatus);
  @override
  ServerState init() => ServerState(alias: 'receiver', port: 53317, https: false, web: null, session: session('A', initialStatus));
  void replace(String id, SessionStatus status) {
    state = state!.copyWith(session: session(id, status));
  }

  ReceiveSessionState session(String id, SessionStatus status) => ReceiveSessionState(
    sessionId: id,
    status: status,
    sender: Device.empty,
    senderAlias: 'sender',
    files: {
      'file': const ReceivingFile(
        file: FileDto(id: 'file', fileName: 'test.txt', size: 3, fileType: FileType.text, hash: null, preview: null, metadata: null),
        token: 'token',
        desiredName: 'test.txt',
        path: null,
        savedToGallery: false,
        errorMessage: null,
      ),
    },
    startTime: 1000,
    endTime: status == SessionStatus.finished ? 2000 : null,
    destinationDirectory: '/tmp',
    cacheDirectory: '/tmp',
    saveToGallery: false,
    createdDirectories: {},
  );
}

class _UnusedPersistence implements PersistenceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected persistence: ${invocation.memberName}');
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

class FixtureSync implements SyncState {
  @override
  String get alias => 'receiver';
  @override
  int get port => 53317;
  @override
  ProtocolType get protocol => ProtocolType.http;
  @override
  bool get serverRunning => true;
  @override
  bool get download => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected sync use');
}

class FixtureConnector<R, S> implements IsolateConnector<R, S> {
  @override
  void sendToIsolate(S message) {
    cancelMessages.add(message);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected connector use');
}
