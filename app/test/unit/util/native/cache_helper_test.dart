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
}
