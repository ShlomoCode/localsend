import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_isolates/rust/api/scoped_file.dart';

part 'scoped_file.mapper.dart';

/// Local authority to read one file relative to a user-selected directory.
/// Never included in a protocol DTO.
@MappableClass()
class ScopedFile with ScopedFileMappable {
  final String directoryPath;
  final String accessToken;
  final String relativePath;

  const ScopedFile({required this.directoryPath, required this.accessToken, required this.relativePath});

  RsScopedFile toRust() => RsScopedFile(directoryPath: directoryPath, accessToken: accessToken, relativePath: relativePath);

  @override
  String toString() => 'ScopedFile(relativePath: $relativePath)';
}
