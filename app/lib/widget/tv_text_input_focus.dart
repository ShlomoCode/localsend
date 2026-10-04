import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gives Android TV an editor signal before EditableText opens its input connection.
/// The listener is installed before the field below is built, so Flutter notifies it
/// before EditableText's listener on the same focus node.
class TvTextInputFocus extends StatefulWidget {
  const TvTextInputFocus({required this.builder, this.editable = true, super.key});

  final Widget Function(FocusNode focusNode) builder;
  final bool editable;

  @override
  State<TvTextInputFocus> createState() => _TvTextInputFocusState();
}

class _TvTextInputFocusState extends State<TvTextInputFocus> {
  static const _channel = MethodChannel('org.localsend.localsend_app/localsend');
  static final Map<FocusNode, bool> _fields = {};
  static bool _lastSentFocused = false;

  late final FocusNode _focusNode = FocusNode()..addListener(_updateNativeFocus);

  static void _updateNativeFocus() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final focused = _fields[FocusManager.instance.primaryFocus] ?? false;
    if (focused == _lastSentFocused) return;
    _lastSentFocused = focused;
    unawaited(_channel.invokeMethod<void>('setNativeTextInputFocused', focused));
  }

  @override
  void initState() {
    super.initState();
    _fields[_focusNode] = widget.editable;
  }

  @override
  void didUpdateWidget(TvTextInputFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editable != widget.editable) {
      _fields[_focusNode] = widget.editable;
      _updateNativeFocus();
    }
  }

  @override
  void dispose() {
    _fields.remove(_focusNode);
    _updateNativeFocus();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_focusNode);
}
