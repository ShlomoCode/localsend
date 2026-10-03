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

  testWidgets('fractional sizes with the same decode target share the cached image', (tester) async {
    final bytes = _png(800, 600);
    final first = await _show(tester, bytes, size: 50.1, dpr: 1);
    final second = await _show(tester, bytes, size: 50.9, dpr: 1);
    expect(second.image, same(first.image));
  });

  testWidgets('unchanged APK rebuild keeps the decoded icon visible', (tester) async {
    final bytes = _png(512, 512);
    final raw = await _show(tester, bytes, size: 60, dpr: 2, type: FileType.apk);
    for (var rebuild = 0; rebuild < 3; rebuild++) {
      await tester.pumpWidget(_thumbnailWidget(bytes, size: 60, dpr: 2, type: FileType.apk));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(raw.image), reason: 'An unchanged parent rebuild must not clear the icon');
    }
  });

  for (final example in [
    (48, 48, 50.0, 1.0),
    (48, 96, 60.0, 3.0),
    (96, 48, 50.0, 2.0),
    (96, 96, 60.0, 1.25),
    (96, 192, 50.0, 3.0),
    (192, 96, 60.0, 2.0),
    (192, 192, 50.0, 2.625),
    (192, 512, 60.0, 3.0),
    (512, 192, 50.0, 1.0),
    (512, 512, 60.0, 2.0),
    (301, 199, 50.0, 1.25),
    (199, 301, 60.0, 2.625),
  ]) {
    final (width, height, size, dpr) = example;
    testWidgets('APK ${width}x$height preserves padded bounds at size $size and DPR $dpr', (tester) async {
      final raw = await _show(tester, _png(width, height), size: size, dpr: dpr, type: FileType.apk);
      _expectPaddedApk(tester, raw, source: Size(width.toDouble(), height.toDouble()), size: size, dpr: dpr);
    });
  }

  testWidgets('same cached bytes adapt between ordinary images and padded APK icons', (tester) async {
    final bytes = _png(512, 512);
    for (final display in [
      (FileType.image, 50.0, 1.0),
      (FileType.apk, 50.0, 1.0),
      (FileType.apk, 60.0, 3.0),
      (FileType.apk, 60.0, 1.25),
      (FileType.image, 60.0, 1.25),
      (FileType.apk, 50.0, 1.0),
    ]) {
      final (type, size, dpr) = display;
      final raw = await _show(tester, bytes, size: size, dpr: dpr, type: type);
      if (type == FileType.apk) {
        _expectPaddedApk(tester, raw, source: const Size(512, 512), size: size, dpr: dpr);
      } else {
        _expectCover(tester, raw, source: const Size(512, 512), size: size, dpr: dpr);
        expect(math.min(raw.image!.width, raw.image!.height), lessThanOrEqualTo((size * dpr).ceil() + 1));
      }
    }
  });
}

Uint8List _png(int width, int height) {
  final source = img.Image(width: width, height: height);
  img.fill(source, color: img.ColorRgb8(40, 100, 180));
  return Uint8List.fromList(img.encodePng(source));
}

Widget _thumbnailWidget(Uint8List bytes, {required double size, required double dpr, required FileType type}) {
  return MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(inputDecorationTheme: const InputDecorationTheme(fillColor: Colors.white)),
        child: Center(
          child: MemoryThumbnail(bytes: bytes, fileType: type, size: size),
        ),
      ),
    ),
  );
}

Future<RawImage> _show(WidgetTester tester, Uint8List bytes, {required double size, required double dpr, FileType type = FileType.image}) async {
  await tester.pumpWidget(_thumbnailWidget(bytes, size: size, dpr: dpr, type: type));
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

void _expectPaddedApk(WidgetTester tester, RawImage raw, {required Size source, required double size, required double dpr}) {
  final thumbnail = tester.renderObject<RenderBox>(find.byType(MemoryThumbnail));
  final imageBox = tester.renderObject<RenderBox>(find.byType(RawImage));
  expect(thumbnail.size, Size.square(size));
  final transform = imageBox.getTransformTo(thumbnail);
  final painted = Rect.fromPoints(
    MatrixUtils.transformPoint(transform, Offset.zero),
    MatrixUtils.transformPoint(transform, imageBox.size.bottomRight(Offset.zero)),
  );
  final shortSide = math.min(source.width, source.height);
  final originalScale = size / (shortSide + 100);
  final expected = Rect.fromCenter(
    center: Offset(size / 2, size / 2),
    width: source.width * originalScale,
    height: source.height * originalScale,
  );
  final decoded = raw.image!;
  final roundingTolerance = originalScale * shortSide / math.min(decoded.width, decoded.height) + 0.001;
  expect(painted.left, closeTo(expected.left, roundingTolerance));
  expect(painted.top, closeTo(expected.top, roundingTolerance));
  expect(painted.right, closeTo(expected.right, roundingTolerance));
  expect(painted.bottom, closeTo(expected.bottom, roundingTolerance));
  expect(decoded.width, lessThanOrEqualTo(source.width));
  expect(decoded.height, lessThanOrEqualTo(source.height));
  if (size * dpr <= shortSide + 100) {
    expect(painted.width * dpr / decoded.width, lessThanOrEqualTo(1.00001));
    expect(painted.height * dpr / decoded.height, lessThanOrEqualTo(1.00001));
  }
  final maximumShortSide = math.min(shortSide, (size * dpr * shortSide / (shortSide + 100)).ceil());
  expect(math.min(decoded.width, decoded.height), lessThanOrEqualTo(maximumShortSide));
  if (shortSide >= 512) {
    expect(decoded.width * decoded.height * 4, lessThan(source.width * source.height * 4 / 4));
  }
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
