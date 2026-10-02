import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_isolates/model/file_type.dart';

void main() {
  late Uint8List bytes;
  setUpAll(() {
    final sourceImage = img.Image(width: 4000, height: 3000);
    img.fill(sourceImage, color: img.ColorRgb8(255, 0, 0));
    bytes = img.encodePng(sourceImage);
  });

  for (final (pixelRatio, expectedSize) in [(1.0, (64, 48)), (2.0, (128, 96))]) {
    testWidgets('memory thumbnails decode at thumbnail resolution on ${pixelRatio}x displays', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(inputDecorationTheme: const InputDecorationTheme(fillColor: Colors.white)),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(devicePixelRatio: pixelRatio),
              child: MemoryThumbnail(bytes: bytes, fileType: FileType.image),
            ),
          ),
        ),
      );

      ui.Image? image;
      for (var attempt = 0; attempt < 20 && image == null; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        image = tester.widget<RawImage>(find.byType(RawImage)).image;
      }
      expect(image, isNotNull);
      expect((image!.width, image.height), expectedSize);
    });
  }
}
