import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:routerino/routerino.dart';

/// Shows the changes of [release] after the app has been updated to it.
class WhatsNewDialog extends StatelessWidget {
  final ChangelogRelease release;

  const WhatsNewDialog({required this.release, super.key});

  static Future<void> open(BuildContext context, ChangelogRelease release) async {
    final openChangelog = await showDialog<bool>(
      context: context,
      builder: (_) => WhatsNewDialog(release: release),
    );
    if (openChangelog == true && context.mounted) {
      await context.push(() => const ChangelogPage());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.whatsNewPage.title(version: release.version)),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: ChangelogReleaseBody(release: release),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.changelogPage.title),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.general.close),
        ),
      ],
    );
  }
}
