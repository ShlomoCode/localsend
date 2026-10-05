import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
// ignore: depend_on_referenced_packages
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/settings_state.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/notification_strings.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:share_handler/share_handler.dart';

import 'mocks.mocks.dart';

class _ShareHandler extends ShareHandlerPlatform {
  final controller = StreamController<SharedMedia>.broadcast(sync: true);

  @override
  Stream<SharedMedia> get sharedMediaStream => controller.stream;
}

class _PurchasePlatform extends InAppPurchasePlatform {
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();
}

class _Server extends ServerService {
  @override
  Future<ServerState?> startServerFromSettings() async => null;
}

class _CancellationToken implements RsCancellationToken {
  @override
  void cancel() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RustApi implements RustLibApi {
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _CancellationToken();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClient implements RsHttpClient {
  List<String> fileIds = [];
  Map<String, String> fileNames = {};
  Set<String> skippedNames = {};
  void Function()? onPrepareUpload;
  int cancelCount = 0;

  @override
  Future<void> cancel({required rust_model.ProtocolType protocol, required String ip, required int port, required String sessionId}) async {
    cancelCount++;
  }

  @override
  Future<PrepareUploadResult> prepareUpload({
    required rust_model.ProtocolType protocol,
    required String ip,
    required int port,
    required rust_model.PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) async {
    fileNames = payload.files.map((id, file) => MapEntry(id, file.fileName));
    fileIds = payload.files.keys.where((id) => !skippedNames.contains(fileNames[id])).toList();
    onPrepareUpload?.call();
    return PrepareUploadResult(
      statusCode: 200,
      response: rust_model.PrepareUploadResponseDto(sessionId: 'remote', files: {for (final id in fileIds) id: 'token'}),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Clients extends HttpClientCollection {
  final _HttpClient client;

  _Clients(this.client) : super(privateKey: '', certificate: '', discovery: client);

  @override
  RsHttpClient pinnedTo(String fingerprint) => client;
}

class _Settings extends SettingsService {
  _Settings(super.persistence);

  @override
  SettingsState init() => _SettingsState();
}

class _SettingsState implements SettingsState {
  @override
  SendMode get sendMode => SendMode.multiple;

  @override
  bool get createChecksums => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ParentState implements ParentIsolateState {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RustApi()));
  tearDownAll(RustLib.dispose);
  for (final scenario in [
    'successful background send',
    'partial transfer',
    'reselected file',
    'closed completed progress',
    'share during upload',
    'cancel after one file',
    'share after one file',
  ]) {
    testWidgets('a new external share after $scenario removes only previously sent selections', (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousShareHandler = ShareHandlerPlatform.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final shareHandler = _ShareHandler();
      ShareHandlerPlatform.instance = shareHandler;
      InAppPurchase.instance;
      final previousPurchasePlatform = InAppPurchasePlatform.instance;
      InAppPurchasePlatform.instance = _PurchasePlatform();
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = previousPlatform;
        ShareHandlerPlatform.instance = previousShareHandler;
        InAppPurchasePlatform.instance = previousPurchasePlatform;
        await shareHandler.controller.close();
      });

      TransferNotification.init(
        NotificationStrings(
          titleReceiving: 'Receiving',
          titleSending: 'Sending',
          remainingTimeMinutes: ({required m, required ss}) => '$m:$ss',
          remainingTimeLong: ({required h, required m}) => '${h}h ${m}m',
        ),
      );
      final client = _HttpClient();
      if (scenario == 'partial transfer') client.skippedNames = {'skipped.txt'};
      final parentState = _ParentState();
      void Function()? onUpload;
      final gated = scenario == 'share during upload' || scenario == 'cancel after one file' || scenario == 'share after one file';
      final uploadListening = Completer<void>();
      final uploadEvents = gated ? StreamController<HttpUploadEvent>(onListen: uploadListening.complete) : null;
      if (uploadEvents != null) {
        addTearDown(() {
          if (!uploadEvents.isClosed) unawaited(uploadEvents.close());
        });
      }
      int cancelTaskCount = 0;
      final persistence = MockPersistenceService();
      when(persistence.isFirstAppStart).thenReturn(true);
      when(persistence.setWhatsNew(any)).thenAnswer((_) async {});
      final container = RefenaContainer(
        overrides: [
          settingsProvider.overrideWithNotifier((ref) => _Settings(persistence)),
          httpProvider.overrideWithBuilder((ref) => _Clients(client)),
          deviceFullInfoProvider.overrideWithBuilder((ref) => Device.empty),
          parentIsolateProvider.overrideWithReducer(
            notifier: (ref) => IsolateController(initialState: parentState),
            reducer: {
              IsolateDiscoveryListenAction: (state) => (state, const Stream<Device>.empty()),
              IsolateHttpUploadCancelAction: (state) {
                cancelTaskCount++;
                return state;
              },
              IsolateHttpUploadFilesAction: (state) {
                onUpload?.call();
                return (
                  state,
                  IsolateHttpUploadActionResult(
                    taskId: 1,
                    events:
                        uploadEvents?.stream ??
                        Stream.fromIterable([
                          for (final id in client.fileIds)
                            if (client.fileNames[id] == 'failed.txt')
                              HttpUploadFileFailedEvent(fileId: id, error: 'receiver disconnected')
                            else
                              HttpUploadFileFinishedEvent(fileId: id),
                        ]),
                  ),
                );
              },
            },
          ),
          serverProvider.overrideWithNotifier((ref) => _Server()),
          persistenceProvider.overrideWithValue(persistence),
          versionProvider.overrideWithFuture((ref) async => VersionData(version: '1.0', buildNumber: '1')),
        ],
      );
      addTearDown(container.disposeContainer);
      container
          .redux(selectedSendingFilesProvider)
          .dispatch(AddBinaryAction(bytes: Uint8List.fromList('first'.codeUnits), fileType: FileType.text, fileName: 'first.txt'));
      if (scenario == 'cancel after one file' || scenario == 'share after one file') {
        container
            .redux(selectedSendingFilesProvider)
            .dispatch(
              AddBinaryAction(bytes: Uint8List.fromList('unfinished'.codeUnits), fileType: FileType.text, fileName: 'unfinished.txt'),
            );
      }
      if (scenario == 'partial transfer') {
        for (final name in ['failed.txt', 'skipped.txt']) {
          container
              .redux(selectedSendingFilesProvider)
              .dispatch(
                AddBinaryAction(bytes: Uint8List.fromList(name.codeUnits), fileType: FileType.text, fileName: name),
              );
        }
      }

      late BuildContext pageContext;
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            navigatorKey: container.read(navigationProvider).key,
            home: Builder(
              builder: (context) {
                pageContext = context;
                return Scaffold(
                  body: PageView(controller: container.read(homePageControllerProvider).controller, children: const [Text('Receive'), Text('Send')]),
                );
              },
            ),
          ),
        ),
      );
      await postInit(pageContext, pageContext.ref, false);
      debugDefaultTargetPlatformOverride = previousPlatform;
      await tester.pumpAndSettle();

      void addUnsentFile() {
        container
            .redux(selectedSendingFilesProvider)
            .dispatch(
              AddBinaryAction(bytes: Uint8List.fromList('unsent'.codeUnits), fileType: FileType.text, fileName: 'unsent.txt'),
            );
      }

      if (scenario == 'closed completed progress') {
        onUpload = () {
          final sessionId = container.read(sendProvider).keys.single;
          container.notifier(sendProvider).setBackground(sessionId, false);
        };
      }
      if (scenario == 'reselected file') {
        client.onPrepareUpload = () {
          addUnsentFile();
          container.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(0));
          container
              .redux(selectedSendingFilesProvider)
              .dispatch(
                AddBinaryAction(bytes: Uint8List.fromList('first'.codeUnits), fileType: FileType.text, fileName: 'first.txt'),
              );
        };
      }
      if (gated) {
        final sending = container
            .notifier(sendProvider)
            .startSession(
              target: Device.empty.copyWith(ip: '127.0.0.1'),
              files: container.read(selectedSendingFilesProvider),
              background: true,
            );
        await uploadListening.future;
        final sessionId = container.read(sendProvider).keys.single;
        expect(container.read(sendProvider)[sessionId]!.status, SessionStatus.sending);
        final firstId = client.fileIds.singleWhere((id) => client.fileNames[id] == 'first.txt');
        if (scenario == 'share during upload') {
          addUnsentFile();
          shareHandler.controller.add(SharedMedia(content: 'second'));
          await tester.pumpAndSettle();
          expect(
            container.read(selectedSendingFilesProvider).map((file) => utf8.decode(file.bytes!)),
            ['first', 'unsent', 'second'],
            reason: 'the new share must be fully handled before the original upload finishes',
          );
          expect(container.read(sendProvider)[sessionId]!.status, SessionStatus.sending);
          uploadEvents!.add(HttpUploadFileFinishedEvent(fileId: firstId));
        } else {
          expect(client.fileIds, hasLength(2));
          uploadEvents!.add(HttpUploadFileFinishedEvent(fileId: firstId));
          await tester.pump();
          expect(container.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: firstId), FileStatus.finished);
          final unfinishedId = client.fileIds.singleWhere((id) => id != firstId);
          expect(container.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: unfinishedId), FileStatus.queue);
          if (scenario == 'share after one file') {
            try {
              shareHandler.controller.add(SharedMedia(content: 'second'));
              await tester.pumpAndSettle();
              expect(container.read(sendProvider)[sessionId]!.status, SessionStatus.sending);
              expect(container.read(fileTransferProvider).getStatus(sessionId: sessionId, fileId: unfinishedId), FileStatus.queue);
              expect(
                container.read(selectedSendingFilesProvider).map((file) => utf8.decode(file.bytes!)),
                ['unfinished', 'second'],
                reason: 'a completed file must be removed by the new share while another file is still queued',
              );
            } finally {
              uploadEvents.add(HttpUploadFileFinishedEvent(fileId: unfinishedId));
              await uploadEvents.close();
              await sending;
            }
            expect(container.read(sendProvider), isEmpty);
            expect(container.read(selectedSendingFilesProvider).map((file) => utf8.decode(file.bytes!)), ['second']);
            return;
          }
          container.notifier(sendProvider).cancelSession(sessionId);
          expect(container.read(sendProvider), isEmpty);
          expect(client.cancelCount, 1);
          expect(cancelTaskCount, 1);
          shareHandler.controller.add(SharedMedia(content: 'second'));
          await tester.pumpAndSettle();
        }
        await uploadEvents.close();
        await sending;
        expect(container.read(sendProvider), isEmpty);
        expect(
          container.read(selectedSendingFilesProvider).map((file) => utf8.decode(file.bytes!)),
          scenario == 'share during upload' ? ['unsent', 'second'] : ['unfinished', 'second'],
        );
        return;
      }
      await container
          .notifier(sendProvider)
          .startSession(
            target: Device.empty.copyWith(ip: '127.0.0.1'),
            files: container.read(selectedSendingFilesProvider),
            background: true,
          );
      expect(client.fileIds, hasLength(scenario == 'partial transfer' ? 2 : 1));
      if (scenario == 'closed completed progress') {
        final completed = container.read(sendProvider).values.single;
        expect(completed.background, false);
        expect(completed.status, SessionStatus.finished);
        container.notifier(sendProvider).closeSession(completed.sessionId);
        expect(container.read(sendProvider), isEmpty);
      } else if (scenario != 'partial transfer') {
        expect(container.read(sendProvider), isEmpty, reason: 'successful background sessions are removed');
      }
      expect(
        container.read(selectedSendingFilesProvider).map((file) => file.name),
        switch (scenario) {
          'partial transfer' => ['first.txt', 'failed.txt', 'skipped.txt'],
          'reselected file' => ['unsent.txt', 'first.txt'],
          _ => ['first.txt'],
        },
        reason: 'Multiple mode keeps files for another recipient until a new share arrives',
      );

      final selectionBeforeEmptyShare = container.read(selectedSendingFilesProvider);
      shareHandler.controller.add(SharedMedia(content: '   '));
      await tester.pumpAndSettle();
      expect(container.read(selectedSendingFilesProvider), selectionBeforeEmptyShare, reason: 'empty shares do not discard repeat-send selections');

      if (scenario != 'reselected file') addUnsentFile();
      shareHandler.controller.add(SharedMedia(content: 'second'));
      await tester.pumpAndSettle();

      expect(
        container.read(selectedSendingFilesProvider).map((file) => utf8.decode(file.bytes!)),
        switch (scenario) {
          'partial transfer' => ['failed.txt', 'skipped.txt', 'unsent', 'second'],
          'reselected file' => ['unsent', 'first', 'second'],
          _ => ['unsent', 'second'],
        },
      );
    });
  }
}
