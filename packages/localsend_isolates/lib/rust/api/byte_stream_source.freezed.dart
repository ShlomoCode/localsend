// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'byte_stream_source.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ByteStreamSource {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ByteStreamSource);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ByteStreamSource()';
}


}

/// @nodoc
class $ByteStreamSourceCopyWith<$Res>  {
$ByteStreamSourceCopyWith(ByteStreamSource _, $Res Function(ByteStreamSource) __);
}


/// Adds pattern-matching-related methods to [ByteStreamSource].
extension ByteStreamSourcePatterns on ByteStreamSource {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ByteStreamSource_Path value)?  path,TResult Function( ByteStreamSource_Bytes value)?  bytes,TResult Function( ByteStreamSource_FileDescriptor value)?  fileDescriptor,TResult Function( ByteStreamSource_Generated value)?  generated,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ByteStreamSource_Path() when path != null:
return path(_that);case ByteStreamSource_Bytes() when bytes != null:
return bytes(_that);case ByteStreamSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that);case ByteStreamSource_Generated() when generated != null:
return generated(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ByteStreamSource_Path value)  path,required TResult Function( ByteStreamSource_Bytes value)  bytes,required TResult Function( ByteStreamSource_FileDescriptor value)  fileDescriptor,required TResult Function( ByteStreamSource_Generated value)  generated,}){
final _that = this;
switch (_that) {
case ByteStreamSource_Path():
return path(_that);case ByteStreamSource_Bytes():
return bytes(_that);case ByteStreamSource_FileDescriptor():
return fileDescriptor(_that);case ByteStreamSource_Generated():
return generated(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ByteStreamSource_Path value)?  path,TResult? Function( ByteStreamSource_Bytes value)?  bytes,TResult? Function( ByteStreamSource_FileDescriptor value)?  fileDescriptor,TResult? Function( ByteStreamSource_Generated value)?  generated,}){
final _that = this;
switch (_that) {
case ByteStreamSource_Path() when path != null:
return path(_that);case ByteStreamSource_Bytes() when bytes != null:
return bytes(_that);case ByteStreamSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that);case ByteStreamSource_Generated() when generated != null:
return generated(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String path)?  path,TResult Function( Uint8List bytes)?  bytes,TResult Function( int fd)?  fileDescriptor,TResult Function( String descriptor)?  generated,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ByteStreamSource_Path() when path != null:
return path(_that.path);case ByteStreamSource_Bytes() when bytes != null:
return bytes(_that.bytes);case ByteStreamSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that.fd);case ByteStreamSource_Generated() when generated != null:
return generated(_that.descriptor);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String path)  path,required TResult Function( Uint8List bytes)  bytes,required TResult Function( int fd)  fileDescriptor,required TResult Function( String descriptor)  generated,}) {final _that = this;
switch (_that) {
case ByteStreamSource_Path():
return path(_that.path);case ByteStreamSource_Bytes():
return bytes(_that.bytes);case ByteStreamSource_FileDescriptor():
return fileDescriptor(_that.fd);case ByteStreamSource_Generated():
return generated(_that.descriptor);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String path)?  path,TResult? Function( Uint8List bytes)?  bytes,TResult? Function( int fd)?  fileDescriptor,TResult? Function( String descriptor)?  generated,}) {final _that = this;
switch (_that) {
case ByteStreamSource_Path() when path != null:
return path(_that.path);case ByteStreamSource_Bytes() when bytes != null:
return bytes(_that.bytes);case ByteStreamSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that.fd);case ByteStreamSource_Generated() when generated != null:
return generated(_that.descriptor);case _:
  return null;

}
}

}

/// @nodoc


class ByteStreamSource_Path extends ByteStreamSource {
  const ByteStreamSource_Path({required this.path}): super._();
  

 final  String path;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ByteStreamSource_PathCopyWith<ByteStreamSource_Path> get copyWith => _$ByteStreamSource_PathCopyWithImpl<ByteStreamSource_Path>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ByteStreamSource_Path&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'ByteStreamSource.path(path: $path)';
}


}

/// @nodoc
abstract mixin class $ByteStreamSource_PathCopyWith<$Res> implements $ByteStreamSourceCopyWith<$Res> {
  factory $ByteStreamSource_PathCopyWith(ByteStreamSource_Path value, $Res Function(ByteStreamSource_Path) _then) = _$ByteStreamSource_PathCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$ByteStreamSource_PathCopyWithImpl<$Res>
    implements $ByteStreamSource_PathCopyWith<$Res> {
  _$ByteStreamSource_PathCopyWithImpl(this._self, this._then);

  final ByteStreamSource_Path _self;
  final $Res Function(ByteStreamSource_Path) _then;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(ByteStreamSource_Path(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ByteStreamSource_Bytes extends ByteStreamSource {
  const ByteStreamSource_Bytes({required this.bytes}): super._();
  

 final  Uint8List bytes;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ByteStreamSource_BytesCopyWith<ByteStreamSource_Bytes> get copyWith => _$ByteStreamSource_BytesCopyWithImpl<ByteStreamSource_Bytes>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ByteStreamSource_Bytes&&const DeepCollectionEquality().equals(other.bytes, bytes));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(bytes));

@override
String toString() {
  return 'ByteStreamSource.bytes(bytes: $bytes)';
}


}

/// @nodoc
abstract mixin class $ByteStreamSource_BytesCopyWith<$Res> implements $ByteStreamSourceCopyWith<$Res> {
  factory $ByteStreamSource_BytesCopyWith(ByteStreamSource_Bytes value, $Res Function(ByteStreamSource_Bytes) _then) = _$ByteStreamSource_BytesCopyWithImpl;
@useResult
$Res call({
 Uint8List bytes
});




}
/// @nodoc
class _$ByteStreamSource_BytesCopyWithImpl<$Res>
    implements $ByteStreamSource_BytesCopyWith<$Res> {
  _$ByteStreamSource_BytesCopyWithImpl(this._self, this._then);

  final ByteStreamSource_Bytes _self;
  final $Res Function(ByteStreamSource_Bytes) _then;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? bytes = null,}) {
  return _then(ByteStreamSource_Bytes(
bytes: null == bytes ? _self.bytes : bytes // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class ByteStreamSource_FileDescriptor extends ByteStreamSource {
  const ByteStreamSource_FileDescriptor({required this.fd}): super._();
  

 final  int fd;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ByteStreamSource_FileDescriptorCopyWith<ByteStreamSource_FileDescriptor> get copyWith => _$ByteStreamSource_FileDescriptorCopyWithImpl<ByteStreamSource_FileDescriptor>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ByteStreamSource_FileDescriptor&&(identical(other.fd, fd) || other.fd == fd));
}


@override
int get hashCode => Object.hash(runtimeType,fd);

@override
String toString() {
  return 'ByteStreamSource.fileDescriptor(fd: $fd)';
}


}

/// @nodoc
abstract mixin class $ByteStreamSource_FileDescriptorCopyWith<$Res> implements $ByteStreamSourceCopyWith<$Res> {
  factory $ByteStreamSource_FileDescriptorCopyWith(ByteStreamSource_FileDescriptor value, $Res Function(ByteStreamSource_FileDescriptor) _then) = _$ByteStreamSource_FileDescriptorCopyWithImpl;
@useResult
$Res call({
 int fd
});




}
/// @nodoc
class _$ByteStreamSource_FileDescriptorCopyWithImpl<$Res>
    implements $ByteStreamSource_FileDescriptorCopyWith<$Res> {
  _$ByteStreamSource_FileDescriptorCopyWithImpl(this._self, this._then);

  final ByteStreamSource_FileDescriptor _self;
  final $Res Function(ByteStreamSource_FileDescriptor) _then;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fd = null,}) {
  return _then(ByteStreamSource_FileDescriptor(
fd: null == fd ? _self.fd : fd // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ByteStreamSource_Generated extends ByteStreamSource {
  const ByteStreamSource_Generated({required this.descriptor}): super._();
  

 final  String descriptor;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ByteStreamSource_GeneratedCopyWith<ByteStreamSource_Generated> get copyWith => _$ByteStreamSource_GeneratedCopyWithImpl<ByteStreamSource_Generated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ByteStreamSource_Generated&&(identical(other.descriptor, descriptor) || other.descriptor == descriptor));
}


@override
int get hashCode => Object.hash(runtimeType,descriptor);

@override
String toString() {
  return 'ByteStreamSource.generated(descriptor: $descriptor)';
}


}

/// @nodoc
abstract mixin class $ByteStreamSource_GeneratedCopyWith<$Res> implements $ByteStreamSourceCopyWith<$Res> {
  factory $ByteStreamSource_GeneratedCopyWith(ByteStreamSource_Generated value, $Res Function(ByteStreamSource_Generated) _then) = _$ByteStreamSource_GeneratedCopyWithImpl;
@useResult
$Res call({
 String descriptor
});




}
/// @nodoc
class _$ByteStreamSource_GeneratedCopyWithImpl<$Res>
    implements $ByteStreamSource_GeneratedCopyWith<$Res> {
  _$ByteStreamSource_GeneratedCopyWithImpl(this._self, this._then);

  final ByteStreamSource_Generated _self;
  final $Res Function(ByteStreamSource_Generated) _then;

/// Create a copy of ByteStreamSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? descriptor = null,}) {
  return _then(ByteStreamSource_Generated(
descriptor: null == descriptor ? _self.descriptor : descriptor // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
