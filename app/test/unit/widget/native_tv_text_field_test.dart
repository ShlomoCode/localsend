import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/widget/dialogs/native_tv_text_field.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native TV edits sync once, external alias changes sync back, and DONE and Back notify the dialog', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final nativeCalls = <MethodCall>[];
    int? viewId;
    String? channelName;
    Map<Object?, Object?>? creationParams;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final args = call.arguments as Map<Object?, Object?>;
        viewId = args['id'] as int;
        channelName = 'org.localsend.localsend_app/tv_text_field/$viewId';
        messenger.setMockMethodCallHandler(MethodChannel(channelName!), (nativeCall) async {
          nativeCalls.add(nativeCall);
          return null;
        });
        final bytes = args['params'] as Uint8List;
        creationParams = const StandardMessageCodec().decodeMessage(ByteData.sublistView(bytes)) as Map<Object?, Object?>;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform_views, null));
    addTearDown(() {
      if (channelName != null) messenger.setMockMethodCallHandler(MethodChannel(channelName!), null);
    });

    final controller = TextEditingController(text: 'Original');
    addTearDown(controller.dispose);
    final changes = <String>[];
    var doneCount = 0;
    var backCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeTvTextField(
            controller: controller,
            onChanged: changes.add,
            onSubmitted: () => doneCount++,
            onKeyboardDismissed: () => backCount++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(creationParams?['text'], 'Original');
    expect(nativeCalls.map((call) => call.method), containsAllInOrder(['setText', 'focus']));

    controller.text = 'Random alias';
    await tester.pump();
    expect(nativeCalls.where((call) => call.method == 'setText').last.arguments, 'Random alias');

    Future<void> sendNative(String method, [Object? arguments]) async {
      final completer = Completer<void>();
      await messenger.handlePlatformMessage(
        channelName!,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) => completer.complete(),
      );
      await completer.future;
    }

    final callsBeforeEdit = nativeCalls.where((call) => call.method == 'setText').length;
    await sendNative('changed', 'Typed alias');
    expect(controller.text, 'Typed alias');
    expect(changes, ['Typed alias']);
    expect(nativeCalls.where((call) => call.method == 'setText').length, callsBeforeEdit);
    await sendNative('submitted');
    await sendNative('keyboardDismissed');
    expect(doneCount, 1);
    expect(backCount, 1);

    final replacement = TextEditingController(text: 'Replacement');
    addTearDown(replacement.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeTvTextField(controller: replacement, onChanged: changes.add),
        ),
      ),
    );
    expect(nativeCalls.where((call) => call.method == 'setText').last.arguments, 'Replacement');
    final callsBeforeOldControllerChange = nativeCalls.length;
    controller.text = 'Old controller changed';
    await tester.pump();
    expect(nativeCalls.length, callsBeforeOldControllerChange);
    await sendNative('changed', 'Replacement edited');
    expect(replacement.text, 'Replacement edited');
    expect(controller.text, 'Old controller changed');

    await tester.pumpWidget(const SizedBox());
    await sendNative('changed', 'Late edit');
    expect(replacement.text, 'Replacement edited');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('alias dialog uses native input only on TV and returns focus to Confirm after Back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger = tester.binding.defaultBinaryMessenger;
    String? channelName;
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map<Object?, Object?>)['id'] as int;
        channelName = 'org.localsend.localsend_app/tv_text_field/$id';
        messenger.setMockMethodCallHandler(MethodChannel(channelName!), (nativeCall) async {
          nativeCalls.add(nativeCall);
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (channelName != null) messenger.setMockMethodCallHandler(MethodChannel(channelName!), null);
    });

    final controller = TextEditingController(text: 'Device');
    addTearDown(controller.dispose);
    Widget app(bool isTv) => RefenaScope(
      overrides: [tvProvider.overrideWithValue(isTv)],
      child: MaterialApp(
        home: Scaffold(
          body: TextFieldWithActions(name: 'Alias', controller: controller, onChanged: (_) {}, actions: const []),
        ),
      ),
    );

    await tester.pumpWidget(app(true));
    await tester.tap(find.byType(TextFieldWithActions));
    await tester.pumpAndSettle();
    expect(find.byType(NativeTvTextField), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(channelName, isNotNull);

    final completer = Completer<void>();
    await messenger.handlePlatformMessage(
      channelName!,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('keyboardDismissed')),
      (_) => completer.complete(),
    );
    await completer.future;
    await tester.pump();
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).focusNode!.hasFocus, isTrue);

    final focusCallsBeforeReenter = nativeCalls.where((call) => call.method == 'focus').length;
    final platformFocus = tester.widget<Focus>(find.descendant(of: find.byType(PlatformViewLink), matching: find.byType(Focus))).focusNode!;
    platformFocus.requestFocus();
    await tester.pump();
    expect(nativeCalls.where((call) => call.method == 'focus').length, greaterThan(focusCallsBeforeReenter));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(false));
    await tester.tap(find.byType(TextFieldWithActions));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.byType(NativeTvTextField), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
