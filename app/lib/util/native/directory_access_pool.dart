import 'dart:async';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:localsend_isolates/model/scoped_file.dart';
import 'package:logging/logging.dart';

final directoryAccessPool = DirectoryAccessPool(
  release: (token) => FilePicker.releaseDirectoryAccess(accessToken: token),
);

/// Owns picker directory leases on the main isolate. Only strings cross isolates.
class DirectoryAccessPool {
  DirectoryAccessPool({required Future<void> Function(String accessToken) release}) : _release = release;

  final Future<void> Function(String accessToken) _release;
  final Map<String, _DirectoryLease> _leases = {};
  static final _logger = Logger('DirectoryAccessPool');

  /// The picker starts one native reference. The caller must dispose this owner.
  DirectoryAccessOwner registerPicked({required String path, required String accessToken}) {
    if (path.isEmpty || accessToken.isEmpty || _leases.containsKey(accessToken)) {
      throw StateError('Invalid or duplicate directory access');
    }
    _leases[accessToken] = _DirectoryLease(path, 1);
    return DirectoryAccessOwner._(this, {accessToken});
  }

  /// Validates the entire batch before changing any counts.
  DirectoryAccessOwner retain(Iterable<ScopedFile?> sources) {
    final roots = <String, String>{};
    for (final source in sources) {
      if (source == null) continue;
      final lease = _leases[source.accessToken];
      if (lease == null || lease.path != source.directoryPath) {
        throw StateError('Directory access expired or path changed');
      }
      roots[source.accessToken] = source.directoryPath;
    }
    for (final token in roots.keys) {
      _leases[token]!.references++;
    }
    return DirectoryAccessOwner._(this, roots.keys.toSet());
  }

  void _releaseTokens(Set<String> tokens) {
    for (final token in tokens) {
      final lease = _leases[token];
      if (lease == null) continue;
      if (--lease.references != 0) continue;
      _leases.remove(token);
      unawaited(
        Future.sync(() => _release(token)).catchError((Object error, StackTrace stack) {
          _logger.warning('Failed to release directory access', error, stack);
        }),
      );
    }
  }
}

class _DirectoryLease {
  _DirectoryLease(this.path, this.references);
  final String path;
  int references;
}

class DirectoryAccessOwner {
  DirectoryAccessOwner._(this._pool, this._tokens);
  final DirectoryAccessPool _pool;
  final Set<String> _tokens;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pool._releaseTokens(_tokens);
  }
}
