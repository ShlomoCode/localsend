import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:routerino/routerino.dart';

class TextFieldWithActionsDialog extends StatefulWidget {
  final String name;
  final String initialValue;
  final List<Widget> Function(ValueChanged<String> setDraft) actionsBuilder;

  const TextFieldWithActionsDialog({
    required this.name,
    required this.initialValue,
    required this.actionsBuilder,
  });

  @override
  State<TextFieldWithActionsDialog> createState() => _TextFieldWithActionsDialogState();
}

class _TextFieldWithActionsDialogState extends State<TextFieldWithActionsDialog> {
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
