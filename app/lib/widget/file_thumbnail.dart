import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/util/file_type_ext.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:uri_content/uri_content.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

const double defaultThumbnailSize = 50;
const double _apkThumbnailPadding = 50;

class SmartFileThumbnail extends StatelessWidget {
  final Uint8List? bytes;
  final AssetEntity? asset;
  final String? path;
  final FileType fileType;

  const SmartFileThumbnail({
    required this.bytes,
    required this.asset,
    required this.path,
    required this.fileType,
  });

  factory SmartFileThumbnail.fromCrossFile(CrossFile file) {
    return SmartFileThumbnail(
      bytes: file.thumbnail,
      asset: file.asset,
      path: file.path,
      fileType: file.fileType,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (bytes != null) {
      return MemoryThumbnail(
        bytes: bytes,
        fileType: fileType,
      );
    } else if (asset != null) {
      return AssetThumbnail(
        asset: asset!,
        fileType: fileType,
      );
    } else {
      return FilePathThumbnail(
        path: path,
        fileType: fileType,
      );
    }
  }
}

class AssetThumbnail extends StatelessWidget {
  final AssetEntity asset;
  final FileType fileType;

  const AssetThumbnail({
    required this.asset,
    required this.fileType,
  });

  @override
  Widget build(BuildContext context) {
    return _Thumbnail(
      thumbnail: AssetEntityImage(
        asset,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize.square(64),
        thumbnailFormat: ThumbnailFormat.jpeg,
      ),
      icon: fileType.icon,
    );
  }
}

class FilePathThumbnail extends StatelessWidget {
  final String? path;
  final FileType fileType;

  const FilePathThumbnail({
    required this.path,
    required this.fileType,
  });

  @override
  Widget build(BuildContext context) {
    final Widget? thumbnail;
    if (path != null && fileType == FileType.image) {
      if (path!.startsWith('content://')) {
        thumbnail = Image(
          image: ResizeImage.resizeIfNeeded(
            64,
            null,
            _ContentUriImage(Uri.parse(path!)),
          ),
          errorBuilder: (_, _, _) => Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(fileType.icon, size: 32),
          ),
        );
      } else {
        thumbnail = Image.file(
          File(path!),
          cacheWidth: 64, // reduce memory with low cached size; do not set cacheHeight because the image must keep its ratio
          errorBuilder: (_, _, _) => Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(fileType.icon, size: 32),
          ),
        );
      }
    } else {
      thumbnail = null;
    }

    return _Thumbnail(
      thumbnail: thumbnail,
      icon: fileType.icon,
    );
  }
}

class MemoryThumbnail extends StatelessWidget {
  final Uint8List? bytes;
  final FileType fileType;
  final double size;

  const MemoryThumbnail({
    required this.bytes,
    required this.fileType,
    this.size = defaultThumbnailSize,
  });

  @override
  Widget build(BuildContext context) {
    final Widget? thumbnail;
    if (bytes != null) {
      final padding = fileType == FileType.apk ? _apkThumbnailPadding : 0.0;
      final pixelSize = size * MediaQuery.devicePixelRatioOf(context);
      thumbnail = Padding(
        padding: EdgeInsets.all(padding),
        child: Image(
          // Moving the window between displays can change DPR and require a new decode.
          // Keep the current frame until it is ready; changed bytes reset the Image.
          key: ObjectKey(bytes),
          gaplessPlayback: true,
          image: _ThumbnailMemoryImage(
            bytes!,
            pixelSize: padding == 0 ? pixelSize.ceilToDouble() : pixelSize,
            padding: padding,
          ),
          errorBuilder: (_, _, _) => Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(fileType.icon, size: 32),
          ),
        ),
      );
    } else {
      thumbnail = null;
    }

    return _Thumbnail(
      thumbnail: thumbnail,
      icon: fileType.icon,
      size: size,
    );
  }
}

class _ThumbnailMemoryImage extends MemoryImage {
  final double pixelSize;
  final double padding;

  const _ThumbnailMemoryImage(super.bytes, {required this.pixelSize, this.padding = 0, super.scale});

  @override
  Future<MemoryImage> obtainKey(ImageConfiguration configuration) => padding == 0 ? super.obtainKey(configuration) : _obtainPaddedKey();

  Future<MemoryImage> _obtainPaddedKey() async {
    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    ImageDescriptor? descriptor;
    try {
      descriptor = await ImageDescriptor.encoded(buffer);
      final shortSide = descriptor.width <= descriptor.height ? descriptor.width : descriptor.height;
      final target = (pixelSize * shortSide / (shortSide + 2 * padding)).ceil().clamp(1, shortSide);
      return _ThumbnailMemoryImage(
        bytes,
        pixelSize: target.toDouble(),
        // Keep the original logical size so FittedBox scales the icon and its
        // padding together as it does for the full-resolution image.
        scale: target / shortSide,
      );
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) => (key as _ThumbnailMemoryImage)._load(decode);

  ImageStreamCompleter _load(ImageDecoderCallback decode) {
    return super.loadImage(
      this,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: (width, height) {
          // BoxFit.cover fills the square using the shorter side. Leave the
          // other dimension unset to preserve the aspect ratio during decoding.
          final target = pixelSize.ceil();
          return width <= height ? TargetImageSize(width: target.clamp(1, width)) : TargetImageSize(height: target.clamp(1, height));
        },
      ),
    );
  }

  @override
  bool operator ==(Object other) => other is _ThumbnailMemoryImage && super == other && pixelSize == other.pixelSize && padding == other.padding;

  @override
  int get hashCode => Object.hash(super.hashCode, pixelSize, padding);
}

class _Thumbnail extends StatelessWidget {
  final Widget? thumbnail;
  final IconData? icon;
  final double size;

  const _Thumbnail({
    required this.thumbnail,
    required this.icon,
    this.size = defaultThumbnailSize,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: Theme.of(context).inputDecorationTheme.fillColor!,
          child: thumbnail == null
              ? Icon(icon!, size: 32)
              : FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: thumbnail,
                ),
        ),
      ),
    );
  }
}

class _ContentUriImage extends ImageProvider<Uri> {
  final Uri uri;

  _ContentUriImage(this.uri);

  @override
  Future<Uri> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<Uri>(uri);
  }

  @override
  ImageStreamCompleter loadImage(Uri key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      // ignore: discarded_futures
      codec: _loadAsync(key, decode),
      scale: 1,
      informationCollector: () sync* {
        yield ErrorDescription('ContentUriImage: $uri');
      },
    );
  }

  Future<Codec> _loadAsync(Uri key, ImageDecoderCallback decode) async {
    final bytes = await UriContent().from(key);
    return decode(await ImmutableBuffer.fromUint8List(bytes));
  }
}
