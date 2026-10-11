// Temporary issue1864 observation only. No focus requests or key consumption.
import 'dart:convert';

import 'package:flutter/material.dart';

void tracePicker(String stage, Map<String, Object?> details) {
  // Diagnostic release builds need this output outside assertions/debugPrint throttling.
  // ignore: avoid_print
  print('ISSUE1864_TRACE ${jsonEncode({'hostDateTime': DateTime.now().toUtc().toIso8601String(), 'stage': stage, ...details})}');
}

/// One session per picker route. The caller starts it and disposes it when the route returns.
/// Registered nodes remain owned by their tile states; unregister before disposing a node.
class DiagnosticPickerFocusTrace {
  final Map<FocusNode, String> _nodes = {};
  late final _PickerTraceDispatcher _dispatcher = _PickerTraceDispatcher(this);
  bool _started = false;
  bool _disposed = false;
  int _eventSequence = 0;
  int _snapshotSequence = 0;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    FocusManager.instance.addEarlyKeyEventHandler(_earlyKey);
    FocusManager.instance.addLateKeyEventHandler(_lateKey);
    FocusManager.instance.addListener(_focusChanged);
    snapshotAfterFrame('picker-open');
  }

  Widget wrap(Widget child) => Actions(dispatcher: _dispatcher, actions: const <Type, Action<Intent>>{}, child: child);

  void observeNode(String label, FocusNode node) {
    if (_disposed) return;
    _nodes[node] = label;
    tracePicker('node-register', {'label': label});
    snapshotAfterFrame('node-register');
  }

  void unobserveNode(FocusNode node) {
    final label = _nodes.remove(node);
    if (label != null) tracePicker('node-unregister', {'label': label});
  }

  KeyEventResult _earlyKey(KeyEvent event) {
    _eventSequence++;
    _key('key-early', event);
    snapshotAfterFrame('key-after-frame');
    return KeyEventResult.ignored;
  }

  KeyEventResult _lateKey(KeyEvent event) {
    _key('key-late-unhandled', event);
    return KeyEventResult.ignored;
  }

  void _key(String stage, KeyEvent event) {
    tracePicker(stage, {
      'sequence': _eventSequence,
      'type': event.runtimeType.toString(),
      'logicalId': event.logicalKey.keyId,
      'logicalLabel': event.logicalKey.keyLabel,
      'physicalId': event.physicalKey.usbHidUsage,
      'synthesized': event.synthesized,
      'eventMicros': event.timeStamp.inMicroseconds,
      'primaryFocus': _node(FocusManager.instance.primaryFocus),
    });
  }

  void _focusChanged() => snapshot('focus-change');

  void snapshotAfterFrame(String reason) {
    final sequence = _eventSequence;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) snapshot(reason, sequence: sequence);
    });
  }

  void snapshot(String reason, {int? sequence}) {
    if (_disposed) return;
    final primary = FocusManager.instance.primaryFocus;
    final scope = primary?.nearestScope;
    final snapshotId = ++_snapshotSequence;
    tracePicker('snapshot-summary', {
      'snapshotId': snapshotId,
      'reason': reason,
      'sequence': sequence ?? _eventSequence,
      'primaryFocus': _node(primary),
      'scope': _node(scope),
    });
    void emitNodes(String category, Iterable<FocusNode> nodes) {
      var ordinal = 0;
      for (final node in nodes) {
        tracePicker('snapshot-node', {'snapshotId': snapshotId, 'category': category, 'ordinal': ordinal++, 'node': _node(node)});
      }
    }

    emitNodes('ancestor', primary?.ancestors ?? const <FocusNode>[]);
    emitNodes('traversal', scope?.traversalDescendants ?? const <FocusNode>[]);
    emitNodes('tile', _nodes.keys);
  }

  Map<String, Object?>? _node(FocusNode? node) {
    if (node == null) return null;
    final label = _nodes[node] ?? node.debugLabel ?? node.runtimeType.toString();
    List<double>? rect;
    bool? intersectsViewport;
    final context = node.context;
    final renderObject = context != null && context.mounted ? context.findRenderObject() : null;
    if (renderObject is RenderBox && renderObject.attached && renderObject.hasSize) {
      final bounds = node.rect;
      final coordinates = [bounds.left, bounds.top, bounds.right, bounds.bottom];
      if (coordinates.every((value) => value.isFinite)) rect = coordinates;
      final size = context == null ? null : MediaQuery.maybeSizeOf(context);
      if (size != null) intersectsViewport = bounds.overlaps(Offset.zero & size);
    }
    return {
      'label': label.length > 60 ? label.substring(0, 60) : label,
      'identity': identityHashCode(node),
      'hasFocus': node.hasFocus,
      'hasPrimaryFocus': node.hasPrimaryFocus,
      'canRequestFocus': node.canRequestFocus,
      'skipTraversal': node.skipTraversal,
      'descendantsAreFocusable': node.descendantsAreFocusable,
      'descendantsAreTraversable': node.descendantsAreTraversable,
      'attachedContext': context != null,
      'rect': rect,
      'intersectsViewport': intersectsViewport,
    };
  }

  void action(String phase, Action<Intent> action, Intent intent, {bool? enabled}) {
    tracePicker('action-$phase', {
      'sequence': _eventSequence,
      'intent': intent.runtimeType.toString(),
      'direction': intent is DirectionalFocusIntent ? intent.direction.name : null,
      'action': action.runtimeType.toString(),
      'enabled': ?enabled,
      'primaryFocus': _node(FocusManager.instance.primaryFocus),
    });
  }

  void dispose() {
    if (_disposed) return;
    if (_started) {
      FocusManager.instance.removeEarlyKeyEventHandler(_earlyKey);
      FocusManager.instance.removeLateKeyEventHandler(_lateKey);
      FocusManager.instance.removeListener(_focusChanged);
    }
    tracePicker('trace-dispose', {'registeredNodeCount': _nodes.length});
    _nodes.clear();
    _disposed = true;
  }
}

class _PickerTraceDispatcher extends ActionDispatcher {
  _PickerTraceDispatcher(this.trace);
  final DiagnosticPickerFocusTrace trace;

  @override
  Object? invokeAction(covariant Action<Intent> action, covariant Intent intent, [BuildContext? context]) {
    trace.action('invoke-before', action, intent);
    final result = super.invokeAction(action, intent, context);
    trace.action('invoke-after', action, intent);
    trace.snapshotAfterFrame('action-after-frame');
    return result;
  }

  @override
  (bool, Object?) invokeActionIfEnabled(covariant Action<Intent> action, covariant Intent intent, [BuildContext? context]) {
    trace.action('conditional-before', action, intent);
    final result = super.invokeActionIfEnabled(action, intent, context);
    trace.action('conditional-after', action, intent, enabled: result.$1);
    trace.snapshotAfterFrame('action-after-frame');
    return result;
  }
}
