import 'package:flutter/material.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';
import 'package:refena_flutter/refena_flutter.dart';

// Both APKs use the production widget. The control only disables Android's proxy.
void main() {
  runApp(
    RefenaScope.withContainer(
      container: RefenaContainer(
        overrides: [tvProvider.overrideWithValue(true)],
      ),
      child: MaterialApp(
        theme: ThemeData(
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
            fillColor: Colors.white,
          ),
        ),
        home: const _KeyboardFixture(),
      ),
    ),
  );
}

class _KeyboardFixture extends StatefulWidget {
  const _KeyboardFixture();

  @override
  State<_KeyboardFixture> createState() => _KeyboardFixtureState();
}

class _KeyboardFixtureState extends State<_KeyboardFixture> {
  final _controller = TextEditingController(text: 'Nice Grape');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Value: ${_controller.text}'),
            TextFieldWithActions(
              name: 'TV keyboard E2E',
              controller: _controller,
              onChanged: (_) => setState(() {}),
              actions: const [],
            ),
          ],
        ),
      ),
    );
  }
}
