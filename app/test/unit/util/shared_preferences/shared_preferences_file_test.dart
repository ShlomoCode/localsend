import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/shared_preferences/shared_preferences_file.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;
  late SharedPreferencesFile store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'localsend-settings-test-',
    );
    file = File('${directory.path}/settings.json');
    store = SharedPreferencesFile(filePath: file.path);
  });

  tearDown(() async => directory.delete(recursive: true));

  test('a settings write yields to the event loop before completing', () async {
    final tick = Completer<void>();
    Timer.run(tick.complete);
    var writeCompleted = false;
    final write = store.setValue('String', 'alias', 'LocalSend').then((value) {
      writeCompleted = true;
      return value;
    });

    await tick.future;
    expect(writeCompleted, isFalse);
    expect(await write, isTrue);
    expect(jsonDecode(await file.readAsString()), {'alias': 'LocalSend'});
  });

  test(
    'overlapping changes persist the final state, including clear',
    () async {
      final writes = [
        store.setValue('String', 'old', 'value'),
        store.setValue('String', 'alias', 'first'),
        store.setValue('String', 'alias', 'last'),
        store.remove('alias'),
        store.clear(),
        store.setValue('String', 'new', 'value'),
      ];

      expect(await Future.wait(writes), everyElement(isTrue));
      expect(await store.getAll(), {'new': 'value'});
      expect(jsonDecode(await file.readAsString()), {'new': 'value'});
    },
  );

  test('a failed write reports the error and permits a later retry', () async {
    await store.setValue('String', 'first', 'value');
    await file.delete();
    await Directory(file.path).create();

    await expectLater(
      store.setValue('String', 'second', 'value'),
      throwsA(isA<FileSystemException>()),
    );
    await Directory(file.path).delete();
    expect(await store.setValue('String', 'third', 'value'), isTrue);
    expect(jsonDecode(await file.readAsString()), {
      'first': 'value',
      'second': 'value',
      'third': 'value',
    });
  });
}
