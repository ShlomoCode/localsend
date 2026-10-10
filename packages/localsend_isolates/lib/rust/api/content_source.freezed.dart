// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'content_source.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ContentSource {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSource);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ContentSource()';
}


}

/// @nodoc
class $ContentSourceCopyWith<$Res>  {
$ContentSourceCopyWith(ContentSource _, $Res Function(ContentSource) __);
}


/// Adds pattern-matching-related methods to [ContentSource].
extension ContentSourcePatterns on ContentSource {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ContentSource_Path value)?  path,TResult Function( ContentSource_Bytes value)?  bytes,TResult Function( ContentSource_FileDescriptor value)?  fileDescriptor,TResult Function( ContentSource_Generated value)?  generated,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ContentSource_Path() when path != null:
return path(_that);case ContentSource_Bytes() when bytes != null:
return bytes(_that);case ContentSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that);case ContentSource_Generated() when generated != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ContentSource_Path value)  path,required TResult Function( ContentSource_Bytes value)  bytes,required TResult Function( ContentSource_FileDescriptor value)  fileDescriptor,required TResult Function( ContentSource_Generated value)  generated,}){
final _that = this;
switch (_that) {
case ContentSource_Path():
return path(_that);case ContentSource_Bytes():
return bytes(_that);case ContentSource_FileDescriptor():
return fileDescriptor(_that);case ContentSource_Generated():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ContentSource_Path value)?  path,TResult? Function( ContentSource_Bytes value)?  bytes,TResult? Function( ContentSource_FileDescriptor value)?  fileDescriptor,TResult? Function( ContentSource_Generated value)?  generated,}){
final _that = this;
switch (_that) {
case ContentSource_Path() when path != null:
return path(_that);case ContentSource_Bytes() when bytes != null:
return bytes(_that);case ContentSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that);case ContentSource_Generated() when generated != null:
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
case ContentSource_Path() when path != null:
return path(_that.path);case ContentSource_Bytes() when bytes != null:
return bytes(_that.bytes);case ContentSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that.fd);case ContentSource_Generated() when generated != null:
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
case ContentSource_Path():
return path(_that.path);case ContentSource_Bytes():
return bytes(_that.bytes);case ContentSource_FileDescriptor():
return fileDescriptor(_that.fd);case ContentSource_Generated():
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
case ContentSource_Path() when path != null:
return path(_that.path);case ContentSource_Bytes() when bytes != null:
return bytes(_that.bytes);case ContentSource_FileDescriptor() when fileDescriptor != null:
return fileDescriptor(_that.fd);case ContentSource_Generated() when generated != null:
return generated(_that.descriptor);case _:
  return null;

}
}

}

/// @nodoc


class ContentSource_Path extends ContentSource {
  const ContentSource_Path({required this.path}): super._();


 final  String path;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ContentSource_PathCopyWith<ContentSource_Path> get copyWith => _$ContentSource_PathCopyWithImpl<ContentSource_Path>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSource_Path&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,path);

@override
String toString() {
  return 'ContentSource.path(path: $path)';
}


}

/// @nodoc
abstract mixin class $ContentSource_PathCopyWith<$Res> implements $ContentSourceCopyWith<$Res> {
  factory $ContentSource_PathCopyWith(ContentSource_Path value, $Res Function(ContentSource_Path) _then) = _$ContentSource_PathCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$ContentSource_PathCopyWithImpl<$Res>
    implements $ContentSource_PathCopyWith<$Res> {
  _$ContentSource_PathCopyWithImpl(this._self, this._then);

  final ContentSource_Path _self;
  final $Res Function(ContentSource_Path) _then;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(ContentSource_Path(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ContentSource_Bytes extends ContentSource {
  const ContentSource_Bytes({required this.bytes}): super._();


 final  Uint8List bytes;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ContentSource_BytesCopyWith<ContentSource_Bytes> get copyWith => _$ContentSource_BytesCopyWithImpl<ContentSource_Bytes>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSource_Bytes&&const DeepCollectionEquality().equals(other.bytes, bytes));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(bytes));

@override
String toString() {
  return 'ContentSource.bytes(bytes: $bytes)';
}


}

/// @nodoc
abstract mixin class $ContentSource_BytesCopyWith<$Res> implements $ContentSourceCopyWith<$Res> {
  factory $ContentSource_BytesCopyWith(ContentSource_Bytes value, $Res Function(ContentSource_Bytes) _then) = _$ContentSource_BytesCopyWithImpl;
@useResult
$Res call({
 Uint8List bytes
});




}
/// @nodoc
class _$ContentSource_BytesCopyWithImpl<$Res>
    implements $ContentSource_BytesCopyWith<$Res> {
  _$ContentSource_BytesCopyWithImpl(this._self, this._then);

  final ContentSource_Bytes _self;
  final $Res Function(ContentSource_Bytes) _then;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? bytes = null,}) {
  return _then(ContentSource_Bytes(
bytes: null == bytes ? _self.bytes : bytes // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class ContentSource_FileDescriptor extends ContentSource {
  const ContentSource_FileDescriptor({required this.fd}): super._();


 final  int fd;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ContentSource_FileDescriptorCopyWith<ContentSource_FileDescriptor> get copyWith => _$ContentSource_FileDescriptorCopyWithImpl<ContentSource_FileDescriptor>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSource_FileDescriptor&&(identical(other.fd, fd) || other.fd == fd));
}


@override
int get hashCode => Object.hash(runtimeType,fd);

@override
String toString() {
  return 'ContentSource.fileDescriptor(fd: $fd)';
}


}

/// @nodoc
abstract mixin class $ContentSource_FileDescriptorCopyWith<$Res> implements $ContentSourceCopyWith<$Res> {
  factory $ContentSource_FileDescriptorCopyWith(ContentSource_FileDescriptor value, $Res Function(ContentSource_FileDescriptor) _then) = _$ContentSource_FileDescriptorCopyWithImpl;
@useResult
$Res call({
 int fd
});




}
/// @nodoc
class _$ContentSource_FileDescriptorCopyWithImpl<$Res>
    implements $ContentSource_FileDescriptorCopyWith<$Res> {
  _$ContentSource_FileDescriptorCopyWithImpl(this._self, this._then);

  final ContentSource_FileDescriptor _self;
  final $Res Function(ContentSource_FileDescriptor) _then;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? fd = null,}) {
  return _then(ContentSource_FileDescriptor(
fd: null == fd ? _self.fd : fd // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class ContentSource_Generated extends ContentSource {
  const ContentSource_Generated({required this.descriptor}): super._();


 final  String descriptor;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ContentSource_GeneratedCopyWith<ContentSource_Generated> get copyWith => _$ContentSource_GeneratedCopyWithImpl<ContentSource_Generated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentSource_Generated&&(identical(other.descriptor, descriptor) || other.descriptor == descriptor));
}


@override
int get hashCode => Object.hash(runtimeType,descriptor);

@override
String toString() {
  return 'ContentSource.generated(descriptor: $descriptor)';
}


}

/// @nodoc
abstract mixin class $ContentSource_GeneratedCopyWith<$Res> implements $ContentSourceCopyWith<$Res> {
  factory $ContentSource_GeneratedCopyWith(ContentSource_Generated value, $Res Function(ContentSource_Generated) _then) = _$ContentSource_GeneratedCopyWithImpl;
@useResult
$Res call({
 String descriptor
});




}
/// @nodoc
class _$ContentSource_GeneratedCopyWithImpl<$Res>
    implements $ContentSource_GeneratedCopyWith<$Res> {
  _$ContentSource_GeneratedCopyWithImpl(this._self, this._then);

  final ContentSource_Generated _self;
  final $Res Function(ContentSource_Generated) _then;

/// Create a copy of ContentSource
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? descriptor = null,}) {
  return _then(ContentSource_Generated(
descriptor: null == descriptor ? _self.descriptor : descriptor // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
