import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:test/test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

void main() {
  setUpAll(() {
    RustLib.initMock(api: _MockRustLibApi());
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('uses the iOS asset modification date instead of the exported file date', () async {
    final directory = await Directory.systemTemp.createTemp('cross-file-converters-test-');
    addTearDown(() => directory.delete(recursive: true));
    final exportedFile = File('${directory.path}/photo.jpg');
    await exportedFile.writeAsBytes([1, 2, 3]);

    final modified = DateTime.utc(2020, 8, 15, 10, 20, 30);
    final asset = _FakeAssetEntity(
      exportedFile: exportedFile,
      createDateSecond: DateTime.utc(2019, 1, 2).millisecondsSinceEpoch ~/ 1000,
      modifiedDateSecond: modified.millisecondsSinceEpoch ~/ 1000,
    );

    final converted = await CrossFileConverters.convertAssetEntity(asset);

    expect(converted.lastModified, modified.toIso8601String());
  });

  test('uses the iOS asset creation date when no modification date is available', () async {
    final directory = await Directory.systemTemp.createTemp('cross-file-converters-test-');
    addTearDown(() => directory.delete(recursive: true));
    final exportedFile = File('${directory.path}/photo.jpg');
    await exportedFile.writeAsBytes([1, 2, 3]);

    final created = DateTime.utc(2019, 1, 2, 3, 4, 5);
    final asset = _FakeAssetEntity(
      exportedFile: exportedFile,
      createDateSecond: created.millisecondsSinceEpoch ~/ 1000,
      modifiedDateSecond: 0,
    );

    final converted = await CrossFileConverters.convertAssetEntity(asset);

    expect(converted.lastModified, created.toIso8601String());
  });
}

class _FakeAssetEntity extends AssetEntity {
  final File exportedFile;

  _FakeAssetEntity({
    required this.exportedFile,
    required super.createDateSecond,
    required super.modifiedDateSecond,
  }) : super(
         id: 'photo-id',
         typeInt: 1,
         width: 1,
         height: 1,
         title: 'photo.jpg',
       );

  @override
  Future<File?> get originFile async => exportedFile;

  @override
  Future<String> get titleAsync async => title!;
}

class _MockRustLibApi implements RustLibApi {
  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async {
    return const FileMetadata(
      modified: '2026-09-29T00:00:00Z',
      accessed: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not mocked: ${invocation.memberName}');
}
