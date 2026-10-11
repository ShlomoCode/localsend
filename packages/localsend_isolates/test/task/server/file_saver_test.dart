import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.localsend.localsend_app/localsend');
  late Directory tempDir;

  setUpAll(() {
    RustLib.initMock(api: _MockRustLibApi());
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_saver_test');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('awaits Android publication before completing a plain-path save', () async {
    final file = File(p.join(tempDir.path, 'received.txt'))..writeAsStringSync('received');
    final started = Completer<void>();
    final scan = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'scanFile');
      expect(call.arguments, {'path': file.path});
      started.complete();
      return scan.future;
    });
    var finished = false;
    final publication = finalizeFileSaveTarget(
      target: FileSaveTarget(path: file.path, fileDescriptor: null, displayPath: file.path),
      androidSdkInt: 30,
      saveToGallery: false,
    ).then((_) => finished = true);

    await started.future;
    expect(finished, isFalse);
    scan.complete(true);
    await publication;
    expect(finished, isTrue);
    expect(file.readAsStringSync(), 'received');
  });

  test('does not scan SAF, gallery cache, or non-Android save targets', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return true;
    });
    final path = p.join(tempDir.path, 'received.txt');
    final plain = FileSaveTarget(path: path, fileDescriptor: null, displayPath: path);
    final saf = FileSaveTarget(path: null, fileDescriptor: 12, displayPath: 'content://documents/received.txt');

    await finalizeFileSaveTarget(target: saf, androidSdkInt: 30, saveToGallery: false);
    await finalizeFileSaveTarget(target: plain, androidSdkInt: 30, saveToGallery: true);
    await finalizeFileSaveTarget(target: plain, androidSdkInt: null, saveToGallery: false);
    expect(calls, 0);
  });

  for (final scanThrows in [false, true]) {
    test('keeps completed bytes when Android publication ${scanThrows ? 'throws' : 'returns no URI'}', () async {
      final file = File(p.join(tempDir.path, 'received.txt'))..writeAsStringSync('received');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        if (scanThrows) throw PlatformException(code: 'SCAN_FAILED');
        return false;
      });

      await finalizeFileSaveTarget(
        target: FileSaveTarget(path: file.path, fileDescriptor: null, displayPath: file.path),
        androidSdkInt: 30,
        saveToGallery: false,
      );
      expect(file.readAsStringSync(), 'received');
    });
  }

  Future<String> digest(String parentDirectory, String fileName) async {
    final (path, _, _) = await digestFilePathAndPrepareDirectory(
      parentDirectory: parentDirectory,
      fileName: fileName,
      createdDirectories: {},
    );
    return path;
  }

  test('creates the destination directory when it does not exist', () async {
    final destination = p.join(tempDir.path, 'gone');
    final path = await digest(destination, 'file.txt');

    expect(Directory(destination).existsSync(), isTrue);
    expect(path, p.join(destination, 'file.txt'));
  });

  test('creates the sub-directories of a folder transfer', () async {
    final path = await digest(tempDir.path, p.join('outer', 'inner', 'file.txt'));

    expect(Directory(p.join(tempDir.path, 'outer', 'inner')).existsSync(), isTrue);
    expect(path, p.join(tempDir.path, 'outer', 'inner', 'file.txt'));
  });

  test('keeps an existing directory and its content', () async {
    File(p.join(tempDir.path, 'file.txt')).writeAsStringSync('hello');

    final path = await digest(tempDir.path, 'file.txt');

    expect(path, p.join(tempDir.path, 'file (2).txt'));
    expect(File(p.join(tempDir.path, 'file.txt')).readAsStringSync(), 'hello');
  });

  test('still rejects path traversal', () async {
    await expectLater(
      digest(tempDir.path, p.join('..', 'escaped', 'file.txt')),
      throwsA('Path traversal detected'),
    );
  });

  test('saves under an alternative name when a directory occupies the incoming name', () async {
    final existingDirectory = Directory(p.join(tempDir.path, 'file.txt'))..createSync();
    final existingContent = File(p.join(existingDirectory.path, 'keep.txt'))..writeAsStringSync('keep');
    final existingFile = File(p.join(tempDir.path, 'file (2).txt'))..writeAsStringSync('existing');

    final path = await digest(tempDir.path, 'file.txt');
    await File(path).writeAsString('received');

    expect(path, p.join(tempDir.path, 'file (3).txt'));
    expect(File(path).readAsStringSync(), 'received');
    expect(existingContent.readAsStringSync(), 'keep');
    expect(existingFile.readAsStringSync(), 'existing');
  });
}

/// The sanitizer lives in the Rust library, which is not loaded in unit tests.
class _MockRustLibApi implements RustLibApi {
  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
