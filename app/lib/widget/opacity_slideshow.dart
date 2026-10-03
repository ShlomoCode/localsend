import 'dart:async';

import 'package:flutter/material.dart';

/// A slideshow of widgets using [AnimatedOpacity] as transition.
class OpacitySlideshow extends StatefulWidget {
  final List<Widget> children;
  final int durationMillis;
  final int switchDurationMillis;
  final bool running;

  const OpacitySlideshow({
    required this.children,
    required this.durationMillis,
    this.switchDurationMillis = 300,
    this.running = true,
    super.key,
  });

  @override
  State<OpacitySlideshow> createState() => _OpacitySlideshowState();
}

class _OpacitySlideshowState extends State<OpacitySlideshow> {
  Timer? _timer;
  Timer? _switchTimer;
  int _index = 0;
  double _opacity = 1;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _switchTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(OpacitySlideshow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) {
      _timer?.cancel();
      _switchTimer?.cancel();
      _opacity = 1;
      _startTimer();
    }
  }

  void _startTimer() {
    if (!widget.running || widget.children.length <= 1) {
      return;
    }

    _timer = Timer.periodic(Duration(milliseconds: widget.durationMillis), (_) {
      // Let a pending fade finish before starting another one.
      if (_switchTimer?.isActive ?? false) {
        return;
      }
      setState(() {
        _opacity = 0;
      });
      _switchTimer = Timer(Duration(milliseconds: widget.switchDurationMillis), () {
        setState(() {
          _index = (_index + 1) % widget.children.length;
          _opacity = 1;
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: Duration(milliseconds: widget.switchDurationMillis),
      child: widget.children[_index],
    );
  }
}
