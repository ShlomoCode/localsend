import 'dart:io';

import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

class _MockRustApi extends Mock implements RustLibApi {
  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async => null;
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _MockRustApi());
  });

  tearDownAll(RustLib.dispose);

  test('loads a large run of file arguments in one update', () async {
    final directory = Directory.systemTemp.createTempSync('localsend-args-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final paths = List.generate(1000, (index) {
      final file = File('${directory.path}/$index.txt');
      file.writeAsStringSync('$index');
      return file.path;
    });
    final observer = RefenaHistoryObserver.only(actionDispatched: true, change: true);
    final ref = RefenaContainer(observers: [observer]);
    addTearDown(ref.disposeContainer);

    final added = await ref.redux(selectedSendingFilesProvider).dispatchAsyncTakeResult(LoadSelectionFromArgsAction(paths));

    expect(added, isTrue);
    expect(ref.read(selectedSendingFilesProvider).map((file) => file.path), paths);
    expect(observer.dispatchedActions.whereType<AddFilesAction>().length, 1);
    expect(observer.history.whereType<ChangeEvent>().length, 1);
  });

  test('preserves order and ignores a file repeated after an earlier batch', () async {
    final directory = Directory.systemTemp.createTempSync('localsend-args-order-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final first = File('${directory.path}/first.txt')..writeAsStringSync('first');
    final second = File('${directory.path}/second.txt')..writeAsStringSync('second');
    final observer = RefenaHistoryObserver.only(actionDispatched: true);
    final ref = RefenaContainer(observers: [observer]);
    addTearDown(ref.disposeContainer);

    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsyncTakeResult(
          LoadSelectionFromArgsAction([first.path, second.path, first.path, '--text', 'message']),
        );

    final files = ref.read(selectedSendingFilesProvider);
    expect(files.map((file) => file.path), [first.path, second.path, null]);
    expect(observer.dispatchedActions.whereType<AddFilesAction>().length, 2);
  });
}
