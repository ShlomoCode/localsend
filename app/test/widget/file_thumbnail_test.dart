import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_isolates/model/file_type.dart';

void main() {
  for (final source in [(800, 600), (600, 800), (512, 512), (2400, 120), (120, 2400), (301, 199), (199, 301)]) {
    for (final display in [(50.0, 1.0), (50.0, 3.0), (87.3, 1.25), (129.5, 2.625)]) {
      final (width, height) = source;
      final (size, dpr) = display;
      // Sources smaller than the display cannot supply one pixel per physical pixel.
      if (math.min(width, height) < size * dpr) continue;
      testWidgets('${width}x$height covers a $size thumbnail at DPR $dpr without enlarging decoded pixels', (tester) async {
        final raw = await _show(tester, _png(width, height), size: size, dpr: dpr);
        _expectCover(tester, raw, source: Size(width.toDouble(), height.toDouble()), size: size, dpr: dpr);
      });
    }
  }

  testWidgets('small sources retain their original pixels and still fill the thumbnail', (tester) async {
    for (final source in [(24, 16), (16, 24), (17, 17)]) {
      final (width, height) = source;
      final raw = await _show(tester, _png(width, height), size: 90, dpr: 3);
      expect(raw.image!.width, width);
      expect(raw.image!.height, height);
      _expectCover(tester, raw, source: Size(width.toDouble(), height.toDouble()), size: 90, dpr: 3, sufficientSource: false);
    }
  });

  testWidgets('cached bytes adapt to both thumbnail size and device pixel ratio', (tester) async {
    final bytes = _png(1200, 800);
    // Reuse the bytes and Image element, including revisiting a smaller cached size.
    for (final display in [(50.0, 1.0), (50.0, 3.0), (140.5, 3.0), (140.5, 1.25), (50.0, 1.0)]) {
      final (size, dpr) = display;
      final raw = await _show(tester, bytes, size: size, dpr: dpr);
      _expectCover(tester, raw, source: const Size(1200, 800), size: size, dpr: dpr);
      // A stale, larger cached decode would look sharp but lose the memory saving.
      expect(math.min(raw.image!.width, raw.image!.height), lessThanOrEqualTo((size * dpr).ceil() + 1));
    }
  });
}

Uint8List _png(int width, int height) {
  final source = img.Image(width: width, height: height);
  img.fill(source, color: img.ColorRgb8(40, 100, 180));
  return Uint8List.fromList(img.encodePng(source));
}

Future<RawImage> _show(WidgetTester tester, Uint8List bytes, {required double size, required double dpr}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData(inputDecorationTheme: const InputDecorationTheme(fillColor: Colors.white)),
          child: Center(
            child: MemoryThumbnail(bytes: bytes, fileType: FileType.image, size: size),
          ),
        ),
      ),
    ),
  );
  final finder = find.descendant(of: find.byType(MemoryThumbnail), matching: find.byType(RawImage));
  // Codec completion uses real asynchronous engine work, outside the fake test clock.
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      final raw = tester.widget<RawImage>(finder);
      if (raw.image != null) return raw;
    }
  }
  fail('The thumbnail image did not finish decoding');
}

void _expectCover(
  WidgetTester tester,
  RawImage raw, {
  required Size source,
  required double size,
  required double dpr,
  bool sufficientSource = true,
}) {
  final thumbnail = tester.renderObject<RenderBox>(find.byType(MemoryThumbnail));
  final imageBox = tester.renderObject<RenderBox>(find.byType(RawImage));
  expect(thumbnail.size, Size.square(size));

  // Measure the actual FittedBox paint transform, rather than its decode request.
  final transform = imageBox.getTransformTo(thumbnail);
  final origin = MatrixUtils.transformPoint(transform, Offset.zero);
  final corner = MatrixUtils.transformPoint(transform, imageBox.size.bottomRight(Offset.zero));
  final painted = Rect.fromPoints(origin, corner);
  expect(painted.width, greaterThanOrEqualTo(size - 0.001));
  expect(painted.height, greaterThanOrEqualTo(size - 0.001));
  expect(math.min(painted.width, painted.height), closeTo(size, 0.001));
  expect(painted.center.dx, closeTo(size / 2, 0.001));
  expect(painted.center.dy, closeTo(size / 2, 0.001));

  final decoded = raw.image!;
  if (sufficientSource) {
    expect(painted.width * dpr / decoded.width, lessThanOrEqualTo(1.00001), reason: 'Rendered horizontal pixels must have enough decoded detail');
    expect(painted.height * dpr / decoded.height, lessThanOrEqualTo(1.00001), reason: 'Rendered vertical pixels must have enough decoded detail');
  }

  // Decoder integer rounding may move the long edge by at most one decoded pixel.
  // The rendered crop must still have the source aspect ratio, without stretching.
  final idealScale = size / math.min(source.width, source.height);
  final roundingTolerance = size / math.min(decoded.width, decoded.height) + 0.001;
  expect(painted.width, closeTo(source.width * idealScale, roundingTolerance));
  expect(painted.height, closeTo(source.height * idealScale, roundingTolerance));
  expect(decoded.width, lessThanOrEqualTo(source.width));
  expect(decoded.height, lessThanOrEqualTo(source.height));
}
