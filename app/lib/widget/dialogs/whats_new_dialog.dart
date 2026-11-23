import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:routerino/routerino.dart';

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
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChangelogReleaseTitle(
                  release: release,
                  title: t.whatsNewPage.title(version: release.version),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: ChangelogReleaseBody(release: release),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(t.changelogPage.title),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(t.general.close),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
