import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/custom_icon_button.dart';

void main() {
  testWidgets('icon button padding follows the active theme platform', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: const Scaffold(body: CustomIconButton(onPressed: null, child: Icon(Icons.close))),
      ),
    );

    TextButton button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.style!.padding!.resolve({}), const EdgeInsets.symmetric(horizontal: 8, vertical: 16));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: CustomIconButton(onPressed: null, child: Icon(Icons.close))),
      ),
    );
    await tester.pumpAndSettle();

    button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.style!.padding!.resolve({}), const EdgeInsets.all(8));
    debugDefaultTargetPlatformOverride = null;
  });
}
