import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _beautyEncoder = JsonEncoder.withIndent('  ');
const _encoder = JsonEncoder();

/// Custom implementation of SharedPreferencesStorePlatform
/// that uses a custom file.
class SharedPreferencesFile extends SharedPreferencesStorePlatform {
  final File _file;
  final bool beautify;
  Future<void>? _pendingWrite;
  int _revision = 0;

  SharedPreferencesFile({required String filePath, this.beautify = false}) : _file = File(filePath);

  late final Map<String, Object> _cache = _getAll();

  bool exists() {
    return _file.existsSync();
  }

  String getPath() {
    return _file.path;
  }

  @override
  Future<bool> clear() {
    _cache.clear();
    return _write();
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return _cache;
  }

  Map<String, Object> _getAll() {
    if (!_file.existsSync()) {
      _file.createSync(recursive: true);
    }

    try {
      return json.decode(_file.readAsStringSync()).cast<String, Object>();
    } catch (e) {
      return {};
    }
  }

  @override
  Future<bool> remove(String key) {
    _cache.remove(key);
    return _write();
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _cache[key] = value;
    return _write();
  }

  Future<bool> _write() async {
    _revision++;
    await (_pendingWrite ??= _flush());
    return true;
  }

  Future<void> _flush() async {
    try {
      await Future<void>.delayed(Duration.zero);
      while (true) {
        final revision = _revision;
        final data = (beautify ? _beautyEncoder : _encoder).convert(_cache);
        if (!await _file.exists()) {
          await _file.create(recursive: true);
        }
        await _file.writeAsString(data);
        if (revision == _revision) break;
      }
    } finally {
      _pendingWrite = null;
    }
  }
}
