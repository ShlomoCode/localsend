import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_isolates/model/file_type.dart';

void main() {
  test('retained native selection refreshes growth and shrinkage without losing its send name', () async {
    final directory = await Directory.systemTemp.createTemp('localsend-retained-selection-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes(List.filled(11, 1));
    final selected = CrossFile(
      name: 'renamed/subdirectory.bin',
      fileType: FileType.other,
      size: await source.length(),
      thumbnail: null,
      asset: null,
      path: source.path,
      bytes: null,
      lastModified: '2026-10-11T00:00:00Z',
      lastAccessed: null,
    );

    for (final size in [14, 7]) {
      await source.writeAsBytes(List.filled(size, 2));
      final refreshed = await selected.refreshSize();
      expect(refreshed.size, size);
      expect(refreshed.name, selected.name);
      expect(refreshed.path, selected.path);
      expect(refreshed.lastModified, selected.lastModified);
    }
    expect(selected.size, 11);
  });

  test('memory-backed content keeps its byte size when a different native file exists', () async {
    final directory = await Directory.systemTemp.createTemp('localsend-memory-selection-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes(List.filled(14, 2));
    final selected = CrossFile(
      name: 'message.txt',
      fileType: FileType.text,
      size: 3,
      thumbnail: null,
      asset: null,
      path: source.path,
      bytes: [1, 2, 3],
      lastModified: null,
      lastAccessed: null,
    );

    final refreshed = await selected.refreshSize();
    expect(refreshed.size, selected.bytes!.length);
    expect(refreshed.bytes, selected.bytes);
  });
}
