import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/rust/api/discovery.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/isolate/child/sync_provider.dart';
import 'package:localsend_isolates/src/task/discovery/discovery.dart';
import 'package:refena_flutter/refena_flutter.dart';

// Exercises the real service and sync events at the Rust API boundary.
class RecordingDiscovery implements RsDiscovery {
  final stream = StreamController<RsStoredDevice>();
  final answers = <bool>[];
  int stops = 0;
  int announcements = 0;
  Completer<void>? answerGate;

  @override
  Stream<RsStoredDevice> listen() => stream.stream;
  @override
  Future<String?> multicastError() async => null;
  @override
  Future<void> announce() async => announcements++;
  @override
  Future<void> setAnswerAnnouncements({required bool answer}) async {
    final gate = answerGate;
    answerGate = null;
    if (gate != null) await gate.future;
    answers.add(answer);
  }

  @override
  Future<void> stop() async {
    stops++;
    unawaited(stream.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingApi implements RustLibApi {
  final starts = <Map<Symbol, dynamic>>[];
  final handles = <RecordingDiscovery>[];
  Completer<void>? nextStartGate;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #crateApiDiscoveryStartDiscovery) {
      starts.add(invocation.namedArguments);
      final handle = RecordingDiscovery();
      handles.add(handle);
      final gate = nextStartGate;
      nextStartGate = null;
      if (gate != null) return gate.future.then<RsDiscovery>((_) => handle);
      return Future<RsDiscovery>.value(handle);
    }
    return super.noSuchMethod(invocation);
  }
}

SyncState initialState() => SyncState(
  rootIsolateToken: Object(),
  securityContext: const StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: 'test'),
  deviceInfo: DeviceInfoResult(deviceType: DeviceType.desktop, deviceModel: 'probe', androidSdkInt: null),
  alias: 'Probe',
  port: 53317,
  networkWhitelist: null,
  networkBlacklist: null,
  protocol: ProtocolType.https,
  multicastGroup: '224.0.0.167',
  discoveryTimeout: 500,
  serverRunning: true,
  download: false,
);

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late RecordingApi api;
  late RefenaContainer ref;
  late DiscoveryService service;
  late SyncState state;

  setUpAll(() {
    api = RecordingApi();
    RustLib.initMock(api: api);
  });
  setUp(() async {
    api.starts.clear();
    api.handles.clear();
    state = initialState();
    ref = RefenaContainer(overrides: [syncProvider.overrideWithNotifier((_) => SyncService(initial: state))]);
    service = ref.read(discoveryProvider);
    service.startListener().listen((_) {});
    await settle();
    expect(api.starts, hasLength(1));
  });

  Future<void> update(SyncState next) async {
    state = next;
    ref.redux(syncProvider).dispatch(UpdateSyncStateAction(next));
    await settle();
  }

  test('port follows Stop -> port change -> Start', () async {
    await update(state.copyWith(serverRunning: false));
    await update(state.copyWith(port: 53318, serverRunning: true));
    expect(api.handles.first.answers, [true, false, true]);
    expect(api.starts.last[#port], 53318, reason: 'discovery must advertise the active server port');
  });

  test('protocol follows HTTPS -> HTTP web share', () async {
    await update(state.copyWith(serverRunning: false));
    await update(state.copyWith(protocol: ProtocolType.http, serverRunning: true, download: true));
    expect(api.starts.last[#protocol].toString(), contains('http'));
    expect(api.starts.last[#protocol].toString(), isNot(contains('https')), reason: 'discovery must use the active HTTP server protocol');
    expect(api.starts.last[#download], true);
  });

  test('serverRunning alone toggles answers without restarting discovery', () async {
    await update(state.copyWith(serverRunning: false));
    await update(state.copyWith(serverRunning: true));
    expect(api.starts, hasLength(1));
    expect(api.handles.first.answers, [true, false, true]);
    expect(api.handles.first.stops, 0);
  });

  test('configuration changed during startup is refreshed before announcing', () async {
    final gate = Completer<void>();
    api.nextStartGate = gate;
    await update(state.copyWith(port: 53318));
    expect(api.starts, hasLength(2));
    await update(state.copyWith(port: 53319));
    gate.complete();
    await settle();
    expect(api.starts, hasLength(3));
    expect(api.starts.last[#port], 53319);
    expect(api.handles[1].stops, 1);
    expect(api.handles[1].announcements, 0);
    expect(api.handles.last.announcements, 1);
  });

  test('server started while startup disables answers is reconciled', () async {
    await update(state.copyWith(serverRunning: false));
    final startGate = Completer<void>();
    api.nextStartGate = startGate;
    await update(state.copyWith(port: 53318));
    final starting = api.handles.last;
    final answerGate = Completer<void>();
    starting.answerGate = answerGate;
    startGate.complete();
    await settle();
    await update(state.copyWith(serverRunning: true));
    answerGate.complete();
    await settle();
    expect(starting.answers.last, true);
    expect(starting.announcements, 1);
    expect(api.starts, hasLength(2));
  });
}
