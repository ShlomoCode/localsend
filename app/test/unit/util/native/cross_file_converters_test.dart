import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:test/test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

const _exportedFileModifiedAt = '2026-09-29T00:00:00Z';

void main() {
  setUpAll(() {
    RustLib.initMock(api: _MockRustLibApi());
  });

  group('CrossFileConverters.convertAssetEntity on iOS', () {
    late Directory temporaryDirectory;
    late File exportedPhoto;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      temporaryDirectory = await Directory.systemTemp.createTemp('cross-file-converters-test-');
      exportedPhoto = File('${temporaryDirectory.path}/photo.jpg');
      await exportedPhoto.writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await temporaryDirectory.delete(recursive: true);
    });

    test('prefers the asset modification date over the exported file date', () async {
      final assetModifiedAt = DateTime.utc(2020, 8, 15, 10, 20, 30);
      final asset = _FakeAssetEntity(
        exportedFile: exportedPhoto,
        createdAt: DateTime.utc(2019, 1, 2),
        modifiedAt: assetModifiedAt,
      );

      final result = await CrossFileConverters.convertAssetEntity(asset);

      expect(result.lastModified, assetModifiedAt.toIso8601String());
    });

    test('falls back to the asset creation date when the modification date is unavailable', () async {
      final assetCreatedAt = DateTime.utc(2019, 1, 2, 3, 4, 5);
      final asset = _FakeAssetEntity(
        exportedFile: exportedPhoto,
        createdAt: assetCreatedAt,
      );

      final result = await CrossFileConverters.convertAssetEntity(asset);

      expect(result.lastModified, assetCreatedAt.toIso8601String());
    });
  });
}

class _FakeAssetEntity extends AssetEntity {
  final File _exportedFile;

  _FakeAssetEntity({
    required File exportedFile,
    required DateTime createdAt,
    DateTime? modifiedAt,
  }) : _exportedFile = exportedFile,
       super(
         id: 'photo-id',
         typeInt: 1,
         width: 1,
         height: 1,
         title: 'photo.jpg',
         createDateSecond: _unixSeconds(createdAt),
         modifiedDateSecond: modifiedAt == null ? 0 : _unixSeconds(modifiedAt),
       );

  @override
  Future<File?> get originFile async => _exportedFile;

  @override
  Future<String> get titleAsync async => title!;
}

class _MockRustLibApi implements RustLibApi {
  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async {
    return const FileMetadata(
      modified: _exportedFileModifiedAt,
      accessed: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}

int _unixSeconds(DateTime dateTime) => dateTime.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
