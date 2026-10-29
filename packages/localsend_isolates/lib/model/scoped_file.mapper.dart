// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'scoped_file.dart';

class ScopedFileMapper extends ClassMapperBase<ScopedFile> {
  ScopedFileMapper._();

  static ScopedFileMapper? _instance;
  static ScopedFileMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ScopedFileMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'ScopedFile';

  static String _$directoryPath(ScopedFile v) => v.directoryPath;
  static const Field<ScopedFile, String> _f$directoryPath = Field(
    'directoryPath',
    _$directoryPath,
  );
  static String _$accessToken(ScopedFile v) => v.accessToken;
  static const Field<ScopedFile, String> _f$accessToken = Field(
    'accessToken',
    _$accessToken,
  );
  static String _$relativePath(ScopedFile v) => v.relativePath;
  static const Field<ScopedFile, String> _f$relativePath = Field(
    'relativePath',
    _$relativePath,
  );

  @override
  final MappableFields<ScopedFile> fields = const {
    #directoryPath: _f$directoryPath,
    #accessToken: _f$accessToken,
    #relativePath: _f$relativePath,
  };

  static ScopedFile _instantiate(DecodingData data) {
    return ScopedFile(
      directoryPath: data.dec(_f$directoryPath),
      accessToken: data.dec(_f$accessToken),
      relativePath: data.dec(_f$relativePath),
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ScopedFile fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ScopedFile>(map);
  }

  static ScopedFile deserialize(String json) {
    return ensureInitialized().decodeJson<ScopedFile>(json);
  }
}

mixin ScopedFileMappable {
  String serialize() {
    return ScopedFileMapper.ensureInitialized().encodeJson<ScopedFile>(
      this as ScopedFile,
    );
  }

  Map<String, dynamic> toJson() {
    return ScopedFileMapper.ensureInitialized().encodeMap<ScopedFile>(
      this as ScopedFile,
    );
  }

  ScopedFileCopyWith<ScopedFile, ScopedFile, ScopedFile> get copyWith =>
      _ScopedFileCopyWithImpl<ScopedFile, ScopedFile>(
        this as ScopedFile,
        $identity,
        $identity,
      );
  @override
  String toString() {
    return ScopedFileMapper.ensureInitialized().stringifyValue(
      this as ScopedFile,
    );
  }

  @override
  bool operator ==(Object other) {
    return ScopedFileMapper.ensureInitialized().equalsValue(
      this as ScopedFile,
      other,
    );
  }

  @override
  int get hashCode {
    return ScopedFileMapper.ensureInitialized().hashValue(this as ScopedFile);
  }
}

extension ScopedFileValueCopy<$R, $Out>
    on ObjectCopyWith<$R, ScopedFile, $Out> {
  ScopedFileCopyWith<$R, ScopedFile, $Out> get $asScopedFile =>
      $base.as((v, t, t2) => _ScopedFileCopyWithImpl<$R, $Out>(v, t, t2));
}

abstract class ScopedFileCopyWith<$R, $In extends ScopedFile, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? directoryPath, String? accessToken, String? relativePath});
  ScopedFileCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _ScopedFileCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, ScopedFile, $Out>
    implements ScopedFileCopyWith<$R, ScopedFile, $Out> {
  _ScopedFileCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<ScopedFile> $mapper =
      ScopedFileMapper.ensureInitialized();
  @override
  $R call({String? directoryPath, String? accessToken, String? relativePath}) =>
      $apply(
        FieldCopyWithData({
          if (directoryPath != null) #directoryPath: directoryPath,
          if (accessToken != null) #accessToken: accessToken,
          if (relativePath != null) #relativePath: relativePath,
        }),
      );
  @override
  ScopedFile $make(CopyWithData data) => ScopedFile(
    directoryPath: data.get(#directoryPath, or: $value.directoryPath),
    accessToken: data.get(#accessToken, or: $value.accessToken),
    relativePath: data.get(#relativePath, or: $value.relativePath),
  );

  @override
  ScopedFileCopyWith<$R2, ScopedFile, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  ) => _ScopedFileCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

