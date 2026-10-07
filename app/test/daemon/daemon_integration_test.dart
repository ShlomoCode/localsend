import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/daemon/daemon_app.dart';
import 'package:localsend_app/daemon/daemon_client.dart';

class RealHttpOverrides extends HttpOverrides {}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('Daemon integration state did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final socket = Platform.environment['LOCALSEND_DAEMON_SOCKET'];
  final token = Platform.environment['LOCALSEND_DAEMON_TOKEN_FILE'];
  testWidgets('actual Rust daemon receives after Flutter UI closes and restores completed state', (tester) async {
    final options = DaemonConnectionOptions(socketPath: socket!, tokenFile: token!);
    final client = DaemonClient(options);
    late HttpClient http;
    late Future<Map<String, dynamic>> prepare;
    await tester.runAsync(() async {
      http = HttpOverrides.runWithHttpOverrides(HttpClient.new, RealHttpOverrides());
      unawaited(client.start());
      await waitFor(() => client.connected);
      final port = client.snapshot!.port;
      prepare = () async {
        final request = await http.postUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/prepare-upload'));
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'info': {
              'alias': 'Flutter integration sender',
              'version': '2.2',
              'deviceType': 'desktop',
              'fingerprint': 'TEST-SENDER',
              'port': port,
              'protocol': 'http',
              'download': false,
            },
            'files': {
              'file-1': {'id': 'file-1', 'fileName': 'flutter.txt', 'size': 5, 'fileType': 'text/plain'},
            },
          }),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
      }();
      await waitFor(() => client.snapshot!.receive?.status == 'pending');
    });
    await tester.pumpWidget(DaemonApp(client: client));
    expect(find.text('flutter.txt'), findsOneWidget);
    late Map<String, dynamic> prepared;
    final port = client.snapshot!.port;
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      prepared = await prepare;
      await waitFor(() => client.snapshot!.receive?.status == 'receiving');
    });
    // Dispose the whole Flutter UI before sending any file bytes.
    await tester.pumpWidget(const SizedBox());
    late DaemonClient reopened;
    await tester.runAsync(() async {
      final url = Uri.parse('http://127.0.0.1:$port/api/localsend/v2/upload').replace(
        queryParameters: {
          'sessionId': prepared['sessionId'] as String,
          'fileId': 'file-1',
          'token': (prepared['files'] as Map<String, dynamic>)['file-1'] as String,
        },
      );
      final upload = await http.postUrl(url);
      upload.add(utf8.encode('hello'));
      final result = await upload.close();
      expect(result.statusCode, 200);
      await result.drain<void>();
      reopened = DaemonClient(options);
      unawaited(reopened.start());
      await waitFor(() => reopened.connected && reopened.snapshot!.receive?.status == 'finished');
      final file = reopened.snapshot!.receive!.files.single;
      expect(file.receivedBytes, 5);
      expect(await File(file.path!).readAsString(), 'hello');
      http.close(force: true);
    });
    await tester.pumpWidget(DaemonApp(client: reopened));
    expect(find.text('Transfer complete'), findsOneWidget);
    expect(find.text('flutter.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.isWindows || socket == null || token == null);
}
