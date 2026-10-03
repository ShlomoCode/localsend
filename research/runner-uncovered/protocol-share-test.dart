import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/config/init.dart';
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

// Real private action is called through the same-library test-only seam added
// by protocol-share-apply.py. The route contains the real ProgressPage and the
// notifier inherits the real closeSession business logic.
void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final status in [SessionStatus.finished, SessionStatus.sending, SessionStatus.finishedWithErrors]) {
    testWidgets('new share over actual progress page with $status', (tester) async {
      final fixture = await _mount(tester, status);
      await protocolShareTestHook(fixture, SharedMedia(content: 'new share'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      if (status == SessionStatus.finished) {
        expect(find.byType(ProgressPage), findsNothing);
        expect(fixture.read(sendProvider), isEmpty);
        expect(
          fixture.read(selectedSendingFilesProvider).single.bytes,
          'new share'.codeUnits,
          reason: 'Old completed-session cleanup must run before adding the new share.',
        );
        expect(find.text('SEND TAB'), findsOneWidget);
      } else {
        expect(find.byType(ProgressPage), findsOneWidget);
        expect(fixture.read(sendProvider)['old']!.status, status);
        expect(fixture.read(selectedSendingFilesProvider), hasLength(2));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.disposeContainer();
    });
  }

  testWidgets('removed completed route cancels auto-finish timer before new share', (tester) async {
    final fixture = await _mount(tester, SessionStatus.finished, autoFinish: true);
    await protocolShareTestHook(fixture, SharedMedia(content: 'new share'));
    await tester.pump();
    expect(find.byType(ProgressPage), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(fixture.read(selectedSendingFilesProvider).single.bytes, 'new share'.codeUnits);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.disposeContainer();
  });

  testWidgets('active receive preserves completed send page and queues share', (tester) async {
    final fixture = await _mount(tester, SessionStatus.finished, receiving: true);
    await protocolShareTestHook(fixture, SharedMedia(content: 'new share'));
    await tester.pump();
    expect(find.byType(ProgressPage), findsOneWidget);
    expect(fixture.read(serverProvider)!.session!.status, SessionStatus.sending);
    expect(fixture.read(sendProvider), contains('old'));
    expect(fixture.read(selectedSendingFilesProvider), hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.disposeContainer();
  });

  testWidgets('dialog above completed progress page stays open and share is queued', (tester) async {
    final fixture = await _mount(tester, SessionStatus.finished);
    showDialog<void>(
      context: Routerino.context,
      builder: (_) => const AlertDialog(content: Text('KEEP MODAL')),
    );
    await tester.pumpAndSettle();
    await protocolShareTestHook(fixture, SharedMedia(content: 'new share'));
    await tester.pump();
    expect(find.text('KEEP MODAL'), findsOneWidget);
    expect(fixture.read(sendProvider), contains('old'));
    expect(fixture.read(selectedSendingFilesProvider), hasLength(2));
    await tester.pumpWidget(const SizedBox());
    fixture.disposeContainer();
  });
}

Future<RefenaContainer> _mount(WidgetTester tester, SessionStatus status, {bool receiving = false, bool autoFinish = false}) async {
  Routerino.navigatorKey = GlobalKey<NavigatorState>();
  final fixture = RefenaContainer(
    overrides: [
      settingsProvider.overrideWithNotifier((_) => _Settings(autoFinish)),
      sendProvider.overrideWithNotifier((_) => _Send(status)),
      if (receiving) serverProvider.overrideWithNotifier((_) => _Receiving()),
    ],
  );
  fixture.read(navigationProvider).setKey(Routerino.navigatorKey);
  fixture.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: 'old selection'));
  fixture
      .notifier(fileTransferProvider)
      .setStatus(sessionId: 'old', fileId: 'file', status: status == SessionStatus.finished ? FileStatus.finished : FileStatus.sending);
  await tester.pumpWidget(
    RefenaScope.withContainer(
      container: fixture,
      ownsContainer: false,
      child: MaterialApp(
        navigatorKey: Routerino.navigatorKey,
        home: Scaffold(
          body: PageView(
            controller: fixture.read(homePageControllerProvider).controller,
            children: const [
              Center(child: Text('RECEIVE TAB')),
              Center(child: Text('SEND TAB')),
              SizedBox(),
            ],
          ),
        ),
      ),
    ),
  );
  Routerino.context.pushImmediately(() => const ProgressPage(showAppBar: false, closeSessionOnClose: true, sessionId: 'old'));
  await tester.pump();
  await tester.pump();
  expect(find.byType(ProgressPage), findsOneWidget);
  return fixture;
}

class _Send extends SendNotifier {
  final SessionStatus status;
  _Send(this.status);
  @override
  Map<String, SendSessionState> init() => {
    'old': SendSessionState(
      sessionId: 'old',
      remoteSessionId: 'remote',
      background: false,
      status: status,
      target: Device.empty.copyWith(alias: 'receiver'),
      files: {
        'file': const SendingFile(
          file: FileDto(id: 'file', fileName: 'old.txt', size: 3, fileType: FileType.text, hash: null, preview: null, metadata: null),
          token: 'token',
          thumbnail: null,
          asset: null,
          path: null,
          bytes: [1, 2, 3],
          errorMessage: null,
        ),
      },
      hashedFileCount: 1,
      startTime: 1000,
      endTime: status == SessionStatus.finished ? 2000 : null,
      sendingTasks: [],
      errorMessage: null,
    ),
  };
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

class _Receiving extends ServerService {
  @override
  ServerState? init() => ServerState(
    alias: 'receiver',
    port: 53317,
    https: false,
    web: null,
    session: ReceiveSessionState(
      sessionId: 'receive',
      status: SessionStatus.sending,
      sender: Device.empty,
      senderAlias: 'sender',
      files: {
        'receiving': const ReceivingFile(
          file: FileDto(id: 'receiving', fileName: 'new.txt', size: 3, fileType: FileType.text, hash: null, preview: null, metadata: null),
          token: 'token',
          desiredName: 'new.txt',
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
    ),
  );
}
