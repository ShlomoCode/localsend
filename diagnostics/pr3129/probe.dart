import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

final paints = <String,int>{};
final frames = <Map<String,int>>[];
void startProbe() {
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      frames.add({'build_us': t.buildDuration.inMicroseconds, 'raster_us': t.rasterDuration.inMicroseconds, 'total_us': t.totalSpan.inMicroseconds});
    }
  });
  Timer.periodic(const Duration(seconds: 1), (_) {
    final path = Platform.environment['PROBE_LOG'];
    if (path == null) return;
    final phase = File('/tmp/pr3129-phase');
    File(path).writeAsStringSync('${jsonEncode({'time':DateTime.now().toIso8601String(), 'phase':phase.existsSync()?phase.readAsStringSync().trim():'warmup','paints':Map.of(paints),'frames':List.of(frames)})}\n',mode:FileMode.append);
    paints.clear(); frames.clear();
  });
}
class PaintProbe extends SingleChildRenderObjectWidget {
  final String name;
  const PaintProbe({required this.name, required super.child, super.key});
  @override RenderObject createRenderObject(BuildContext context) => ProbeRender(name);
}
class ProbeRender extends RenderProxyBox {
  final String name;
  ProbeRender(this.name);
  @override void paint(PaintingContext context, Offset offset) {
    paints[name]=(paints[name]??0)+1;
    super.paint(context,offset);
  }
}
