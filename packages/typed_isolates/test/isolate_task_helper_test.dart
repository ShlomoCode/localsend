import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:typed_isolates/typed_isolates.dart';

class _TestConnector implements IsolateConnector<IsolateTaskStreamResult<int>, IsolateTask<String>> {
  final responses = StreamController<IsolateTaskStreamResult<int>>.broadcast(sync: true);

  @override
  Stream<IsolateTaskStreamResult<int>> get receiveFromIsolate => responses.stream;

  @override
  Isolate get isolate => throw UnsupportedError('No child isolate is needed for this stream test');

  @override
  void sendToIsolate(IsolateTask<String> request) {
    if (request.data == 'normal') {
      responses.add(IsolateTaskStreamResult.event(id: request.id, data: 7));
      responses.add(IsolateTaskStreamResult.done(id: request.id));
    } else if (request.data == 'error') {
      responses.add(IsolateTaskStreamResult.error(id: request.id, error: 'child failure'));
    } else if (request.data == 'first') {
      responses.add(IsolateTaskStreamResult.event(id: request.id, data: 7));
    }
  }
}

void main() {
  late _TestConnector connector;

  setUp(() => connector = _TestConnector());
  tearDown(() => connector.responses.close());

  test('normal task delivers data and closes', () async {
    expect(await connector.sendTaskAndListenStream(task: 'normal').toList().timeout(const Duration(seconds: 2)), [7]);
    expect(connector.responses.hasListener, isFalse);
  });

  test('failed task reports its error and closes', () async {
    final errorSeen = Completer<Object>();
    final doneSeen = Completer<void>();
    connector.sendTaskAndListenStream(task: 'error').listen(
          (_) {},
          onError: (Object error) => errorSeen.complete(error),
          onDone: doneSeen.complete,
        );
    expect(await errorSeen.future.timeout(const Duration(seconds: 2)), 'child failure');
    await doneSeen.future.timeout(const Duration(milliseconds: 500));
    expect(connector.responses.hasListener, isFalse);
  });

  test('cancelled consumer releases its response listener', () async {
    final subscription = connector.convertResponseToStream(taskId: 42).listen((_) {});
    expect(connector.responses.hasListener, isTrue);
    await subscription.cancel();
    expect(connector.responses.hasListener, isFalse);
  });

  test('repeated first consumers release their response listeners', () async {
    for (var i = 0; i < 3; i++) {
      expect(await connector.sendTaskAndListenStream(task: 'first').first.timeout(const Duration(seconds: 2)), 7);
      expect(connector.responses.hasListener, isFalse);
    }
  });
}
