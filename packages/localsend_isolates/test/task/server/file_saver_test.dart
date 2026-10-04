import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/util/file_path_helper.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late _MockRustLibApi mockApi;

  setUpAll(() {
    mockApi = _MockRustLibApi();
    RustLib.initMock(api: mockApi);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('file_saver_test');
    mockApi.directories.clear();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<String> digest(String parentDirectory, String fileName) async {
    final (path, _, _) = await digestFilePathAndPrepareDirectory(parentDirectory: parentDirectory, fileName: fileName, createdDirectories: {});
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
    await expectLater(digest(tempDir.path, p.join('..', 'escaped', 'file.txt')), throwsA('Path traversal detected'));
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

  test('uses the actual parent for each folder component and limits a long name on a nested volume', () async {
    final longName = '${List.filled(100, '界').join()}.txt'; // 304 UTF-8 bytes but 104 UTF-16 units.
    final path = await digest(tempDir.path, 'nested/$longName');

    expect(mockApi.directories, [tempDir.path, p.join(tempDir.path, 'nested')]);
    expect(p.basename(path), isNot(longName));
    expect(utf8.encode(p.basename(path)).length, lessThanOrEqualTo(255));
    expect(p.dirname(path), p.join(tempDir.path, 'nested'));
  });

  test('numbered collision stays within the component limit and advances the counter', () async {
    final name = '${'a' * 251}.txt';
    final firstPath = await digest(tempDir.path, name);
    File(firstPath).writeAsStringSync('first');
    final secondPath = await digest(tempDir.path, name);
    File(secondPath).writeAsStringSync('second');

    expect(p.basename(secondPath), endsWith(' (2).txt'));
    expect(p.basename(secondPath).length, lessThanOrEqualTo(255));
    expect(secondPath, isNot(firstPath));
  });
}

/// The sanitizer lives in the Rust library, which is not loaded in unit tests.
class _MockRustLibApi implements RustLibApi {
  final directories = <String>[];

  @override
  String crateApiFilenameSanitizeFileName({required String name}) => name;

  @override
  String crateApiFilenameSanitizeFileNameForDirectory({
    required String name,
    required String directory,
    int? counter,
    required bool conservative,
  }) {
    directories.add(directory);
    var result = counter == null ? name : name.withCount(counter);
    // Model a byte-limited mounted directory while the root can accept the
    // same spelling under its Unicode component limit.
    if (directory.endsWith('/nested') && utf8.encode(result).length > 255) {
      final buffer = StringBuffer();
      for (final rune in result.runes) {
        final next = '${buffer.toString()}${String.fromCharCode(rune)}';
        if (utf8.encode(next).length > 255) break;
        buffer.writeCharCode(rune);
      }
      result = buffer.toString();
    } else if (result.length > 255) {
      final ext = p.extension(result);
      final suffix = counter == null ? '' : ' ($counter)';
      result = '${name.substring(0, 255 - suffix.length - ext.length)}$suffix$ext';
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
