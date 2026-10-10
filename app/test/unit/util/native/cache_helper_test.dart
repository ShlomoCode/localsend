import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:test/test.dart';

void main() {
  test('temporary cache files are deleted before cleanup completes', () async {
    final cacheDir = await Directory.systemTemp.createTemp('localsend-cache-test-');
    addTearDown(() => cacheDir.delete(recursive: true));

    final files = [for (var i = 0; i < 64; i++) File('${cacheDir.path}/$i.tmp')..writeAsStringSync('cached')];
    final subdirectory = await Directory('${cacheDir.path}/keep').create();

    await Isolate.run(() => clearTemporaryCacheFiles(cacheDir));

    expect(files.where((file) => file.existsSync()), isEmpty);
    expect(subdirectory.existsSync(), isTrue);
  });

  test('cleanup waits for directory listing to finish', () async {
    final entries = StreamController<FileSystemEntity>();
    var completed = false;
    final cleanup = clearTemporaryCacheFiles(_ControlledDirectory(entries.stream)).then((_) => completed = true);

    try {
      // An event-loop turn drains microtasks while the listing remains open.
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
    } finally {
      await entries.close();
      await cleanup;
    }
    expect(completed, isTrue);
  });

  test('cleanup waits for file deletion to finish', () async {
    final file = _ControlledFile();
    var completed = false;
    final cleanup = clearTemporaryCacheFiles(_ControlledDirectory(Stream.value(file))).then((_) => completed = true);

    try {
      await file.deleteStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
    } finally {
      file.deleteFinished.complete(file);
      await cleanup;
    }
    expect(completed, isTrue);
  });
}

class _ControlledDirectory implements Directory {
  final Stream<FileSystemEntity> entries;

  _ControlledDirectory(this.entries);

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) => entries;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledFile implements File {
  final deleteStarted = Completer<void>();
  final deleteFinished = Completer<File>();

  @override
  Future<File> delete({bool recursive = false}) {
    deleteStarted.complete();
    return deleteFinished.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
