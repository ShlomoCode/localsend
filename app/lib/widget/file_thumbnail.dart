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
      thumbnail = Padding(
        padding: fileType == FileType.apk ? const EdgeInsets.all(_apkThumbnailPadding) : EdgeInsets.zero,
        child: Image(
          image: fileType == FileType.apk
              ? _PaddedThumbnailMemoryImage(
                  bytes!,
                  pixelSize: size * MediaQuery.devicePixelRatioOf(context),
                  padding: _apkThumbnailPadding,
                )
              : _ThumbnailMemoryImage(
                  bytes!,
                  pixelSize: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
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
  final int pixelSize;

  const _ThumbnailMemoryImage(super.bytes, {required this.pixelSize, super.scale});

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    return super.loadImage(key, (buffer, {getTargetSize}) {
      return decode(
        buffer,
        getTargetSize: (width, height) {
          // BoxFit.cover fills the square using the shorter side. Leave the
          // other dimension unset to preserve the aspect ratio during decoding.
          return width <= height ? TargetImageSize(width: pixelSize.clamp(1, width)) : TargetImageSize(height: pixelSize.clamp(1, height));
        },
      );
    });
  }

  @override
  bool operator ==(Object other) => other is _ThumbnailMemoryImage && super == other && pixelSize == other.pixelSize;

  @override
  int get hashCode => Object.hash(super.hashCode, pixelSize);
}

class _PaddedThumbnailMemoryImage extends ImageProvider<_ThumbnailMemoryImage> {
  final Uint8List bytes;
  final double pixelSize;
  final double padding;

  const _PaddedThumbnailMemoryImage(this.bytes, {required this.pixelSize, required this.padding});

  @override
  Future<_ThumbnailMemoryImage> obtainKey(ImageConfiguration configuration) async {
    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    ImageDescriptor? descriptor;
    try {
      descriptor = await ImageDescriptor.encoded(buffer);
      final shortSide = descriptor.width <= descriptor.height ? descriptor.width : descriptor.height;
      final target = (pixelSize * shortSide / (shortSide + 2 * padding)).ceil().clamp(1, shortSide);
      return _ThumbnailMemoryImage(
        bytes,
        pixelSize: target,
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
  ImageStreamCompleter loadImage(_ThumbnailMemoryImage key, ImageDecoderCallback decode) => key.loadImage(key, decode);
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
