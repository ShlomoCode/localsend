import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
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
        final originalValue = widget.controller.text;
        final result = await showDialog<String>(
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
                  TextFormField(
                    controller: widget.controller,
                    textAlign: TextAlign.center,
                    autofocus: true,
                    onFieldSubmitted: (value) => context.pop(value),
                  ),
                ],
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                  onPressed: () => context.pop(widget.controller.text),
                  child: Text(t.general.confirm),
                ),
              ],
            );
          },
        );
        if (!mounted) {
          return;
        }
        setState(() => widget.controller.text = result ?? originalValue);
        if (result != null) {
          widget.onChanged(result);
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
