import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/widget/dialogs/native_tv_text_field.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A [AlertDialog] on all devices.
/// The button opens a dialog box with actions.
class TextFieldWithActions extends StatefulWidget {
  final String name;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final List<Widget> actions;

  const TextFieldWithActions({
    required this.name,
    required this.controller,
    required this.onChanged,
    required this.actions,
  });

  @override
  State<TextFieldWithActions> createState() => _TextFieldWithActionsState();
}

class _TextFieldWithActionsState extends State<TextFieldWithActions> with Refena {
  final FocusNode _buttonFocus = FocusNode();
  final FocusNode _confirmFocus = FocusNode();

  @override
  void dispose() {
    _buttonFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(tvProvider);
    return TextButton(
      focusNode: _buttonFocus,
      style: TextButton.styleFrom(
        backgroundColor: Theme.of(context).inputDecorationTheme.fillColor,
        shape: RoundedRectangleBorder(
          borderRadius: Theme.of(context).inputDecorationTheme.borderRadius,
        ),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: () async {
        await showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(widget.name),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Display actions inside the dialog
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: widget.actions,
                  ),
                  const SizedBox(height: 10),
                  if (isTv)
                    NativeTvTextField(
                      controller: widget.controller,
                      onChanged: widget.onChanged,
                      onSubmitted: () => context.pop(),
                      onKeyboardDismissed: _confirmFocus.requestFocus,
                    )
                  else
                    TextFormField(
                      controller: widget.controller,
                      textAlign: TextAlign.center,
                      onChanged: widget.onChanged,
                      autofocus: true,
                      onFieldSubmitted: (_) => context.pop(),
                    ),
                ],
              ),
              actions: [
                ElevatedButton(
                  focusNode: _confirmFocus,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                  onPressed: () => context.pop(),
                  child: Text(t.general.confirm),
                ),
              ],
            );
          },
        );
        if (mounted && isTv) _buttonFocus.requestFocus();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text(
          widget.controller.text,
          style: Theme.of(context).textTheme.titleMedium,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
