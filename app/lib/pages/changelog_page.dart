import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/ui/nav_bar_padding.dart';

class ChangelogPage extends StatelessWidget {
  const ChangelogPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.changelogPage.title),
      ),
      body: const ChangelogContent(),
    );
  }
}

class ChangelogContent extends StatefulWidget {
  const ChangelogContent({super.key});

  @override
  State<ChangelogContent> createState() => _ChangelogContentState();
}

class _ChangelogContentState extends State<ChangelogContent> {
  late final Future<String> _changelog = rootBundle.loadString(Assets.changelog);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _changelog,
      builder: (context, data) {
        if (data.hasError) {
          return Center(child: Text(t.general.error));
        }
        if (!data.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return Markdown(
          padding: EdgeInsets.only(
            left: 15,
            right: 15,
            top: 15,
            bottom: 15 + getNavBarPadding(context),
          ),
          data: data.data!,
        );
      },
    );
  }
}
