import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const originalModified = '2020-01-02T03:04:05.123456789Z';
  const copiedModified = '2026-10-07T00:00:00.987654321Z';
  const originalModifiedSecond = 1577934245;
  final api = _MetadataApi();
  late Directory directory;
  late Directory cache;

  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directory = await Directory.systemTemp.createTemp('localsend-media-timestamp-');
    cache = await Directory('${directory.path}/cache').create();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return cache.path;
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    await directory.delete(recursive: true);
  });

  test('Media cache copies use the original asset modification time', () async {
    // Given a cached copy with a newer modification time than the original file.
    final file = await File('${cache.path}/photo.jpg').writeAsBytes([1, 2, 3]);
    api.modified = copiedModified;
    final asset = _Asset(file, originalModifiedSecond);

    // When converting the selected media to a CrossFile.
    final converted = await CrossFileConverters.convertAssetEntity(asset);

    // Then use the original modification time and keep the cached file's path and size.
    expect(converted.lastModified, '2020-01-02T03:04:05.000Z');
    expect(converted.path, file.path);
    expect(converted.size, 3);
  });

  test('Files in cache-original are outside cache and retain nanosecond precision', () async {
    // Given an original file in cache-original, a sibling of cache, with a timestamp that includes nanoseconds.
    final source = await Directory('${cache.path}-original').create();
    final file = await File('${source.path}/photo.jpg').writeAsBytes([1, 2, 3]);
    api.modified = originalModified;
    final asset = _Asset(file, originalModifiedSecond);

    // When converting the selected media to a CrossFile.
    final converted = await CrossFileConverters.convertAssetEntity(asset);

    // Then keep the file's precise timestamp instead of the asset's whole-second timestamp.
    expect(converted.lastModified, originalModified);
  });

  test('Missing asset modification time preserves the available file timestamp', () async {
    // Given a cached copy whose asset has no original modification time.
    final file = await File('${cache.path}/photo.jpg').writeAsBytes([1, 2, 3]);
    api.modified = copiedModified;
    final asset = _Asset(file, null);

    // When converting the selected media to a CrossFile.
    final converted = await CrossFileConverters.convertAssetEntity(asset);

    // Then keep the cached file's timestamp because the original timestamp is unavailable.
    expect(converted.lastModified, copiedModified);
  });

  test('An original asset modification time of zero is preserved for cached media', () async {
    // Given a cached copy whose original modification time is the Unix epoch (zero seconds).
    final file = await File('${cache.path}/photo.jpg').writeAsBytes([1, 2, 3]);
    api.modified = copiedModified;
    final asset = _Asset(file, 0);

    // When converting the selected media to a CrossFile.
    final converted = await CrossFileConverters.convertAssetEntity(asset);

    // Then use the original timestamp even though its value is zero.
    expect(converted.lastModified, '1970-01-01T00:00:00.000Z');
  });
}

class _Asset extends AssetEntity {
  final File source;

  _Asset(this.source, int? modified) : super(id: '1', typeInt: 1, width: 1, height: 1, title: 'photo.jpg', modifiedDateSecond: modified);

  @override
  Future<File?> get originFile async => source;

  @override
  Future<String> get titleAsync async => title!;
}

class _MetadataApi implements RustLibApi {
  String? modified;

  @override
  Future<rust.FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async {
    return rust.FileMetadata(modified: modified, accessed: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}
