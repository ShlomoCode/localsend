import 'dart:io' hide Platform;
class Platform { static bool isIOS = true; }
enum AssetType { image, video }
enum FileType { image, video }
class AssetEntity {
  final File file;
  final int? modifiedDateSecond;
  final AssetType type;
  AssetEntity(this.file, this.modifiedDateSecond, [this.type = AssetType.image]);
  Future<File?> get originFile async => file;
  Future<String> get titleAsync async => 'old-photo.jpg';
}
class Metadata {
  final String? modified;
  final String? accessed;
  Metadata(this.modified, this.accessed);
}
// Native stat seam; metadata serialization does not affect timestamp selection.
Future<Metadata?> readFileMetadata({required String path}) async {
  final stat = await File(path).stat();
  return Metadata(stat.modified.toUtc().toIso8601String(), stat.accessed.toUtc().toIso8601String());
}
class CrossFile {
  final String? lastModified;
  final String? path;
  CrossFile({required String name,required FileType fileType,required int size,Object? thumbnail,Object? asset,this.path,Object? bytes,this.lastModified,String? lastAccessed});
}
class CrossFileConverters {
  static Future<CrossFile> convertAssetEntity(AssetEntity asset) async {
    final file = (await asset.originFile)!;
    final metadata = await readFileMetadata(path: file.path);
    final assetModified = asset.modifiedDateSecond;
    final lastModified = Platform.isIOS && assetModified != null && assetModified > 0
        ? DateTime.fromMillisecondsSinceEpoch(assetModified * 1000, isUtc: true).toIso8601String()
        : metadata?.modified;
    return CrossFile(
      name: await asset.titleAsync,
      fileType: asset.type == AssetType.video ? FileType.video : FileType.image,
      size: await file.length(),
      thumbnail: null,
      asset: asset,
      path: file.path,
      bytes: null,
      lastModified: lastModified,
      lastAccessed: metadata?.accessed,
    );
  }

}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('photo-modified-');
  try {
    final cache = File('${dir.path}/export.jpg');
    await cache.writeAsBytes([255, 216, 255, 217]);
    final stat = await cache.stat();
    final originalDate = DateTime.utc(2020);
    final originalSecond = originalDate.millisecondsSinceEpoch ~/ 1000;
    final converted = await CrossFileConverters.convertAssetEntity(AssetEntity(cache, originalSecond));
    if (DateTime.parse(converted.lastModified!) != originalDate) throw StateError('library modification date lost: ${converted.lastModified}');
    for (final value in [null, 0, -1]) {
      final converted = await CrossFileConverters.convertAssetEntity(AssetEntity(cache, value));
      if (DateTime.parse(converted.lastModified!) != stat.modified.toUtc()) throw StateError('invalid asset date did not fall back to stat');
    }
    Platform.isIOS = false;
    final android = await CrossFileConverters.convertAssetEntity(AssetEntity(cache, originalSecond));
    if (DateTime.parse(android.lastModified!) != stat.modified.toUtc()) throw StateError('Android source stat changed');
    print('PASS library date preserved, unknown/zero/negative fall back, Android unchanged');
  } finally { await dir.delete(recursive: true); }
}
