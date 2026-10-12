import 'dart:async';

import 'package:flutter/material.dart';

class RotatingWidget extends StatefulWidget {
  final Duration duration;
  final bool spinning;
  final bool reverse;
  final Widget child;

  const RotatingWidget({
    required this.duration,
    this.spinning = true,
    this.reverse = false,
    required this.child,
    super.key,
  });

  @override
  State<RotatingWidget> createState() => RotatingWidgetState();
}

class RotatingWidgetState extends State<RotatingWidget> {
  static const _fps = 30;
  static const _tickDuration = 1000 ~/ _fps; // in milliseconds
  static const _maxRadians = 6.28; // 360 degrees in radians
  double _angle = 0; // in radians
  double _anglePerTick = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _updateAnglePerTick();
    _startTimer();
  }

  @override
  void didUpdateWidget(RotatingWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnglePerTick();
    if (oldWidget.spinning != widget.spinning) {
      _timer?.cancel();
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateAnglePerTick() {
    _anglePerTick = _maxRadians / (widget.duration.inMilliseconds / _tickDuration);
    if (widget.reverse) {
      _anglePerTick = -_anglePerTick;
    }
  }

  void _startTimer() {
    if (!widget.spinning) {
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: _tickDuration), (_) {
      setState(() {
        _angle = (_angle + _anglePerTick) % _maxRadians;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: _angle,
      child: widget.child,
    );
  }
}
