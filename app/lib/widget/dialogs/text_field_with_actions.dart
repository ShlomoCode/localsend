import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:routerino/routerino.dart';

/// A [AlertDialog] on all devices.
/// The button opens a dialog box with actions.
class TextFieldWithActions extends StatefulWidget {
  final String name;
  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final List<Widget> Function(ValueChanged<String> setDraft) actionsBuilder;

  const TextFieldWithActions({
    required this.name,
    required this.controller,
    required this.onSubmitted,
    required this.actionsBuilder,
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
        final result = await showDialog<String>(
          context: context,
          builder: (_) => _TextFieldWithActionsDialog(
            name: widget.name,
            initialValue: widget.controller.text,
            actionsBuilder: widget.actionsBuilder,
          ),
        );
        if (result == null || !mounted) {
          return;
        }
        setState(() => widget.controller.text = result);
        widget.onSubmitted(result);
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

class _TextFieldWithActionsDialog extends StatefulWidget {
  final String name;
  final String initialValue;
  final List<Widget> Function(ValueChanged<String> setDraft) actionsBuilder;

  const _TextFieldWithActionsDialog({
    required this.name,
    required this.initialValue,
    required this.actionsBuilder,
  });

  @override
  State<_TextFieldWithActionsDialog> createState() => _TextFieldWithActionsDialogState();
}

class _TextFieldWithActionsDialogState extends State<_TextFieldWithActionsDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setDraft(String value) {
    if (mounted) {
      _controller.text = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: widget.actionsBuilder(_setDraft),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _controller,
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
          onPressed: () => context.pop(_controller.text),
          child: Text(t.general.confirm),
        ),
      ],
    );
  }
}
