import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/opacity_slideshow.dart';
import 'package:localsend_app/widget/rotating_widget.dart';

// A frozen picture alone does not prove that its timer stopped waking up.
class _TimerWakeups {
  int count = 0;
  ZoneSpecification get zone => ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) => parent.createTimer(zone, duration, () {
      if (duration > Duration.zero) count++;
      callback();
    }),
    createPeriodicTimer: (self, parent, zone, duration, callback) => parent.createPeriodicTimer(zone, duration, (timer) {
      if (duration > Duration.zero) count++;
      callback(timer);
    }),
  );

  Future<void> run(WidgetTester tester, Future<void> Function() body) => runZoned(() async {
    try {
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 250));
    }
  }, zoneSpecification: zone);
}

void main() {
  testWidgets('rotation has no paused wakeups and resumes from its current angle', (tester) async {
    final wakeups = _TimerWakeups();
    Widget rotation(bool spinning) => RotatingWidget(duration: const Duration(seconds: 2), spinning: spinning, child: const SizedBox());
    double angle() => tester.widget<Transform>(find.byType(Transform)).transform.storage[1];
    await wakeups.run(tester, () async {
      await tester.pumpWidget(rotation(false));
      await tester.pump(const Duration(seconds: 1));
      expect(wakeups.count, 0);
      await tester.pumpWidget(rotation(true));
      await tester.pump(const Duration(milliseconds: 200));
      final pausedAngle = angle();
      expect(pausedAngle, isNot(0));
      await tester.pumpWidget(rotation(false));
      final pausedWakeups = wakeups.count;
      await tester.pump(const Duration(seconds: 1));
      expect(wakeups.count, pausedWakeups);
      expect(angle(), pausedAngle);
      await tester.pumpWidget(rotation(true));
      await tester.pump(const Duration(milliseconds: 200));
      expect(angle(), isNot(pausedAngle));
    });
  });

  testWidgets('slideshow starts paused and cancels an interrupted fade until resumed', (tester) async {
    final wakeups = _TimerWakeups();
    Widget slideshow(bool running) => Directionality(
      textDirection: TextDirection.ltr,
      child: OpacitySlideshow(durationMillis: 500, switchDurationMillis: 200, running: running, children: const [Text('first'), Text('second')]),
    );
    await wakeups.run(tester, () async {
      await tester.pumpWidget(slideshow(false));
      await tester.pump(const Duration(seconds: 1));
      expect(wakeups.count, 0);
      expect(find.text('first'), findsOneWidget);
      await tester.pumpWidget(slideshow(true));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);
      await tester.pumpWidget(slideshow(false));
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
      final pausedWakeups = wakeups.count;
      await tester.pump(const Duration(seconds: 1));
      expect(wakeups.count, pausedWakeups);
      expect(find.text('first'), findsOneWidget);
      await tester.pumpWidget(slideshow(true));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('second'), findsOneWidget);
    });
  });

  testWidgets('a fade longer than the slideshow interval still completes', (tester) async {
    final wakeups = _TimerWakeups();
    await wakeups.run(tester, () async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: OpacitySlideshow(durationMillis: 100, switchDurationMillis: 200, children: [Text('first'), Text('second')]),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('second'), findsOneWidget);
    });
  });
}
