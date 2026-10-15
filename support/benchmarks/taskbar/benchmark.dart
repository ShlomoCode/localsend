import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/taskbar_before_benchmark.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:window_manager/window_manager.dart';

const _channel = MethodChannel('main-delegate-channel');
const _pairs = int.fromEnvironment('BENCHMARK_PAIRS', defaultValue: 50);
const _frames = int.fromEnvironment('BENCHMARK_FRAMES', defaultValue: 600);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('LocalSend taskbar benchmark'))),
    ),
  );
  try {
    if (!Platform.isMacOS || _pairs < 1 || _frames < 2) {
      throw StateError('Requires macOS, positive pairs, and at least two frames');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    await windowManager.ensureInitialized();
    await windowManager.show();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(seconds: 1));
    for (var pair = -3; pair < _pairs; pair++) {
      final order = pair.isEven ? ['before', 'after'] : ['after', 'before'];
      for (final variant in order) {
        await _trial(variant, pair, order.join('-'));
      }
    }
    stdout.writeln('TASKBAR_BENCHMARK_DONE ${jsonEncode({'pairs': _pairs, 'frames': _frames})}');
    await stdout.flush();
    exit(0);
  } catch (error, stack) {
    stderr.writeln('TASKBAR_BENCHMARK_ERROR $error\n$stack');
    await stderr.flush();
    exit(1);
  }
}

Future<void> _nextFrame() {
  final completer = Completer<void>();
  SchedulerBinding.instance.scheduleFrameCallback((_) => completer.complete());
  SchedulerBinding.instance.scheduleFrame();
  return completer.future;
}

Future<void> _trial(String variant, int pair, String order) async {
  final before = variant == 'before';
  // Clear resets each helper's cached percentage. Its native call is outside the trial.
  await (before ? BeforeTaskbarHelper.clearProgressBar() : TaskbarHelper.clearProgressBar());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final start = await _channel.invokeMapMethod<String, dynamic>('resetBenchmarkMetrics');
  final elapsed = Stopwatch()..start();
  final outstanding = <Future<void>>[];
  for (var progress = 0; progress < _frames; progress++) {
    await _nextFrame();
    // Match production: progress updates do not wait for native completion before
    // the next frame. Waiting for all calls afterwards catches channel errors.
    outstanding.add(before ? BeforeTaskbarHelper.setProgressBar(progress, _frames - 1) : TaskbarHelper.setProgressBar(progress, _frames - 1));
  }
  await Future.wait(outstanding);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final end = await _channel.invokeMapMethod<String, dynamic>('readBenchmarkMetrics');
  elapsed.stop();
  if (start == null || end == null) throw StateError('Missing native metrics');
  final expectedCalls = before ? _frames : {for (var progress = 0; progress < _frames; progress++) ((progress / (_frames - 1)) * 100).toInt()}.length;
  if (end['native_calls'] != expectedCalls) {
    throw StateError('$variant expected $expectedCalls native calls, got ${end['native_calls']}');
  }
  stdout.writeln(
    'TASKBAR_BENCHMARK_ROW ${jsonEncode({'pair': pair, 'warmup': pair < 0, 'order': order, 'variant': variant, 'frames': _frames, 'total': _frames - 1, 'wall_ms': elapsed.elapsedMicroseconds / 1000, 'native_calls': end['native_calls'], 'native_handler_ns': end['native_handler_ns'], 'app_user_cpu_us': (end['app_user_cpu_us'] as num) - (start['app_user_cpu_us'] as num), 'app_system_cpu_us': (end['app_system_cpu_us'] as num) - (start['app_system_cpu_us'] as num)})}',
  );
  await stdout.flush();
}
