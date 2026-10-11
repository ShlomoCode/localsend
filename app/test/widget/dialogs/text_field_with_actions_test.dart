import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';

void main() {
  late TextEditingController controller;
  late List<String> saved;
  late Completer<String?> systemName;

  setUp(() {
    controller = TextEditingController(text: 'Original alias');
    saved = [];
    systemName = Completer<String?>();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
      home: Scaffold(
        body: TextFieldWithActions(
          name: 'Alias',
          controller: controller,
          onSubmitted: saved.add,
          actionsBuilder: (setDraft) => [
            IconButton(
              icon: const Icon(Icons.casino),
              onPressed: () => setDraft('Random alias'),
            ),
            IconButton(
              icon: const Icon(Icons.desktop_windows_rounded),
              onPressed: () async {
                final name = await systemName.future;
                if (name == null) return;
                setDraft(name);
              },
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Unmount before disposing the externally owned controller.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, controller.text));
    await tester.pumpAndSettle();
  }

  Future<void> cancel(WidgetTester tester) async {
    // A platform back action dismisses the modal without selecting Confirm.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ElevatedButton, t.general.confirm));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  void expectSaved(String alias) {
    expect(controller.text, alias);
    expect(saved, [alias]);
    expect(find.widgetWithText(TextButton, alias), findsOneWidget);
  }

  testWidgets('manual draft is discarded on back and reopening shows the saved alias', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'Edited alias');
    expect(controller.text, 'Original alias');
    expect(saved, isEmpty);
    await cancel(tester);
    expect(controller.text, 'Original alias');
    expect(saved, isEmpty);
    await open(tester);
    expect(find.text('Original alias'), findsNWidgets(2));
    expect(find.text('Edited alias'), findsNothing);
  });

  testWidgets('Confirm commits the final manual draft once', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'First edit');
    await tester.enterText(find.byType(TextFormField), 'Final edit');
    expect(saved, isEmpty);
    await confirm(tester);
    expectSaved('Final edit');
  });

  testWidgets('keyboard submission commits the manual draft once', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'Keyboard alias');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expectSaved('Keyboard alias');
  });

  for (final shortcut in ['random', 'system']) {
    for (final shouldConfirm in [false, true]) {
      testWidgets('$shortcut shortcut changes only the draft until ${shouldConfirm ? 'Confirm' : 'back'}', (tester) async {
        await mount(tester);
        await open(tester);
        await tester.tap(find.byIcon(shortcut == 'random' ? Icons.casino : Icons.desktop_windows_rounded));
        final alias = shortcut == 'random' ? 'Random alias' : 'System alias';
        if (shortcut == 'system') systemName.complete(alias);
        await tester.pumpAndSettle();
        expect(find.text(alias), findsOneWidget);
        expect(controller.text, 'Original alias');
        expect(saved, isEmpty);
        if (shouldConfirm) {
          await confirm(tester);
          expectSaved(alias);
        } else {
          await cancel(tester);
          expect(controller.text, 'Original alias');
          expect(saved, isEmpty);
        }
      });
    }
  }

  for (final shouldConfirm in [false, true]) {
    testWidgets('system lookup completing after ${shouldConfirm ? 'Confirm' : 'back'} does not change saved state', (tester) async {
      await mount(tester);
      await open(tester);
      await tester.enterText(find.byType(TextFormField), 'Manual alias');
      await tester.tap(find.byIcon(Icons.desktop_windows_rounded));
      if (shouldConfirm) {
        await confirm(tester);
      } else {
        await cancel(tester);
      }
      // Keep another dialog open when the previous lookup completes.
      await open(tester);
      systemName.complete('Late system alias');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.text, shouldConfirm ? 'Manual alias' : 'Original alias');
      expect(saved, shouldConfirm ? ['Manual alias'] : isEmpty);
      expect(find.text('Late system alias'), findsNothing);
    });
  }
}
