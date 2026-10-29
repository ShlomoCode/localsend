import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/directory_access_pool.dart';
import 'package:localsend_isolates/model/scoped_file.dart';

void main() {
  test('selection removal cannot release an active session, operation, or web offer', () async {
    final released = <String>[];
    final pool = DirectoryAccessPool(release: (token) async => released.add(token));
    final picked = pool.registerPicked(path: '/outside/Chosen', accessToken: 'lease');
    const file = ScopedFile(directoryPath: '/outside/Chosen', accessToken: 'lease', relativePath: 'nested/a.txt');
    final selection = pool.retain([file]);
    picked.dispose();
    final session = pool.retain([file]);
    final operation = pool.retain([file]);
    final webOffer = pool.retain([file]);
    selection.dispose();
    session.dispose();
    operation.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(released, isEmpty);
    webOffer.dispose();
    webOffer.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(released, ['lease']);
  });

  test('expired and path-mismatched tokens fail before any new batch is retained', () async {
    final released = <String>[];
    final pool = DirectoryAccessPool(release: (token) async => released.add(token));
    final picked = pool.registerPicked(path: '/chosen', accessToken: 'lease');
    const valid = ScopedFile(directoryPath: '/chosen', accessToken: 'lease', relativePath: 'a');
    const invalid = ScopedFile(directoryPath: '/other', accessToken: 'lease', relativePath: 'b');
    expect(() => pool.retain([valid, invalid]), throwsStateError);
    picked.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(released, ['lease']);
    expect(() => pool.retain([valid]), throwsStateError);
  });
}
