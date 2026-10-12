import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';

void main() {
  testWidgets('live edits stay applied and submitted edits require confirmation', (tester) async {
    for (final saveOnConfirm in [false, true]) {
      final controller = TextEditingController(text: 'Original alias');
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextFieldWithActions(
              name: 'Alias',
              controller: controller,
              onChanged: saveOnConfirm ? null : saved.add,
              onSubmitted: saveOnConfirm ? saved.add : null,
              actions: const [],
            ),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Original alias'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Discarded alias');
      expect(saved, saveOnConfirm ? isEmpty : ['Discarded alias']);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final displayedAlias = saveOnConfirm ? 'Original alias' : 'Discarded alias';
      expect(controller.text, displayedAlias);
      expect(saved, saveOnConfirm ? isEmpty : ['Discarded alias']);

      await tester.tap(find.widgetWithText(TextButton, displayedAlias));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'First edit');
      await tester.enterText(find.byType(TextFormField), 'Final alias');
      if (saveOnConfirm) expect(saved, isEmpty);
      await tester.tap(find.widgetWithText(ElevatedButton, t.general.confirm));
      await tester.pumpAndSettle();
      expect(controller.text, 'Final alias');
      expect(saved, saveOnConfirm ? ['Final alias'] : ['Discarded alias', 'First edit', 'Final alias']);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });
}
