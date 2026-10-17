import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A normal [TextFormField] on mobile and desktop.
/// A button which opens a dialog on Android TV
class TextFieldTv extends StatefulWidget {
  final String name;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onDelete;

  const TextFieldTv({
    required this.name,
    required this.controller,
    this.onChanged,
    this.onDelete,
  });

  @override
  State<TextFieldTv> createState() => _TextFieldTvState();
}

class _TextFieldTvState extends State<TextFieldTv> with Refena {
  final _draftController = TextEditingController();

  @override
  void dispose() {
    _draftController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(tvProvider);

    if (isTv) {
      return TextButton(
        style: TextButton.styleFrom(
          backgroundColor: Theme.of(context).inputDecorationTheme.fillColor,
          shape: RoundedRectangleBorder(borderRadius: Theme.of(context).inputDecorationTheme.borderRadius),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: () async {
          _draftController.text = widget.controller.text;
          final confirmedText = await showDialog<String>(
            context: context,
            builder: (context) {
              return AlertDialog(
                title: Text(widget.name),
                content: TextFormField(
                  controller: _draftController,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  onFieldSubmitted: (text) => context.pop(text),
                ),
                actions: [
                  TextButton(
                    onPressed: () => context.pop(),
                    child: Text(t.general.cancel),
                  ),
                  TextButton(
                    onPressed: () => context.pop(_draftController.text),
                    child: Text(t.general.confirm),
                  ),
                ],
              );
            },
          );
          if (!mounted || confirmedText == null) {
            return;
          }

          setState(() {
            widget.controller.text = confirmedText;
          });
          widget.onChanged?.call(confirmedText);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Text(widget.controller.text, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
    } else {
      return TextFormField(
        controller: widget.controller,
        textAlign: TextAlign.center,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          suffixIcon: widget.onDelete != null
              ? IconButton(
                  icon: Icon(Icons.clear),
                  onPressed: () {
                    widget.onDelete?.call();
                  },
                )
              : null,
        ),
      );
    }
  }
}
