import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Isolated reproduction of the pinned APK header, preserving its 30dp page inset.
// Translation/provider/native APK enumeration are replaced by fixed data.
Widget header(bool fixed, bool value, ValueChanged<bool> onChanged) {
  const count = Text('Apps (500)');
  const label = Text('Select Multiple Apps');
  final control = Switch(value: value, onChanged: onChanged);
  if (!fixed) {
    return Row(children: [count, const Spacer(), Row(children: [label, const SizedBox(width: 5), control])]);
  }
  return Wrap(
    alignment: WrapAlignment.spaceBetween,
    spacing: 20,
    runSpacing: 8,
    children: [count, Row(mainAxisSize: MainAxisSize.min, children: [const Flexible(child: label), const SizedBox(width: 5), control])],
  );
}

void main() {
  final results = <Map<String, Object?>>[];
  tearDownAll(() {
    File('header-results.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  });
  // flutter_test uses Ahem, so 800dp is an unambiguous wide control rather than
  // asserting device-font metrics at a borderline width.
  for (final width in <double>[320, 360, 480, 800]) {
    for (final scale in <double>[1, 2, 3]) {
      for (final direction in TextDirection.values) {
        for (final fixed in <bool>[false, true]) {
          testWidgets('${fixed ? 'after' : 'before'} width=$width scale=$scale direction=$direction', (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            var selected = false;
            await tester.pumpWidget(MaterialApp(home: MediaQuery(
              data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(scale)),
              child: Directionality(textDirection: direction, child: Scaffold(body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: StatefulBuilder(builder: (context, setState) => CustomScrollView(slivers: [
                  SliverToBoxAdapter(child: header(fixed, selected, (value) => setState(() => selected = value))),
                ])),
              ))),
            )));
            final exception = tester.takeException();
            final bounds = tester.getRect(find.byType(Switch));
            final inBounds = bounds.left >= 15 && bounds.right <= width - 15;
            final reproduced = exception != null || !inBounds;
            var toggled = false;
            if (fixed) {
              expect(exception, isNull);
              expect(inBounds, isTrue);
              await tester.tap(find.byType(Switch));
              await tester.pumpAndSettle();
              toggled = selected;
              expect(toggled, isTrue);
              expect(tester.takeException(), isNull);
            } else if (width == 800 && scale == 1) {
              expect(reproduced, isFalse, reason: 'Known working baseline control must remain valid.');
            } else if (width == 320 && scale >= 2) {
              expect(reproduced, isTrue, reason: 'Require the reported overflow before accepting the fix.');
            }
            final result = <String, Object?>{
              'fixed': fixed, 'width': width, 'availableWidth': width - 30, 'scale': scale,
              'direction': direction.name, 'font': 'flutter_test Ahem', 'layoutException': exception?.toString(),
              'switchLeft': bounds.left, 'switchRight': bounds.right, 'inBounds': inBounds,
              'reproduced': reproduced, 'toggled': toggled,
            };
            results.add(result);
            print('HEADER_RESULT ${jsonEncode(result)}');
          });
        }
      }
    }
  }
}
