import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/whats_new_page.dart';

void main() {
  testWidgets('shows the bundled changelog while keeping Done accessible', (tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: WhatsNewPage(version: '1.18.2')));
    await tester.pumpAndSettle();

    final bundledChangelog = await rootBundle.loadString(Assets.changelog);
    expect(find.textContaining('1.18.2'), findsWidgets);
    expect(tester.widget<Markdown>(find.byType(Markdown)).data, bundledChangelog);

    final doneButton = find.widgetWithText(FilledButton, t.general.done);
    expect(doneButton, findsOneWidget);
    expect(doneButton.hitTestable(), findsOneWidget);

    final changelogScroll = find.descendant(of: find.byType(Markdown), matching: find.byType(Scrollable)).first;
    final scrollPosition = tester.state<ScrollableState>(changelogScroll).position;
    expect(scrollPosition.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(Markdown), const Offset(0, -250));
    await tester.pumpAndSettle();

    expect(scrollPosition.pixels, greaterThan(0));
    expect(doneButton.hitTestable(), findsOneWidget);
  });
}
