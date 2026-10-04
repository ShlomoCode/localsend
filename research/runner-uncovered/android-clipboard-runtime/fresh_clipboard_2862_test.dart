import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('org.localsend.localsend_app/localsend');
  const pasteboard = MethodChannel('pasteboard');
  const length = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.uri_content.UriContentPlatformApi.getContentLength', StandardMessageCodec(),
  );
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? rawText;
  List<String> nativeUris = [];
  int coercedReads = 0;
  int pasteboardReads = 0;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    rawText = null;
    nativeUris = [];
    coercedReads = 0;
    pasteboardReads = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'getClipboardText') return rawText;
      throw StateError('Unexpected native call ${call.method}');
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        coercedReads++;
        return {'text': rawText ?? 'GFF3 provider text coerced into a message'};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(pasteboard, (call) async {
      pasteboardReads++;
      if (call.method == 'image') return null;
      if (call.method == 'files') return nativeUris;
      throw StateError('Unexpected pasteboard call ${call.method}');
    });
    messenger.setMockDecodedMessageHandler<Object?>(length, (message) async => <Object?>[42 * 1024 * 1024]);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(pasteboard, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockDecodedMessageHandler<Object?>(length, null);
  });

  Future<RefenaContainer> paste(WidgetTester tester) async {
    final ref = RefenaContainer();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }))));
    await tester.runAsync(() => ref.global.dispatchAsync(PickFileAction(option: FilePickerOption.clipboard, context: context)));
    return ref;
  }

  testWidgets('SAF text file remains a file and never requests coerced text', (tester) async {
    try {
      nativeUris = ['content://test.documents/document/TAIR10_GFF3_genes.gff'];
      final ref = await paste(tester);
      final selected = ref.read(selectedSendingFilesProvider);
      expect(selected, hasLength(1));
      expect(selected.single.path, nativeUris.single);
      expect(selected.single.bytes, isNull);
      expect(selected.single.size, 42 * 1024 * 1024);
      expect(coercedReads, 0);
      ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('explicit copied text wins even with an accompanying URI', (tester) async {
    try {
      rawText = 'https://example.com';
      nativeUris = ['content://test.documents/document/attachment'];
      final ref = await paste(tester);
      final selected = ref.read(selectedSendingFilesProvider);
      expect(selected, hasLength(1));
      expect(utf8.decode(selected.single.bytes!), rawText);
      expect(selected.single.path, isNull);
      expect(coercedReads, 0);
      expect(pasteboardReads, 0);
      ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop still uses Flutter clipboard', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final ref = await paste(tester);
      expect(coercedReads, 1);
      expect(utf8.decode(ref.read(selectedSendingFilesProvider).single.bytes!), 'GFF3 provider text coerced into a message');
      ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
