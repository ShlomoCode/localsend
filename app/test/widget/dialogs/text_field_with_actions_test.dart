import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';

void main() {
  testWidgets('cancel discards edits and Confirm submits the final alias once', (tester) async {
    final controller = TextEditingController(text: 'Original alias');
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextFieldWithActions(
            name: 'Alias',
            controller: controller,
            onSubmitted: saved.add,
            actions: const [],
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Original alias'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Discarded alias');
    expect(saved, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.text, 'Original alias');
    expect(saved, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Original alias'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'First edit');
    await tester.enterText(find.byType(TextFormField), 'Final alias');
    expect(saved, isEmpty);
    await tester.tap(find.widgetWithText(ElevatedButton, t.general.confirm));
    await tester.pumpAndSettle();
    expect(controller.text, 'Final alias');
    expect(saved, ['Final alias']);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
