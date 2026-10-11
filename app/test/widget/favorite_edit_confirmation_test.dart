import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/widget/dialogs/favorite_edit_dialog.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistence;
  late Completer<void> save;

  setUp(() {
    persistence = MockPersistenceService();
    when(persistence.getFavorites()).thenReturn([
      FavoriteDevice(id: 'favorite', fingerprint: 'fingerprint', ip: '127.0.0.1', port: 53317, alias: 'Original'),
    ]);
    when(persistence.setFavorites(any)).thenAnswer((_) => save.future);
  });

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.text('Edit favorite'));
    await tester.pumpAndSettle();
  }

  Future<void> confirmRename(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, 'Changed');
    await tester.tap(find.text(t.general.confirm));
    await tester.pump();
  }

  testWidgets('confirm closes the edit route after saving and reopens with the saved name', (tester) async {
    save = Completer<void>();
    await tester.pumpWidget(_testApp(persistence));
    await openEditor(tester);
    await confirmRename(tester);

    expect(find.byType(FavoriteEditDialog), findsOneWidget);
    final saved = verify(persistence.setFavorites(captureAny)).captured.single as List<FavoriteDevice>;
    expect(saved.single.alias, 'Changed');
    expect(saved.single.customAlias, isTrue);

    save.complete();
    await tester.pumpAndSettle();
    expect(find.byType(FavoriteEditDialog), findsNothing);

    await openEditor(tester);
    expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, 'Changed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel during saving does not close a subsequently opened dialog', (tester) async {
    save = Completer<void>();
    await tester.pumpWidget(_testApp(persistence));
    await openEditor(tester);
    await confirmRename(tester);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(FavoriteEditDialog), findsNothing);

    await tester.tap(find.text('Other dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Keep open'), findsOneWidget);

    save.complete();
    await tester.pumpAndSettle();
    expect(find.text('Keep open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp(MockPersistenceService persistence) {
  return RefenaScope(
    overrides: [persistenceProvider.overrideWithValue(persistence)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FavoriteEditDialog(favorite: context.ref.read(favoritesProvider).single),
                ),
                child: const Text('Edit favorite'),
              ),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(title: Text('Keep open')),
                ),
                child: const Text('Other dialog'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
