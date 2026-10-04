import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
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
  String? text;
  bool hasPrimaryClip = false;
  List<String> nativeUris = [];
  int nativeChecks = 0;
  int filesCalls = 0;
  int textCalls = 0;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    text = null;
    hasPrimaryClip = false;
    nativeUris = [];
    nativeChecks = 0;
    filesCalls = 0;
    textCalls = 0;
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'hasClipboardContent') { nativeChecks++; return hasPrimaryClip; }
      throw StateError('Unexpected native call ${call.method}');
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        textCalls++;
        return text == null ? null : {'text': text};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(pasteboard, (call) async {
      if (call.method == 'image') return null;
      if (call.method == 'files') {
        filesCalls++;
        if (defaultTargetPlatform == TargetPlatform.android && !hasPrimaryClip) {
          // Exact pinned Android plugin sends no callback for null primaryClip.
          return Completer<Object?>().future;
        }
        return nativeUris;
      }
      throw StateError('Unexpected pasteboard call ${call.method}');
    });
    messenger.setMockDecodedMessageHandler<Object?>(length, (message) async => <Object?>[4096]);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(pasteboard, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockDecodedMessageHandler<Object?>(length, null);
  });

  Future<({RefenaContainer ref, bool completed})> paste(WidgetTester tester) async {
    final ref = RefenaContainer();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }))));
    var completed = true;
    await tester.runAsync(() => ref.global
        .dispatchAsync(PickFileAction(option: FilePickerOption.clipboard, context: context))
        .timeout(const Duration(milliseconds: 300), onTimeout: () { completed = false; }));
    await tester.pump();
    return (ref: ref, completed: completed);
  }

  testWidgets('empty Android clipboard completes and shows no-item message', (tester) async {
    try {
      final result = await paste(tester);
      expect(result.completed, isTrue, reason: 'Empty Android clipboard must finish instead of waiting for a missing native files callback');
      expect(result.ref.read(selectedSendingFilesProvider), isEmpty);
      expect(filesCalls, 0);
      expect(nativeChecks, 1);
      expect(find.text(t.general.noItemInClipboard), findsOneWidget);
      result.ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('copied Android URI still selects a file', (tester) async {
    try {
      hasPrimaryClip = true;
      nativeUris = ['content://test.documents/document/a.bin'];
      final result = await paste(tester);
      expect(result.completed, isTrue);
      final selected = result.ref.read(selectedSendingFilesProvider);
      expect(selected, hasLength(1));
      expect(selected.single.path, nativeUris.single);
      expect(selected.single.bytes, isNull);
      expect(filesCalls, 1);
      result.ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('ordinary Android text keeps existing text priority', (tester) async {
    try {
      hasPrimaryClip = true;
      text = 'copied text';
      final result = await paste(tester);
      expect(result.completed, isTrue);
      expect(utf8.decode(result.ref.read(selectedSendingFilesProvider).single.bytes!), text);
      expect(textCalls, 1);
      expect(nativeChecks, 0);
      expect(filesCalls, 0);
      result.ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('empty desktop clipboard still uses existing pasteboard route', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final result = await paste(tester);
      expect(result.completed, isTrue);
      expect(result.ref.read(selectedSendingFilesProvider), isEmpty);
      expect(filesCalls, 1);
      expect(nativeChecks, 0);
      expect(find.text(t.general.noItemInClipboard), findsOneWidget);
      result.ref.disposeContainer();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
