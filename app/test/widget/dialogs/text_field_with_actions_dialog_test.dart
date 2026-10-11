import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions_dialog.dart';

void main() {
  const originalAlias = 'Original alias';
  late List<String?> results;
  late Completer<String?> systemName;

  setUp(() {
    results = [];
  });

  Future<void> mount(WidgetTester tester) async {
    systemName = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder())),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => TextFieldWithActionsDialog(
                      name: 'Alias',
                      initialValue: results.lastOrNull ?? originalAlias,
                      actionsBuilder: (setDraft) => [
                        IconButton(icon: const Icon(Icons.casino), onPressed: () => setDraft('Random alias')),
                        IconButton(
                          icon: const Icon(Icons.desktop_windows_rounded),
                          onPressed: () async {
                            final name = await systemName.future;
                            if (name != null) setDraft(name);
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Open'));
    await tester.pumpAndSettle();
  }

  Future<void> cancel(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ElevatedButton, t.general.confirm));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets('manual draft is discarded on back and reopening shows the saved alias', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'Edited alias');
    expect(results, isEmpty);
    await cancel(tester);
    expect(results, [null]);
    await open(tester);
    expect(find.text(originalAlias), findsOneWidget);
    expect(find.text('Edited alias'), findsNothing);
  });

  testWidgets('Confirm commits the final manual draft once', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'First edit');
    await tester.enterText(find.byType(TextFormField), 'Final edit');
    expect(results, isEmpty);
    await confirm(tester);
    expect(results, ['Final edit']);
  });

  testWidgets('keyboard submission commits the manual draft once', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.enterText(find.byType(TextFormField), 'Keyboard alias');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(results, ['Keyboard alias']);
  });

  testWidgets('random shortcut stays a draft until Confirm', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.tap(find.byIcon(Icons.casino));
    expect(find.text('Random alias'), findsOneWidget);
    expect(results, isEmpty);
    await confirm(tester);
    expect(results, ['Random alias']);
  });

  testWidgets('system shortcut stays a draft until cancelled', (tester) async {
    await mount(tester);
    await open(tester);
    await tester.tap(find.byIcon(Icons.desktop_windows_rounded));
    systemName.complete('System alias');
    await tester.pumpAndSettle();
    expect(find.text('System alias'), findsOneWidget);
    expect(results, isEmpty);
    await cancel(tester);
    expect(results, [null]);
  });

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
      expect(results, [shouldConfirm ? 'Manual alias' : null]);
      expect(find.text('Late system alias'), findsNothing);
    });
  }
}
