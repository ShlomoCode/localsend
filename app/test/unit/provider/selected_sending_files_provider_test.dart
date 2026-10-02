import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

CrossFile _file(String name, String? path, {List<int>? bytes, AssetEntity? asset}) => CrossFile(
  name: name,
  fileType: FileType.other,
  size: bytes?.length ?? 1,
  thumbnail: null,
  asset: asset,
  path: path,
  bytes: bytes,
  lastModified: null,
  lastAccessed: null,
);

void main() {
  test('adding files compares only against the existing selection by path', () async {
    final asset = AssetEntity(id: 'asset-1', typeInt: 1, width: 1, height: 1);
    final selectedPath = _file('selected', '/selected');
    final selectedBytes = _file('message', null, bytes: [1]);
    final service = ReduxNotifier.test(
      redux: SelectedSendingFilesNotifier(),
      initialState: [selectedPath, selectedBytes],
    );
    final duplicatePath = _file('renamed', '/selected');
    final duplicateNullPath = _file('different asset', null, asset: asset);
    final newFile = _file('new', '/new');
    final repeatedInBatch = _file('same path in this batch', '/new');

    await service.dispatchAsync(
      AddFilesAction(
        files: [duplicatePath, duplicateNullPath, newFile, repeatedInBatch],
        converter: (file) async => file,
      ),
    );

    expect(service.state, [selectedPath, selectedBytes, newFile, repeatedInBatch]);
  });

  test('adding an Android folder skips selected URIs while retaining repeated incoming URIs', () async {
    const folderUri = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments';
    const existingUri = '$folderUri/document/primary%3ADocuments%2Fselected.txt';
    const newUri = '$folderUri/document/primary%3ADocuments%2Fnew.txt';
    final selected = _file('selected.txt', existingUri);
    final service = ReduxNotifier.test(redux: SelectedSendingFilesNotifier(), initialState: [selected]);

    await service.dispatchAsync(
      AddAndroidDirectoryAction(
        android_channel.PickDirectoryResult(
          directoryUri: folderUri,
          files: [
            android_channel.FileInfo(name: 'selected.txt', size: 1, uri: existingUri, lastModified: null),
            android_channel.FileInfo(name: 'new.txt', size: 1, uri: newUri, lastModified: null),
            android_channel.FileInfo(name: 'new.txt', size: 1, uri: newUri, lastModified: null),
          ],
        ),
      ),
    );

    expect(service.state.map((file) => file.path), [existingUri, newUri, newUri]);
  });
}
