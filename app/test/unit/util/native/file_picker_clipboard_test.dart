import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _MockRustLibApi extends Mock implements RustLibApi {
  @override
  Future<FileMetadata?> crateApiMetadataReadFileMetadata({required String path}) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => RustLib.initMock(api: _MockRustLibApi()));

  testWidgets('pasting a copied file path adds the file', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final directory = Directory.systemTemp.createTempSync('clipboard_file_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/copied.txt')..writeAsStringSync('content');
    final clipboardFiles = [file.path];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': file.path};
      return null;
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), (call) async {
      if (call.method == 'files') return clipboardFiles;
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null);
    });

    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    late BuildContext context;
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        ownsContainer: false,
        child: MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    await tester.runAsync(() => container.global.dispatchAsync(PickFileAction(option: FilePickerOption.clipboard, context: context)));

    final selected = container.read(selectedSendingFilesProvider);
    expect(selected, hasLength(1));
    expect(selected.single.path, file.path);

    clipboardFiles.clear();
    await tester.runAsync(() => container.global.dispatchAsync(PickFileAction(option: FilePickerOption.clipboard, context: context)));
    final selectedAfterTextPaste = container.read(selectedSendingFilesProvider);
    expect(selectedAfterTextPaste, hasLength(2));
    expect(selectedAfterTextPaste.last.path, isNull);
    expect(utf8.decode(selectedAfterTextPaste.last.bytes!), file.path);
    debugDefaultTargetPlatformOverride = null;
  });
}
