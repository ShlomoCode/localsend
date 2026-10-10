import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_isolates/rust/api/content_source.dart' as rust;
import 'package:localsend_isolates/util/android_channel.dart';

part 'content_source.mapper.dart';

/// A replayable source of bytes that can be sent through an isolate.
@MappableClass(discriminatorKey: 'type')
sealed class ContentSource with ContentSourceMappable {
  const ContentSource();

  const factory ContentSource.fromPath(String path) = PathContentSource;
  const factory ContentSource.fromBytes(List<int> bytes) = BytesContentSource;
  const factory ContentSource._fromPrepared(String descriptor) = PreparedContentSource;

  String? get path => switch (this) {
    PathContentSource(:final path) => path,
    _ => null,
  };

  List<int>? get bytes => switch (this) {
    BytesContentSource(:final bytes) => bytes,
    _ => null,
  };

  /// Opens Android content URIs afresh, so retries receive a usable descriptor.
  Future<rust.ContentSource> resolve() async => switch (this) {
    PathContentSource(:final path) when path.startsWith('content://') => rust.ContentSource.fileDescriptor(
      fd: await getFileDescriptorAndroid(uri: path),
    ),
    PathContentSource(:final path) => rust.ContentSource.path(path: path),
    BytesContentSource(:final bytes) => rust.ContentSource.bytes(bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes)),
    PreparedContentSource(:final descriptor) => rust.ContentSource.generated(descriptor: descriptor),
  };

  /// Preserves a native generated source as an isolate-safe Dart value.
  static ContentSource fromRust(rust.ContentSource source) => switch (source) {
    rust.ContentSource_Path(:final path) => ContentSource.fromPath(path),
    rust.ContentSource_Bytes(:final bytes) => ContentSource.fromBytes(bytes),
    rust.ContentSource_Generated(:final descriptor) => ContentSource._fromPrepared(descriptor),
    rust.ContentSource_FileDescriptor() => throw UnsupportedError('An open file descriptor cannot be stored as a replayable source'),
  };
}

@MappableClass(discriminatorValue: 'path')
class PathContentSource extends ContentSource with PathContentSourceMappable {
  @override
  final String path;

  const PathContentSource(this.path);
}

@MappableClass(discriminatorValue: 'bytes')
class BytesContentSource extends ContentSource with BytesContentSourceMappable {
  @override
  final List<int> bytes;

  const BytesContentSource(this.bytes);
}

@MappableClass(discriminatorValue: 'generated')
class PreparedContentSource extends ContentSource with PreparedContentSourceMappable {
  final String descriptor;

  const PreparedContentSource(this.descriptor);
}
