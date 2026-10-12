import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/theme.dart';

/// Native Android text input for TV dialogs. Android's IME owns D-pad navigation.
class NativeTvTextField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final VoidCallback? onKeyboardDismissed;

  const NativeTvTextField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onKeyboardDismissed,
  });

  @override
  State<NativeTvTextField> createState() => _NativeTvTextFieldState();
}

class _NativeTvTextFieldState extends State<NativeTvTextField> {
  MethodChannel? _channel;
  bool _updatingFromNative = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFromController);
  }

  @override
  void didUpdateWidget(NativeTvTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncFromController);
      widget.controller.addListener(_syncFromController);
      _syncFromController();
    }
  }

  void _syncFromController() {
    if (!_updatingFromNative) _send('setText', widget.controller.text);
  }

  void _send(String method, [Object? arguments]) {
    final channel = _channel;
    if (channel != null) unawaited(channel.invokeMethod<void>(method, arguments));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge;
    _send('setStyle', {
      'textColor': (style?.color ?? theme.colorScheme.onSurface).toARGB32(),
      'textSize': style?.fontSize ?? 16,
    });
  }

  void _onPlatformViewCreated(int id) {
    if (!mounted) return;
    final channel = MethodChannel(
      'org.localsend.localsend_app/tv_text_field/$id',
    );
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'changed':
          final text = call.arguments as String;
          if (widget.controller.text != text) {
            _updatingFromNative = true;
            try {
              widget.controller.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            } finally {
              _updatingFromNative = false;
            }
            widget.onChanged?.call(text);
          }
          return;
        case 'submitted':
          widget.onSubmitted?.call();
          return;
        case 'keyboardDismissed':
          widget.onKeyboardDismissed?.call();
          return;
      }
    });
    _syncFromController();
    _send('focus');
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    return Container(
      width: 320,
      height: 56,
      decoration: BoxDecoration(
        color: theme.inputDecorationTheme.fillColor,
        borderRadius: theme.inputDecorationTheme.borderRadius,
      ),
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: (focused) {
          // Flutter updates its platform-view client on focus, but does not focus the
          // Android EditText when the remote navigates back after dismissing the IME.
          if (focused) _send('focus');
        },
        child: PlatformViewLink(
          viewType: 'org.localsend.localsend_app/tv_text_field',
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          ),
          onCreatePlatformView: (params) {
            final controller = PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: 'org.localsend.localsend_app/tv_text_field',
              layoutDirection: Directionality.of(context),
              creationParams: {
                'text': widget.controller.text,
                'textColor': (style.color ?? theme.colorScheme.onSurface).toARGB32(),
                'hintColor': theme.hintColor.toARGB32(),
                'textSize': style.fontSize ?? 16,
              },
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            );
            controller.addOnPlatformViewCreatedListener((id) {
              params.onPlatformViewCreated(id);
              _onPlatformViewCreated(id);
            });
            unawaited(controller.create());
            return controller;
          },
        ),
      ),
    );
  }
}
