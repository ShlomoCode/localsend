import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/opacity_slideshow.dart';
import 'package:localsend_app/widget/rotating_widget.dart';

class _TimerWakeups {
  int positiveDurationCount = 0;

  void _record(Duration duration) {
    if (duration > Duration.zero) positiveDurationCount++;
  }

  ZoneSpecification get zoneSpecification => ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      return parent.createTimer(zone, duration, () {
        _record(duration);
        callback();
      });
    },
    createPeriodicTimer: (self, parent, zone, duration, callback) {
      return parent.createPeriodicTimer(zone, duration, (timer) {
        _record(duration);
        callback(timer);
      });
    },
  );
}

Future<void> _withTimerWakeups(WidgetTester tester, _TimerWakeups wakeups, Future<void> Function() body) async {
  await runZoned(() async {
    try {
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 250));
    }
  }, zoneSpecification: wakeups.zoneSpecification);
}

Future<void> _pumpFor(WidgetTester tester, Duration total, Duration step) async {
  final iterations = total.inMilliseconds ~/ step.inMilliseconds;
  for (var i = 0; i < iterations; i++) {
    await tester.pump(step);
  }
}

void main() {
  testWidgets('paused rotation does not wake the timer and resumes rotating', (tester) async {
    final wakeups = _TimerWakeups();
    await _withTimerWakeups(tester, wakeups, () async {
      Widget rotation(bool spinning) => Directionality(
        textDirection: TextDirection.ltr,
        child: RotatingWidget(duration: const Duration(seconds: 2), spinning: spinning, child: const Text('spinner')),
      );

      await tester.pumpWidget(rotation(false));
      await _pumpFor(tester, const Duration(seconds: 1), const Duration(milliseconds: 40));
      expect(wakeups.positiveDurationCount, 0);

      await tester.pumpWidget(rotation(true));
      await _pumpFor(tester, const Duration(milliseconds: 200), const Duration(milliseconds: 40));
      final transform = tester.widget<Transform>(find.descendant(of: find.byType(RotatingWidget), matching: find.byType(Transform)));
      expect(transform.transform.storage[1].abs(), greaterThan(0));
      expect(wakeups.positiveDurationCount, greaterThan(0));

      await tester.pumpWidget(rotation(false));
      final pausedWakeups = wakeups.positiveDurationCount;
      await _pumpFor(tester, const Duration(seconds: 1), const Duration(milliseconds: 40));
      expect(wakeups.positiveDurationCount, pausedWakeups);

      await tester.pumpWidget(rotation(true));
      final angleBeforeResume = tester
          .widget<Transform>(find.descendant(of: find.byType(RotatingWidget), matching: find.byType(Transform)))
          .transform
          .storage[1];
      await _pumpFor(tester, const Duration(milliseconds: 200), const Duration(milliseconds: 40));
      final angleAfterResume = tester
          .widget<Transform>(find.descendant(of: find.byType(RotatingWidget), matching: find.byType(Transform)))
          .transform
          .storage[1];
      expect(angleAfterResume, isNot(angleBeforeResume));
    });
  });

  testWidgets('initially paused slideshow does not cycle or wake its timer', (tester) async {
    final wakeups = _TimerWakeups();
    await _withTimerWakeups(tester, wakeups, () async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: OpacitySlideshow(
            durationMillis: 200,
            switchDurationMillis: 100,
            running: false,
            children: [Text('first'), Text('second')],
          ),
        ),
      );

      await _pumpFor(tester, const Duration(seconds: 1), const Duration(milliseconds: 50));
      expect(wakeups.positiveDurationCount, 0);
      expect(find.text('first'), findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
    });
  });

  testWidgets('pausing a fade keeps the current slide visible until resumed', (tester) async {
    final wakeups = _TimerWakeups();
    await _withTimerWakeups(tester, wakeups, () async {
      Widget slideshow(bool running) => Directionality(
        textDirection: TextDirection.ltr,
        child: OpacitySlideshow(
          durationMillis: 500,
          switchDurationMillis: 200,
          running: running,
          children: const [Text('first'), Text('second')],
        ),
      );

      await tester.pumpWidget(slideshow(true));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);

      await tester.pumpWidget(slideshow(false));
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, greaterThan(0));
      final pausedWakeups = wakeups.positiveDurationCount;
      await _pumpFor(tester, const Duration(seconds: 1), const Duration(milliseconds: 50));
      expect(wakeups.positiveDurationCount, pausedWakeups);
      expect(find.text('first'), findsOneWidget);

      await tester.pumpWidget(slideshow(true));
      await _pumpFor(tester, const Duration(milliseconds: 750), const Duration(milliseconds: 50));
      expect(find.text('second'), findsOneWidget);
    });
  });

  for (final switchDurationMillis in [100, 200]) {
    testWidgets('slideshow advances when fade duration is $switchDurationMillis ms and interval is 100 ms', (tester) async {
      await _withTimerWakeups(tester, _TimerWakeups(), () async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: OpacitySlideshow(
              durationMillis: 100,
              switchDurationMillis: switchDurationMillis,
              children: const [Text('first'), Text('second')],
            ),
          ),
        );

        await _pumpFor(tester, Duration(milliseconds: 100 + switchDurationMillis + 50), const Duration(milliseconds: 50));
        expect(find.text('second'), findsOneWidget);
        expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
      });
    });
  }
}
