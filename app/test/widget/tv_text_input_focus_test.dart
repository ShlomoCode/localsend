import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/tv_text_input_focus.dart';

void main() {
  const channel = MethodChannel('org.localsend.localsend_app/localsend');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('editor signal precedes Flutter client and stays true across fields', (tester) async {
    final events = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      events.add('native:${call.arguments}');
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.textInput, (call) async {
      events.add('flutter:${call.method}');
      return null;
    });
    addTearDown(tester.testTextInput.register);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TvTextInputFocus(builder: (node) => TextFormField(focusNode: node)),
              TvTextInputFocus(builder: (node) => TextFormField(focusNode: node)),
            ],
          ),
        ),
      ),
    );

    final fields = tester.widgetList<EditableText>(find.byType(EditableText)).toList();
    fields.first.focusNode.requestFocus();
    await tester.pump();
    expect(events, contains('native:true'));
    expect(events, contains('flutter:TextInput.setClient'));
    expect(events.indexOf('native:true'), lessThan(events.indexOf('flutter:TextInput.setClient')));

    events.clear();
    fields.last.focusNode.requestFocus();
    await tester.pump();
    expect(events, isNot(contains('native:false')));
    expect(events, isNot(contains('native:true')));

    fields.last.focusNode.unfocus();
    await tester.pump();
    expect(events, contains('native:false'));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('disposal and noneditable focus clear the editor signal', (tester) async {
    final values = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      values.add(call.arguments as bool);
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextInputFocus(builder: (node) => TextFormField(focusNode: node)),
        ),
      ),
    );
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.requestFocus();
    await tester.pump();
    expect(values, [true]);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(values, [true, false]);

    values.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextInputFocus(editable: false, builder: (node) => TextFormField(focusNode: node, readOnly: true)),
        ),
      ),
    );
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.requestFocus();
    await tester.pump();
    expect(values, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextInputFocus(editable: true, builder: (node) => TextFormField(focusNode: node)),
        ),
      ),
    );
    expect(values, [true]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvTextInputFocus(editable: false, builder: (node) => TextFormField(focusNode: node, readOnly: true)),
        ),
      ),
    );
    expect(values, [true, false]);
    debugDefaultTargetPlatformOverride = null;
  });
}
