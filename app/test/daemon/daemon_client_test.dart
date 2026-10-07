import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// flutter_test is supplied by the shared workspace SDK test harness.
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/daemon/daemon_app.dart';
import 'package:localsend_app/daemon/daemon_client.dart';

class MockDaemon {
  late Directory directory;
  late ServerSocket server;
  final sockets = <Socket>[];
  final requests = <Map<String, dynamic>>[];
  int revision = 1;
  String status = 'pending';
  String? fileStatus;
  String? runtimeError;
  String sessionId = 'session-1';
  bool stale = false;

  Map<String, dynamic> get snapshot => {
    'revision': revision,
    'port': 53317,
    'error': runtimeError,
    'receive': {
      'session_id': sessionId,
      'sender_alias': 'Sender',
      'sender_fingerprint': 'ABC',
      'status': status,
      'files': [
        {
          'id': 'file-1',
          'name': 'report.txt',
          'size': 20,
          'received_bytes': status == 'finished' ? 20 : 0,
          'status': fileStatus ?? (status == 'pending' ? 'offered' : status),
        },
      ],
    },
  };

  Future<void> start() async {
    directory = await Directory.systemTemp.createTemp('ls-daemon-client-');
    await File('${directory.path}/token').writeAsString('test-token\n');
    server = await ServerSocket.bind(InternetAddress('${directory.path}/socket', type: InternetAddressType.unix), 0);
    server.listen((socket) {
      sockets.add(socket);
      socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        requests.add(request);
        if (request['command'] == 'accept' && !stale) {
          status = 'receiving';
          revision++;
        }
        socket.write(
          '${jsonEncode({
            'version': 1,
            'id': request['id'],
            'ok': !stale || request['command'] == 'watch',
            if (stale && request['command'] != 'watch') 'error': {'code': 'stale_session', 'message': 'Session is no longer current'} else 'snapshot': snapshot,
          })}\n',
        );
      });
    });
  }

  DaemonClient client() => DaemonClient(
    DaemonConnectionOptions(socketPath: '${directory.path}/socket', tokenFile: '${directory.path}/token'),
    reconnectDelay: const Duration(milliseconds: 10),
  );

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
    await directory.delete(recursive: true);
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Daemon state did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('watch reconnects and restores current session after UI transport loss', () async {
    final daemon = MockDaemon();
    await daemon.start();
    final client = daemon.client();
    addTearDown(() async {
      client.dispose();
      await daemon.close();
    });
    unawaited(client.start());
    await until(() => client.connected);
    expect(client.snapshot!.receive!.files.single.name, 'report.txt');
    daemon.status = 'finished';
    daemon.revision++;
    await File('${daemon.directory.path}/token').writeAsString('replacement-token\n');
    daemon.sockets.first.destroy();
    await until(() => daemon.requests.where((r) => r['command'] == 'watch').length == 2 && client.snapshot!.receive!.status == 'finished');
    expect(client.snapshot!.receive!.files.single.receivedBytes, 20);
    expect(daemon.requests.first['token'], 'test-token');
    expect(daemon.requests.last['token'], 'replacement-token');
    expect(daemon.requests.where((r) => r['command'] == 'cancel'), isEmpty);
  }, skip: Platform.isWindows);

  test('stale decision error is surfaced without replacing the current snapshot', () async {
    final daemon = MockDaemon();
    await daemon.start();
    final client = daemon.client();
    addTearDown(() async {
      client.dispose();
      await daemon.close();
    });
    unawaited(client.start());
    await until(() => client.connected);
    daemon.stale = true;
    await expectLater(
      client.command('accept', sessionId: 'old-session'),
      throwsA(isA<DaemonCommandException>().having((e) => e.code, 'code', 'stale_session')),
    );
    expect(client.snapshot!.receive!.sessionId, 'session-1');
    expect(daemon.requests.last['session_id'], 'old-session');
  }, skip: Platform.isWindows);

  testWidgets('accept sends the displayed session ID and shows daemon progress', (tester) async {
    final daemon = MockDaemon();
    await tester.runAsync(daemon.start);
    final client = daemon.client();
    addTearDown(() => tester.runAsync(daemon.close));
    await tester.runAsync(() async {
      unawaited(client.start());
      await until(() => client.connected);
    });
    await tester.pumpWidget(DaemonApp(client: client));
    await tester.pump();
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.text('From Sender'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await until(() => daemon.requests.any((r) => r['command'] == 'accept') && client.snapshot!.receive!.status == 'receiving');
    });
    await tester.pump();
    final accept = daemon.requests.singleWhere((r) => r['command'] == 'accept');
    expect(accept['session_id'], 'session-1');
    expect(find.text('Cancel transfer'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(daemon.requests.where((r) => r['command'] == 'cancel'), isEmpty);
  }, skip: Platform.isWindows);

  testWidgets('runtime error preserves receive decisions and incomplete files are not marked complete', (tester) async {
    final daemon = MockDaemon();
    daemon.runtimeError = 'Multicast unavailable';
    await tester.runAsync(daemon.start);
    final client = daemon.client();
    addTearDown(() => tester.runAsync(daemon.close));
    await tester.runAsync(() async {
      unawaited(client.start());
      await until(() => client.connected);
    });
    await tester.pumpWidget(DaemonApp(client: client));
    expect(find.text('Multicast unavailable'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Accept')).onPressed, isNotNull);
    await tester.runAsync(() async {
      daemon.status = 'finished';
      daemon.fileStatus = 'failed';
      daemon.revision++;
      final watch = daemon.requests.firstWhere((request) => request['command'] == 'watch');
      daemon.sockets.first.write('${jsonEncode({'version': 1, 'id': watch['id'], 'ok': true, 'snapshot': daemon.snapshot})}\n');
      await until(() => client.snapshot!.receive!.status == 'finished');
    });
    await tester.pump();
    expect(find.text('Transfer finished with incomplete files'), findsOneWidget);
    expect(find.text('Transfer complete'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.isWindows);
}
