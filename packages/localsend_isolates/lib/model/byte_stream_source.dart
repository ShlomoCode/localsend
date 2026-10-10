import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_isolates/rust/api/byte_stream_source.dart' as rust;
import 'package:localsend_isolates/util/android_channel.dart';

part 'byte_stream_source.mapper.dart';

/// A replayable source of bytes that can be sent through an isolate.
@MappableClass(discriminatorKey: 'type')
sealed class ByteStreamSource with ByteStreamSourceMappable {
  const ByteStreamSource();

  const factory ByteStreamSource.file(String path) = PathByteStreamSource;
  const factory ByteStreamSource.bytes(List<int> bytes) = BytesByteStreamSource;
  const factory ByteStreamSource.generated(String descriptor) = GeneratedByteStreamSource;

  String? get path => switch (this) {
    PathByteStreamSource(:final path) => path,
    _ => null,
  };

  List<int>? get bytes => switch (this) {
    BytesByteStreamSource(:final bytes) => bytes,
    _ => null,
  };

  /// Opens Android content URIs afresh, so retries receive a usable descriptor.
  Future<rust.ByteStreamSource> resolve() async => switch (this) {
    PathByteStreamSource(:final path) when path.startsWith('content://') => rust.ByteStreamSource.fileDescriptor(
      fd: await getFileDescriptorAndroid(uri: path),
    ),
    PathByteStreamSource(:final path) => rust.ByteStreamSource.path(path: path),
    BytesByteStreamSource(:final bytes) => rust.ByteStreamSource.bytes(bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes)),
    GeneratedByteStreamSource(:final descriptor) => rust.ByteStreamSource.generated(descriptor: descriptor),
  };

  /// Preserves a native generated source as an isolate-safe Dart value.
  static ByteStreamSource fromRust(rust.ByteStreamSource source) => switch (source) {
    rust.ByteStreamSource_Path(:final path) => ByteStreamSource.file(path),
    rust.ByteStreamSource_Bytes(:final bytes) => ByteStreamSource.bytes(bytes),
    rust.ByteStreamSource_Generated(:final descriptor) => ByteStreamSource.generated(descriptor),
    rust.ByteStreamSource_FileDescriptor() => throw UnsupportedError('An open file descriptor cannot be stored as a replayable source'),
  };
}

@MappableClass(discriminatorValue: 'path')
class PathByteStreamSource extends ByteStreamSource with PathByteStreamSourceMappable {
  @override
  final String path;

  const PathByteStreamSource(this.path);
}

@MappableClass(discriminatorValue: 'bytes')
class BytesByteStreamSource extends ByteStreamSource with BytesByteStreamSourceMappable {
  @override
  final List<int> bytes;

  const BytesByteStreamSource(this.bytes);
}

@MappableClass(discriminatorValue: 'generated')
class GeneratedByteStreamSource extends ByteStreamSource with GeneratedByteStreamSourceMappable {
  final String descriptor;

  const GeneratedByteStreamSource(this.descriptor);
}
