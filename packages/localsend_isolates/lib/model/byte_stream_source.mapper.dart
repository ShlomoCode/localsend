// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
// ignore_for_file: type=lint
// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'byte_stream_source.dart';

class ByteStreamSourceMapper extends ClassMapperBase<ByteStreamSource> {
  ByteStreamSourceMapper._();

  static ByteStreamSourceMapper? _instance;
  static ByteStreamSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = ByteStreamSourceMapper._());
      PathByteStreamSourceMapper.ensureInitialized();
      BytesByteStreamSourceMapper.ensureInitialized();
      GeneratedByteStreamSourceMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'ByteStreamSource';

  @override
  final MappableFields<ByteStreamSource> fields = const {};

  static ByteStreamSource _instantiate(DecodingData data) {
    throw MapperException.missingSubclass(
      'ByteStreamSource',
      'type',
      '${data.value['type']}',
    );
  }

  @override
  final Function instantiate = _instantiate;

  static ByteStreamSource fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<ByteStreamSource>(map);
  }

  static ByteStreamSource deserialize(String json) {
    return ensureInitialized().decodeJson<ByteStreamSource>(json);
  }
}

mixin ByteStreamSourceMappable {
  String serialize();
  Map<String, dynamic> toJson();
  ByteStreamSourceCopyWith<ByteStreamSource, ByteStreamSource, ByteStreamSource>
  get copyWith;
}

abstract class ByteStreamSourceCopyWith<$R, $In extends ByteStreamSource, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call();
  ByteStreamSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class PathByteStreamSourceMapper
    extends SubClassMapperBase<PathByteStreamSource> {
  PathByteStreamSourceMapper._();

  static PathByteStreamSourceMapper? _instance;
  static PathByteStreamSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PathByteStreamSourceMapper._());
      ByteStreamSourceMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'PathByteStreamSource';

  static String _$path(PathByteStreamSource v) => v.path;
  static const Field<PathByteStreamSource, String> _f$path = Field(
    'path',
    _$path,
  );

  @override
  final MappableFields<PathByteStreamSource> fields = const {#path: _f$path};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'path';
  @override
  late final ClassMapperBase superMapper =
      ByteStreamSourceMapper.ensureInitialized();

  static PathByteStreamSource _instantiate(DecodingData data) {
    return PathByteStreamSource(data.dec(_f$path));
  }

  @override
  final Function instantiate = _instantiate;

  static PathByteStreamSource fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<PathByteStreamSource>(map);
  }

  static PathByteStreamSource deserialize(String json) {
    return ensureInitialized().decodeJson<PathByteStreamSource>(json);
  }
}

mixin PathByteStreamSourceMappable {
  String serialize() {
    return PathByteStreamSourceMapper.ensureInitialized()
        .encodeJson<PathByteStreamSource>(this as PathByteStreamSource);
  }

  Map<String, dynamic> toJson() {
    return PathByteStreamSourceMapper.ensureInitialized()
        .encodeMap<PathByteStreamSource>(this as PathByteStreamSource);
  }

  PathByteStreamSourceCopyWith<
    PathByteStreamSource,
    PathByteStreamSource,
    PathByteStreamSource
  >
  get copyWith =>
      _PathByteStreamSourceCopyWithImpl<
        PathByteStreamSource,
        PathByteStreamSource
      >(this as PathByteStreamSource, $identity, $identity);
  @override
  String toString() {
    return PathByteStreamSourceMapper.ensureInitialized().stringifyValue(
      this as PathByteStreamSource,
    );
  }

  @override
  bool operator ==(Object other) {
    return PathByteStreamSourceMapper.ensureInitialized().equalsValue(
      this as PathByteStreamSource,
      other,
    );
  }

  @override
  int get hashCode {
    return PathByteStreamSourceMapper.ensureInitialized().hashValue(
      this as PathByteStreamSource,
    );
  }
}

extension PathByteStreamSourceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PathByteStreamSource, $Out> {
  PathByteStreamSourceCopyWith<$R, PathByteStreamSource, $Out>
  get $asPathByteStreamSource => $base.as(
    (v, t, t2) => _PathByteStreamSourceCopyWithImpl<$R, $Out>(v, t, t2),
  );
}

abstract class PathByteStreamSourceCopyWith<
  $R,
  $In extends PathByteStreamSource,
  $Out
>
    implements ByteStreamSourceCopyWith<$R, $In, $Out> {
  @override
  $R call({String? path});
  PathByteStreamSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _PathByteStreamSourceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PathByteStreamSource, $Out>
    implements PathByteStreamSourceCopyWith<$R, PathByteStreamSource, $Out> {
  _PathByteStreamSourceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PathByteStreamSource> $mapper =
      PathByteStreamSourceMapper.ensureInitialized();
  @override
  $R call({String? path}) =>
      $apply(FieldCopyWithData({if (path != null) #path: path}));
  @override
  PathByteStreamSource $make(CopyWithData data) =>
      PathByteStreamSource(data.get(#path, or: $value.path));

  @override
  PathByteStreamSourceCopyWith<$R2, PathByteStreamSource, $Out2>
  $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _PathByteStreamSourceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class BytesByteStreamSourceMapper
    extends SubClassMapperBase<BytesByteStreamSource> {
  BytesByteStreamSourceMapper._();

  static BytesByteStreamSourceMapper? _instance;
  static BytesByteStreamSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = BytesByteStreamSourceMapper._());
      ByteStreamSourceMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'BytesByteStreamSource';

  static List<int> _$bytes(BytesByteStreamSource v) => v.bytes;
  static const Field<BytesByteStreamSource, List<int>> _f$bytes = Field(
    'bytes',
    _$bytes,
  );

  @override
  final MappableFields<BytesByteStreamSource> fields = const {#bytes: _f$bytes};

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'bytes';
  @override
  late final ClassMapperBase superMapper =
      ByteStreamSourceMapper.ensureInitialized();

  static BytesByteStreamSource _instantiate(DecodingData data) {
    return BytesByteStreamSource(data.dec(_f$bytes));
  }

  @override
  final Function instantiate = _instantiate;

  static BytesByteStreamSource fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<BytesByteStreamSource>(map);
  }

  static BytesByteStreamSource deserialize(String json) {
    return ensureInitialized().decodeJson<BytesByteStreamSource>(json);
  }
}

mixin BytesByteStreamSourceMappable {
  String serialize() {
    return BytesByteStreamSourceMapper.ensureInitialized()
        .encodeJson<BytesByteStreamSource>(this as BytesByteStreamSource);
  }

  Map<String, dynamic> toJson() {
    return BytesByteStreamSourceMapper.ensureInitialized()
        .encodeMap<BytesByteStreamSource>(this as BytesByteStreamSource);
  }

  BytesByteStreamSourceCopyWith<
    BytesByteStreamSource,
    BytesByteStreamSource,
    BytesByteStreamSource
  >
  get copyWith =>
      _BytesByteStreamSourceCopyWithImpl<
        BytesByteStreamSource,
        BytesByteStreamSource
      >(this as BytesByteStreamSource, $identity, $identity);
  @override
  String toString() {
    return BytesByteStreamSourceMapper.ensureInitialized().stringifyValue(
      this as BytesByteStreamSource,
    );
  }

  @override
  bool operator ==(Object other) {
    return BytesByteStreamSourceMapper.ensureInitialized().equalsValue(
      this as BytesByteStreamSource,
      other,
    );
  }

  @override
  int get hashCode {
    return BytesByteStreamSourceMapper.ensureInitialized().hashValue(
      this as BytesByteStreamSource,
    );
  }
}

extension BytesByteStreamSourceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, BytesByteStreamSource, $Out> {
  BytesByteStreamSourceCopyWith<$R, BytesByteStreamSource, $Out>
  get $asBytesByteStreamSource => $base.as(
    (v, t, t2) => _BytesByteStreamSourceCopyWithImpl<$R, $Out>(v, t, t2),
  );
}

abstract class BytesByteStreamSourceCopyWith<
  $R,
  $In extends BytesByteStreamSource,
  $Out
>
    implements ByteStreamSourceCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, int, ObjectCopyWith<$R, int, int>> get bytes;
  @override
  $R call({List<int>? bytes});
  BytesByteStreamSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _BytesByteStreamSourceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, BytesByteStreamSource, $Out>
    implements BytesByteStreamSourceCopyWith<$R, BytesByteStreamSource, $Out> {
  _BytesByteStreamSourceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<BytesByteStreamSource> $mapper =
      BytesByteStreamSourceMapper.ensureInitialized();
  @override
  ListCopyWith<$R, int, ObjectCopyWith<$R, int, int>> get bytes => ListCopyWith(
    $value.bytes,
    (v, t) => ObjectCopyWith(v, $identity, t),
    (v) => call(bytes: v),
  );
  @override
  $R call({List<int>? bytes}) =>
      $apply(FieldCopyWithData({if (bytes != null) #bytes: bytes}));
  @override
  BytesByteStreamSource $make(CopyWithData data) =>
      BytesByteStreamSource(data.get(#bytes, or: $value.bytes));

  @override
  BytesByteStreamSourceCopyWith<$R2, BytesByteStreamSource, $Out2>
  $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _BytesByteStreamSourceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

class GeneratedByteStreamSourceMapper
    extends SubClassMapperBase<GeneratedByteStreamSource> {
  GeneratedByteStreamSourceMapper._();

  static GeneratedByteStreamSourceMapper? _instance;
  static GeneratedByteStreamSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(
        _instance = GeneratedByteStreamSourceMapper._(),
      );
      ByteStreamSourceMapper.ensureInitialized().addSubMapper(_instance!);
    }
    return _instance!;
  }

  @override
  final String id = 'GeneratedByteStreamSource';

  static String _$descriptor(GeneratedByteStreamSource v) => v.descriptor;
  static const Field<GeneratedByteStreamSource, String> _f$descriptor = Field(
    'descriptor',
    _$descriptor,
  );

  @override
  final MappableFields<GeneratedByteStreamSource> fields = const {
    #descriptor: _f$descriptor,
  };

  @override
  final String discriminatorKey = 'type';
  @override
  final dynamic discriminatorValue = 'generated';
  @override
  late final ClassMapperBase superMapper =
      ByteStreamSourceMapper.ensureInitialized();

  static GeneratedByteStreamSource _instantiate(DecodingData data) {
    return GeneratedByteStreamSource(data.dec(_f$descriptor));
  }

  @override
  final Function instantiate = _instantiate;

  static GeneratedByteStreamSource fromJson(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<GeneratedByteStreamSource>(map);
  }

  static GeneratedByteStreamSource deserialize(String json) {
    return ensureInitialized().decodeJson<GeneratedByteStreamSource>(json);
  }
}

mixin GeneratedByteStreamSourceMappable {
  String serialize() {
    return GeneratedByteStreamSourceMapper.ensureInitialized()
        .encodeJson<GeneratedByteStreamSource>(
          this as GeneratedByteStreamSource,
        );
  }

  Map<String, dynamic> toJson() {
    return GeneratedByteStreamSourceMapper.ensureInitialized()
        .encodeMap<GeneratedByteStreamSource>(
          this as GeneratedByteStreamSource,
        );
  }

  GeneratedByteStreamSourceCopyWith<
    GeneratedByteStreamSource,
    GeneratedByteStreamSource,
    GeneratedByteStreamSource
  >
  get copyWith =>
      _GeneratedByteStreamSourceCopyWithImpl<
        GeneratedByteStreamSource,
        GeneratedByteStreamSource
      >(this as GeneratedByteStreamSource, $identity, $identity);
  @override
  String toString() {
    return GeneratedByteStreamSourceMapper.ensureInitialized().stringifyValue(
      this as GeneratedByteStreamSource,
    );
  }

  @override
  bool operator ==(Object other) {
    return GeneratedByteStreamSourceMapper.ensureInitialized().equalsValue(
      this as GeneratedByteStreamSource,
      other,
    );
  }

  @override
  int get hashCode {
    return GeneratedByteStreamSourceMapper.ensureInitialized().hashValue(
      this as GeneratedByteStreamSource,
    );
  }
}

extension GeneratedByteStreamSourceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, GeneratedByteStreamSource, $Out> {
  GeneratedByteStreamSourceCopyWith<$R, GeneratedByteStreamSource, $Out>
  get $asGeneratedByteStreamSource => $base.as(
    (v, t, t2) => _GeneratedByteStreamSourceCopyWithImpl<$R, $Out>(v, t, t2),
  );
}

abstract class GeneratedByteStreamSourceCopyWith<
  $R,
  $In extends GeneratedByteStreamSource,
  $Out
>
    implements ByteStreamSourceCopyWith<$R, $In, $Out> {
  @override
  $R call({String? descriptor});
  GeneratedByteStreamSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
    Then<$Out2, $R2> t,
  );
}

class _GeneratedByteStreamSourceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, GeneratedByteStreamSource, $Out>
    implements
        GeneratedByteStreamSourceCopyWith<$R, GeneratedByteStreamSource, $Out> {
  _GeneratedByteStreamSourceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<GeneratedByteStreamSource> $mapper =
      GeneratedByteStreamSourceMapper.ensureInitialized();
  @override
  $R call({String? descriptor}) => $apply(
    FieldCopyWithData({if (descriptor != null) #descriptor: descriptor}),
  );
  @override
  GeneratedByteStreamSource $make(CopyWithData data) =>
      GeneratedByteStreamSource(data.get(#descriptor, or: $value.descriptor));

  @override
  GeneratedByteStreamSourceCopyWith<$R2, GeneratedByteStreamSource, $Out2>
  $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
      _GeneratedByteStreamSourceCopyWithImpl<$R2, $Out2>($value, $cast, t);
}

