import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FontVariation;
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
    fontFamily: 'Segoe UI Variable Display', visualDensity: VisualDensity.standard,
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)))),
  home: const Probe(),
));
class Probe extends StatefulWidget {
  const Probe({super.key});
  @override State<Probe> createState() => ProbeState();
}
class ProbeState extends State<Probe> {
  bool saved = false;
  @override Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.titleMedium!;
    final scaler = MediaQuery.textScalerOf(context);
    final styles = <String, TextStyle>{
      'default': base,
      'wght500': base.copyWith(fontVariations: const [FontVariation('wght', 500)]),
      'wght600': base.copyWith(fontVariations: const [FontVariation('wght', 600)]),
      'staticSegoe': base.copyWith(fontFamily: 'Segoe UI'),
    };
    const labels = ['(Downloads)', '(Завантаження)', '(Téléchargements)'];
    if (!saved) {
      saved = true;
      final rows = <Map<String, Object?>>[];
      for (final entry in styles.entries) {
        for (final label in labels) {
          final painter = TextPainter(text: TextSpan(text: label, style: entry.value),
            textDirection: TextDirection.ltr, textScaler: scaler)..layout();
          final width = painter.width;
          painter.layout(maxWidth: 118);
          rows.add({'variant': entry.key, 'label': label, 'unboundedWidth': width,
            'fontSize': entry.value.fontSize, 'fontWeight': entry.value.fontWeight?.index,
            'textScaleAt16': scaler.scale(16), 'boundedWidth': painter.width,
            'lines': painter.computeLineMetrics().map((l) => {'width': l.width,
              'height': l.height, 'baseline': l.baseline, 'line': l.lineNumber}).toList()});
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        File(Platform.environment['BUG2861_OUTPUT']!).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({'rows': rows,
            'devicePixelRatio': MediaQuery.devicePixelRatioOf(context),
            'viewport': MediaQuery.sizeOf(context).toString(),
            'sdk': Platform.environment['BUG2861_SDK']}));
      });
    }
    return Scaffold(body: Padding(padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Identical font / 150 px Settings button probe', style: base),
        for (final entry in styles.entries) ...[
          const SizedBox(height: 24), Text(entry.key),
          Row(children: [for (final label in labels)
            Padding(padding: const EdgeInsets.only(right: 32), child: SizedBox(width: 150,
              child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                child: TextButton(onPressed: () {}, child: Text(label, style: entry.value)))))]),
        ],
      ])));
  }
}
