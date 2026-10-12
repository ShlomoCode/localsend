import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:routerino/routerino.dart';

/// A [AlertDialog] on all devices.
/// The button opens a dialog box with actions.
class TextFieldWithActions extends StatefulWidget {
  final String name;
  final TextEditingController controller;

  /// Called while typing. Without [onSubmitted], edits are kept on cancellation.
  final ValueChanged<String>? onChanged;

  /// Called on confirmation. When provided, cancellation restores the original text.
  final ValueChanged<String>? onSubmitted;
  final List<Widget> actions;

  const TextFieldWithActions({
    required this.name,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    required this.actions,
  });

  @override
  State<TextFieldWithActions> createState() => _TextFieldWithActionsState();
}

class _TextFieldWithActionsState extends State<TextFieldWithActions> {
  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: Theme.of(context).inputDecorationTheme.fillColor,
        shape: RoundedRectangleBorder(borderRadius: Theme.of(context).inputDecorationTheme.borderRadius),
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: () async {
        final originalText = widget.controller.text;
        final confirmedText = await showDialog<String>(
          context: context,
          builder: (dialogContext) {
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
                  TextFormField(
                    controller: widget.controller,
                    textAlign: TextAlign.center,
                    onChanged: widget.onChanged,
                    autofocus: true,
                    onFieldSubmitted: (text) => dialogContext.pop(text),
                  ),
                ],
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.primary,
                    foregroundColor: Theme.of(dialogContext).colorScheme.onPrimary,
                  ),
                  onPressed: () {
                    final editedText = widget.controller.text;
                    dialogContext.pop(editedText);
                  },
                  child: Text(t.general.confirm),
                ),
              ],
            );
          },
        );
        if (!mounted) {
          return;
        }
        final textIfCancelled = widget.onSubmitted != null ? originalText : widget.controller.text;
        final textToDisplay = confirmedText ?? textIfCancelled;
        setState(() => widget.controller.text = textToDisplay);
        if (confirmedText != null) {
          widget.onSubmitted?.call(confirmedText);
        }
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
