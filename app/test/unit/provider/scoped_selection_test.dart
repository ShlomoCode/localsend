import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/directory_access_pool.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/crypto.dart';
import 'package:localsend_isolates/rust/api/scoped_file.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/file_hash.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  test('external directory selection and repeated hashes keep the scoped source', () async {
    final api = _ScopedApi();
    RustLib.initMock(api: api);
    final released = <String>[];
    final pool = DirectoryAccessPool(release: (token) async => released.add(token));
    final picked = pool.registerPicked(path: '/unavailable/Selected', accessToken: 'lease');
    final service = ReduxNotifier.test(redux: SelectedSendingFilesNotifier(directoryPool: pool));

    // This path deliberately does not exist: listing and hashing must use
    // the picker grant rather than opening the bare filesystem path.
    await service.dispatchAsync(AddDirectoryAction('/unavailable/Selected', accessToken: 'lease'));
    picked.dispose();
    expect(service.state.map((file) => file.name), ['Selected/nested/note.txt']);
    final file = service.state.single.copyWith(name: 'renamed.txt');
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(
        await calculateFileHash(path: file.path, bytes: file.bytes, scopedSource: file.scopedSource, cancelToken: _Token()),
        'checksum',
      );
    }
    expect(api.reads, ['nested/note.txt', 'nested/note.txt']);
    expect(file.scopedSource!.directoryPath, '/unavailable/Selected');
    expect(file.scopedSource!.accessToken, 'lease');
    expect(released, isEmpty);
    service.dispatch(RemoveSelectedFileAction(0));
    await Future<void>.delayed(Duration.zero);
    expect(released, ['lease']);

    api.empty = true;
    final empty = pool.registerPicked(path: '/unavailable/Selected', accessToken: 'empty');
    try {
      await service.dispatchAsync(AddDirectoryAction('/unavailable/Selected', accessToken: 'empty'));
    } finally {
      empty.dispose();
    }
    await Future<void>.delayed(Duration.zero);
    expect(released, ['lease', 'empty']);

    api.fail = true;
    final failed = pool.registerPicked(path: '/unavailable/Selected', accessToken: 'failed');
    try {
      await expectLater(service.dispatchAsync(AddDirectoryAction('/unavailable/Selected', accessToken: 'failed')), throwsStateError);
    } finally {
      failed.dispose();
    }
    await Future<void>.delayed(Duration.zero);
    expect(released, ['lease', 'empty', 'failed']);
  });
}

class _Token implements RsCancellationToken {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected token call');
}

class _ScopedApi implements RustLibApi {
  final reads = <String>[];
  bool empty = false;
  bool fail = false;

  @override
  Future<List<RsScopedEntry>> crateApiScopedFileListScopedDirectory({required String directoryPath, required String accessToken}) async {
    expect(directoryPath, '/unavailable/Selected');
    if (fail) throw StateError('Listing failed');
    if (empty) return [];
    expect(accessToken, 'lease');
    return [RsScopedEntry(relativePath: 'nested/note.txt', size: BigInt.from(43))];
  }

  @override
  Stream<RsHashFileEvent> crateApiCryptoHashFile({
    String? path,
    int? fileDescriptor,
    Uint8List? bytes,
    RsScopedFile? scopedSource,
    required RsCancellationToken cancelToken,
  }) async* {
    expect(path, isNull);
    expect(fileDescriptor, isNull);
    expect(bytes, isNull);
    expect(scopedSource!.directoryPath, '/unavailable/Selected');
    expect(scopedSource.accessToken, 'lease');
    reads.add(scopedSource.relativePath);
    yield const RsHashFileEvent.done(hash: 'checksum');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}
